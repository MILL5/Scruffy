import XCTest
import Darwin
@testable import CleanupCore

final class ProgressiveScannerTests: XCTestCase {
    private final class Updates: @unchecked Sendable {
        let lock = NSLock()
        var snapshots: [ScanResult] = []
        func add(_ result: ScanResult) { lock.lock(); snapshots.append(result); lock.unlock() }
    }
    func testStatusOnlyProgressReusesSnapshotIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scruffy-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var options = ScanOptions(folders: [downloads]); options.browsers = false
        let updates = Updates()
        let result = try CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
            .scan(options) { snapshot, _ in updates.add(snapshot) }

        // Walking the empty folder and completing the scan both force progress,
        // without changing candidates or notes. No elapsed-time threshold is needed.
        XCTAssertGreaterThanOrEqual(updates.snapshots.count, 2)
        XCTAssertTrue(updates.snapshots.allSatisfy { $0.files.isEmpty && $0.notes.isEmpty })
        XCTAssertTrue(updates.snapshots.allSatisfy { $0.id == result.id })
    }
    func testCachesPublishBeforeVerifiedDuplicatesAndCandidatesNeverChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scruffy-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        let cache = home.appendingPathComponent("Library/Caches/com.apple.Safari/cache")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache)
        let seconds = Int(Date().timeIntervalSince1970) - 3 * 86400
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(cache.path, &times), 0)
        for name in ["first", "second"] { try Data(repeating: 42, count: 200_000).write(to: downloads.appendingPathComponent(name)) }
        let scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
        let updates = Updates()
        let result = try scanner.scan(ScanOptions(folders: [downloads])) { result, _ in updates.add(result) }
        XCTAssertTrue(updates.snapshots.contains { $0.files.contains(where: { $0.category == .browsers }) && !$0.files.contains(where: { $0.category == .duplicates }) })
        let final = Dictionary(uniqueKeysWithValues: result.files.map { ($0.id, $0) })
        for update in updates.snapshots {
            for item in update.files {
                XCTAssertEqual(item.keeper, final[item.id]?.keeper)
                XCTAssertEqual(item.duplicateHash, final[item.id]?.duplicateHash)
                XCTAssertEqual(item.category, final[item.id]?.category)
                if item.category == .duplicates {
                    XCTAssertNotNil(item.duplicateHash)
                    XCTAssertEqual(update.files.filter { $0.duplicateHash == item.duplicateHash && $0.keeper }.count, 1)
                }
            }
        }
        XCTAssertEqual(result.files.filter { $0.category == .duplicates }.count, 2)
    }
    func testLookAheadNeverTreatsMatchingEndsAsProofOfEquality() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scruffy-lookahead-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let original = Data(repeating: 10, count: 200_000)
        var different = original; different[100_000] = 11
        try original.write(to: downloads.appendingPathComponent("original"))
        try original.write(to: downloads.appendingPathComponent("copy"))
        try different.write(to: downloads.appendingPathComponent("different-middle"))
        var options = ScanOptions(folders: [downloads, home]); options.browsers = false
        let result = try CleanupScanner(home: home, temp: root.appendingPathComponent("temp")).scan(options)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertFalse(result.files.contains { $0.url.lastPathComponent == "different-middle" })
        XCTAssertEqual(result.files.filter(\.keeper).count, 1)
        XCTAssertEqual(Set(result.files.map(\.id)).count, result.files.count)
    }
}
