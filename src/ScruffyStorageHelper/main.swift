import Foundation
import CoreFoundation
import Darwin
import CleanupCore

// CacheDelete is an undocumented macOS interface. Keep ABI calls in this isolated
// process, gate every purge with a read-only filter check, and never elevate it.
typealias Query = @convention(c) (CFDictionary) -> Unmanaged<CFTypeRef>?
typealias ReplyBlock = @convention(block) (CFDictionary?) -> Void
typealias Purge = @convention(c) (CFDictionary, ReplyBlock) -> Unmanaged<CFTypeRef>?

func sumBytes(_ left: Int64, _ right: Int64) throws -> Int64 {
    let (total, overflow) = left.addingReportingOverflow(right)
    guard !overflow else { throw PurgeableError.unsupportedCapacity }
    return total
}

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
    let deadline = DispatchTime.now() + .seconds(210)
    let query = unsafeBitCast(querySymbol, to: Query.self)
    func eligibleBytes(for service: SystemPurgePolicy.Service) throws -> Int64 {
        let info = SystemPurgePolicy.queryInfo(for: service) as CFDictionary
        guard let raw = query(info)?.takeRetainedValue() as? [String: Any] else {
            throw PurgeableError.command("macOS could not inspect purgeable system data.")
        }
        return try SystemPurgePolicy.verifiedBytes(raw, for: service)
    }
    let fileData = try eligibleBytes(for: .fileData)
    let appCaches = try eligibleBytes(for: .appContainerCaches)
    let bytes = try sumBytes(fileData, appCaches)
    var removed: Int64?
    if args[0] == "purge" {
        guard bytes > 0 else {
            throw PurgeableError.command("macOS currently reports no cleanable system data. Nothing was removed.")
        }
        let purge = unsafeBitCast(purgeSymbol, to: Purge.self)
        func clean(_ service: SystemPurgePolicy.Service, bytes: Int64) throws -> Int64 {
            guard bytes > 0 else { return 0 }
            guard DispatchTime.now() < deadline else { throw PurgeableError.command("The macOS purge request timed out.") }
            let box = ReplyBox()
            let callback: ReplyBlock = { dictionary in box.set(dictionary as? [String: Any]) }
            let info = try SystemPurgePolicy.purgeInfo(for: service, cleanableBytes: bytes) as CFDictionary
            _ = purge(info, callback)?.takeRetainedValue()
            guard box.done.wait(timeout: deadline) == .success, let result = box.get() else {
                throw PurgeableError.command("macOS did not report completion. Refresh storage before retrying; the request may still finish.")
            }
            if let error = result["CACHE_DELETE_ERROR"] { throw PurgeableError.command("macOS purge failed: \(error)") }
            guard let amount = SystemPurgePolicy.byteCount(result["CACHE_DELETE_AMOUNT"]) else {
                throw PurgeableError.command("macOS did not report the amount removed. Refresh storage to check the result.")
            }
            return amount
        }
        var fileBytesRemoved = try clean(.fileData, bytes: fileData)
        if fileBytesRemoved > 0 {
            // A successful first pass can leave more purgeable file data. Check once at the same urgency.
            let remaining = try eligibleBytes(for: .fileData)
            fileBytesRemoved = try sumBytes(fileBytesRemoved, clean(.fileData, bytes: remaining))
        }
        removed = try sumBytes(fileBytesRemoved, clean(.appContainerCaches, bytes: appCaches))
    }
    let reply = SystemPurgeReply(cleanableBytes: bytes, removedBytes: removed)
    FileHandle.standardOutput.write(try JSONEncoder().encode(reply))
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
