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
    func testVerifiedDuplicatesPublishBeforeCachesAndCandidatesNeverChange() throws {
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
        XCTAssertTrue(updates.snapshots.contains { $0.categoryCounts[.duplicates, default: 0] > 0 && $0.categoryCounts[.browsers, default: 0] == 0 })
        XCTAssertFalse(updates.snapshots.contains { $0.categoryCounts[.browsers, default: 0] > 0 && $0.categoryCounts[.duplicates, default: 0] == 0 })
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

    private struct OrderedFixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-order-\(UUID())")
        var home: URL { root.appendingPathComponent("home") }
        var downloads: URL { home.appendingPathComponent("Downloads") }
        var documents: URL { home.appendingPathComponent("Documents") }
        var temp: URL { root.appendingPathComponent("temp") }
        var scanner: CleanupScanner { CleanupScanner(home: home, temp: temp) }
        var options: ScanOptions {
            var options = ScanOptions(folders: [downloads, documents])
            options.caches = true; options.temporary = true
            return options
        }
        func file(_ url: URL, bytes: Int, daysOld: Int = 0) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if bytes >= 500 * 1024 * 1024 {
                // Sparse file: exercises the large-file boundary without allocating or hashing 500 MB.
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(bytes))
            } else { try Data(repeating: 42, count: bytes).write(to: url) }
            let seconds = Int(Date().timeIntervalSince1970) - daysOld * 86400
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            XCTAssertEqual(utimes(url.path, &times), 0)
        }
        func prepare() throws {
            try file(downloads.appendingPathComponent("original"), bytes: 1_000)
            try file(downloads.appendingPathComponent("copy"), bytes: 1_000)
            try file(downloads.appendingPathComponent("old-download"), bytes: 201, daysOld: 40)
            try file(home.appendingPathComponent("Library/Caches/com.apple.Safari/cache"), bytes: 401, daysOld: 3)
            try file(home.appendingPathComponent("Library/Caches/pip/cache"), bytes: 501, daysOld: 8)
            try file(temp.appendingPathComponent("temporary"), bytes: 601, daysOld: 8)
            try file(documents.appendingPathComponent("large"), bytes: 500 * 1024 * 1024)
            try file(downloads.appendingPathComponent("movie.mp4"), bytes: 303)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func count(_ category: CleanupCategory, in result: ScanResult) -> Int {
        category == .videos ? result.videos.count : result.categoryCounts[category, default: 0]
    }
    private func bytes(_ category: CleanupCategory, in result: ScanResult) -> Int64 {
        category == .videos ? result.videoBytes : result.categoryBytes[category, default: 0]
    }
    private func assertOrder(_ categories: [CleanupCategory], updates: [ScanResult], final: ScanResult,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        var previous = -1
        for category in categories {
            let first = try XCTUnwrap(updates.firstIndex { count(category, in: $0) > 0 }, category.rawValue, file: file, line: line)
            XCTAssertGreaterThan(first, previous, category.rawValue, file: file, line: line)
            for earlier in categories.prefix(while: { $0 != category }) {
                XCTAssertEqual(count(earlier, in: updates[first]), count(earlier, in: final), earlier.rawValue, file: file, line: line)
                XCTAssertEqual(bytes(earlier, in: updates[first]), bytes(earlier, in: final), earlier.rawValue, file: file, line: line)
            }
            previous = first
        }
    }

    func testEveryCategoryPopulatesCountsAndSizesInSidebarOrder() throws {
        let fixture = OrderedFixture(); defer { fixture.cleanup() }; try fixture.prepare()
        let updates = Updates()
        let result = try fixture.scanner.scan(fixture.options) { snapshot, _ in updates.add(snapshot) }
        try assertOrder(CleanupCategory.allCases, updates: updates.snapshots, final: result)
        for category in CleanupCategory.allCases { XCTAssertEqual(count(category, in: result), 1, category.rawValue) }
        let largeBytes: Int64 = 500 * 1024 * 1024
        XCTAssertEqual(result.candidateBytes, largeBytes + 2_704)
        XCTAssertEqual(result.videoBytes, 303)
    }

    func testDownloadsStillPopulateBeforeCachesWithDuplicateDetectionDisabled() throws {
        let fixture = OrderedFixture(); defer { fixture.cleanup() }; try fixture.prepare()
        var options = fixture.options; options.duplicates = false
        let updates = Updates()
        let result = try fixture.scanner.scan(options) { snapshot, _ in updates.add(snapshot) }
        try assertOrder(CleanupCategory.allCases.filter { $0 != .duplicates }, updates: updates.snapshots, final: result)
        XCTAssertEqual(result.categoryCounts[.duplicates, default: 0], 0)
    }

    func testDisabledPersonalCategoriesAllowCachesBeforeVideoDiscovery() throws {
        let fixture = OrderedFixture(); defer { fixture.cleanup() }; try fixture.prepare()
        var options = fixture.options
        options.duplicates = false; options.downloads = false; options.large = false
        let updates = Updates()
        let result = try fixture.scanner.scan(options) { snapshot, _ in updates.add(snapshot) }
        try assertOrder([.browsers, .caches, .temporary, .videos], updates: updates.snapshots, final: result)
        for category in [CleanupCategory.duplicates, .downloads, .large] { XCTAssertEqual(count(category, in: result), 0) }
    }

    func testLaterCategoriesReusePersonalInventoryRatherThanRescanningFolders() throws {
        let fixture = OrderedFixture(); defer { fixture.cleanup() }; try fixture.prepare()
        var options = fixture.options; options.duplicates = false
        let lateVideo = fixture.downloads.appendingPathComponent("created-after-inventory.mov")
        let result = try fixture.scanner.scan(options) { snapshot, _ in
            if snapshot.categoryCounts[.browsers, default: 0] > 0 {
                // Browser scanning starts after the personal-folder inventory has finished.
                try? Data(repeating: 9, count: 97).write(to: lateVideo)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateVideo.path))
        XCTAssertEqual(result.videos.map(\.url), [fixture.downloads.appendingPathComponent("movie.mp4")])
    }
}
