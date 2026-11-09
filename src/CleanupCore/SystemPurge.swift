import Foundation

public struct SystemPurgeReply: Codable, Sendable {
    public let cleanableBytes: Int64
    public let removedBytes: Int64?
    public init(cleanableBytes: Int64, removedBytes: Int64? = nil) {
        self.cleanableBytes = cleanableBytes; self.removedBytes = removedBytes
    }
}

public enum SystemPurgePolicy {
    public static let services = ["com.apple.fspurgeable_data", "com.apple.cache_delete_app_container_caches"]
    public static let volume = "/System/Volumes/Data"
    public static let urgency = 3

    public static func verifiedBytes(_ result: [String: Any]) throws -> Int64 {
        guard result["CACHE_DELETE_ERROR"] == nil,
              result["CACHE_DELETE_VOLUME"] as? String == volume else {
            throw PurgeableError.command("macOS did not return a supported purgeable-data report.")
        }
        var bytes: Int64 = 0
        for (key, value) in result where !key.hasPrefix("CACHE_DELETE_") {
            // Refuse if the OS ever ignores the service restriction, including unknown values.
            guard services.contains(key), let amount = value as? NSNumber, amount.doubleValue.isFinite,
                  amount.doubleValue >= 0, amount.doubleValue < Double(Int64.max) else {
                throw PurgeableError.command("macOS did not honor the restricted cache selection. Nothing was cleaned.")
            }
            let (sum, overflow) = bytes.addingReportingOverflow(amount.int64Value)
            guard !overflow else { throw PurgeableError.unsupportedCapacity }
            bytes = sum
        }
        return bytes
    }
    public static func queryInfo() -> [String: Any] {
        ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY_LIMIT": urgency,
         "CACHE_DELETE_NO_CACHE": true, "CACHE_DELETE_SERVICES": services]
    }
    public static func purgeInfo(cleanableBytes: Int64) throws -> [String: Any] {
        guard cleanableBytes > 0 else { throw PurgeableError.command("macOS currently reports no cleanable system data. Nothing was removed.") }
        return ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY": urgency,
         "CACHE_DELETE_AMOUNT": cleanableBytes, "CACHE_DELETE_SERVICES": services,
         "CACHE_DELETE_QUERY_AFTER_PURGE": true]
    }
}

public struct SystemPurgeClient: Sendable {
    public let helper: URL
    private let runner: PurgeableStorage.Runner
    public init(helper: URL, runner: @escaping PurgeableStorage.Runner = PurgeableStorage.run) {
        self.helper = helper; self.runner = runner
    }
    public func probe() throws -> SystemPurgeReply { try call(["probe"]) }
    public func clean() throws -> SystemPurgeReply { try call(["purge"]) }
    private func call(_ arguments: [String]) throws -> SystemPurgeReply {
        let result = try runner(helper.path, arguments)
        guard result.status == 0 else {
            throw PurgeableError.command(result.output.isEmpty ? "The macOS purge service was unavailable or timed out. Refresh storage before retrying." : String(result.output.prefix(1500)))
        }
        return try JSONDecoder().decode(SystemPurgeReply.self, from: Data(result.output.utf8))
    }
}
