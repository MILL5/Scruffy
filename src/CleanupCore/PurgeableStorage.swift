import Foundation

public struct StorageCapacity: Sendable {
    public let free: Int64
    public let available: Int64?
    public let total: Int64
    // This is a capacity estimate, not a list or measured size of purgeable files.
    public var reclaimableEstimate: Int64? { available.map { max(0, $0 - free) } }
    public init(free: Int64, available: Int64?, total: Int64) {
        self.free = max(0, free); self.available = available; self.total = max(0, total)
    }
}

public enum ReclaimTarget: Int64, CaseIterable, Sendable, Identifiable {
    case one = 1, five = 5, ten = 10, twenty = 20
    public var id: Int64 { rawValue }
    public var bytes: Int64 { rawValue * 1_000_000_000 }
    public var title: String { "\(rawValue) GB" }
}

public struct StorageReport: Sendable {
    public let capacity: StorageCapacity
    public let snapshots: [String]
    public let protectedSnapshotCount: Int
}

public struct SystemCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}

public enum PurgeableError: LocalizedError {
    case command(String), noSnapshots, unsupportedCapacity
    public var errorDescription: String? {
        switch self {
        case .command(let message): message
        case .noSnapshots: "No eligible Time Machine snapshots remain. System-update snapshots are protected."
        case .unsupportedCapacity: "macOS could not report storage capacity for this disk."
        }
    }
}

public struct PurgeableStorage: Sendable {
    public typealias Runner = @Sendable (String, [String]) throws -> SystemCommandResult
    private let runner: Runner
    public init(runner: @escaping Runner = PurgeableStorage.run) { self.runner = runner }

    public static func run(_ executable: String, _ arguments: [String]) throws -> SystemCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SystemCommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
    public static func snapshotNames(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.range(of: #"^com\.apple\.TimeMachine\.\d{4}-\d{2}-\d{2}-\d{6}\.local$"#, options: .regularExpression) != nil
        }.sorted()
    }
    public static func capacity(at url: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> StorageCapacity {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { throw PurgeableError.unsupportedCapacity }
        return StorageCapacity(free: Int64(free), available: values.volumeAvailableCapacityForImportantUsage, total: Int64(total))
    }
    public func report() throws -> StorageReport {
        let capacity = try Self.capacity()
        let listing = try runner("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard listing.status == 0 else { throw PurgeableError.command(listing.output) }
        let protectedCount = listing.output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("com.apple.os.update-") }.count
        return StorageReport(capacity: capacity, snapshots: Self.snapshotNames(in: listing.output), protectedSnapshotCount: protectedCount)
    }
    public static func reclaimScript(target: ReclaimTarget) -> String {
        // Only enum-derived integers and fixed paths enter the shell. No filename, UI
        // string, snapshot name, or process output is interpolated into this command.
        "do shell script \"/usr/bin/tmutil thinlocalsnapshots / \(target.bytes) 1\" with administrator privileges"
    }
    public func reclaim(target: ReclaimTarget) throws {
        // Refresh eligibility immediately before requesting admin approval.
        let listing = try runner("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard listing.status == 0 else { throw PurgeableError.command(listing.output) }
        guard !Self.snapshotNames(in: listing.output).isEmpty else { throw PurgeableError.noSnapshots }
        let result = try runner("/usr/bin/osascript", ["-e", Self.reclaimScript(target: target)])
        guard result.status == 0 else {
            throw PurgeableError.command(result.output.contains("-128") ? "Reclaim cancelled. No completion was reported." : result.output)
        }
    }
}
