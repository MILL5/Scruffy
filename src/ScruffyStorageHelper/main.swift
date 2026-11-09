import Foundation
import CoreFoundation
import Darwin
import CleanupCore

// CacheDelete is an undocumented macOS interface. Keep ABI calls in this isolated
// process, gate every purge with a read-only filter check, and never elevate it.
typealias Query = @convention(c) (CFDictionary) -> Unmanaged<CFTypeRef>?
typealias ReplyBlock = @convention(block) (CFDictionary?) -> Void
typealias Purge = @convention(c) (CFDictionary, ReplyBlock) -> Unmanaged<CFTypeRef>?

final class ReplyBox: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reply: [String: Any]?
    func set(_ value: [String: Any]?) { lock.lock(); reply = value; lock.unlock(); done.signal() }
    func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return reply }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args == ["probe"] || args == ["purge"] else {
        throw PurgeableError.command("Unsupported storage-helper request.")
    }
    alarm(args[0] == "probe" ? 45 : 240)
    guard let handle = dlopen("/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete", RTLD_NOW | RTLD_LOCAL),
          let querySymbol = dlsym(handle, "CacheDeleteCopyItemizedPurgeableSpaceWithInfo"),
          let purgeSymbol = dlsym(handle, "CacheDeletePurgeSpaceWithInfoSync") else {
        throw PurgeableError.command("This macOS version does not provide the required purge service.")
    }
    let query = unsafeBitCast(querySymbol, to: Query.self)
    guard let raw = query(SystemPurgePolicy.queryInfo() as CFDictionary)?.takeRetainedValue() as? [String: Any] else {
        throw PurgeableError.command("macOS could not inspect purgeable system data.")
    }
    let bytes = try SystemPurgePolicy.verifiedBytes(raw)
    var removed: Int64?
    if args[0] == "purge" {
        guard bytes > 0 else {
            throw PurgeableError.command("macOS currently reports no cleanable system data. Nothing was removed.")
        }
        let box = ReplyBox()
        let callback: ReplyBlock = { dictionary in box.set(dictionary as? [String: Any]) }
        let purge = unsafeBitCast(purgeSymbol, to: Purge.self)
        // The fresh, service-validated probe supplies the entire eligible amount.
        _ = purge(try SystemPurgePolicy.purgeInfo(cleanableBytes: bytes) as CFDictionary, callback)?.takeRetainedValue()
        guard box.done.wait(timeout: .now() + 210) == .success, let result = box.get() else {
            throw PurgeableError.command("macOS did not report completion. Refresh storage before retrying; the request may still finish.")
        }
        if let error = result["CACHE_DELETE_ERROR"] { throw PurgeableError.command("macOS purge failed: \(error)") }
        guard let amount = result["CACHE_DELETE_AMOUNT"] as? NSNumber, amount.int64Value >= 0 else {
            throw PurgeableError.command("macOS did not report the amount removed. Refresh storage to check the result.")
        }
        removed = amount.int64Value
    }
    let reply = SystemPurgeReply(cleanableBytes: bytes, removedBytes: removed)
    FileHandle.standardOutput.write(try JSONEncoder().encode(reply))
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
