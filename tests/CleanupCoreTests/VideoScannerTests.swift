import XCTest
@testable import CleanupCore

final class VideoScannerTests: XCTestCase {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ScanResult] = []
        func add(_ result: ScanResult) { lock.lock(); values.append(result); lock.unlock() }
        var snapshots: [ScanResult] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private var root: URL!
    private var home: URL!
    private var downloads: URL!
    private var scanner: CleanupScanner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scruffy-videos-\(UUID())")
        home = root.appendingPathComponent("home")
        downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, bytes: Int, fill: UInt8 = 42) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    private func videoOnlyOptions() -> ScanOptions {
        var options = ScanOptions(folders: [downloads])
        options.downloads = false; options.duplicates = false; options.browsers = false
        options.caches = false; options.temporary = false; options.large = false
        return options
    }

    func testRecentUniqueVideosAreDiscoveredWithoutOtherCleanupFlagsAndSorted() throws {
        let small = try file("Downloads/small.mp4", bytes: 20, fill: 1)
        let tieZ = try file("Downloads/z-medium.mov", bytes: 50, fill: 2)
        let large = try file("Downloads/large.m4v", bytes: 90, fill: 3)
        let tieA = try file("Downloads/a-medium.MP4", bytes: 50, fill: 4)
        try file("Downloads/ordinary.txt", bytes: 100)
        let options = videoOnlyOptions()
        XCTAssertTrue(options.videos)

        let result = try scanner.scan(options)

        XCTAssertEqual(result.videos.map(\.url), [large, tieA, tieZ, small])
        XCTAssertTrue(result.videos.allSatisfy { $0.category == .videos && !$0.keeper && $0.duplicateHash == nil })
        XCTAssertEqual(result.videoBytes, 210)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.filesBySize.isEmpty)
        XCTAssertTrue(result.filesByID.isEmpty)
        XCTAssertEqual(result.candidateBytes, 0)
        XCTAssertEqual(result.categoryCounts[.videos, default: 0], 0)
    }

    func testVideoFlagCanDisableVideoDiscovery() throws {
        try file("Downloads/movie.mp4", bytes: 20)
        var options = videoOnlyOptions(); options.videos = false
        let result = try scanner.scan(options)
        XCTAssertTrue(result.videos.isEmpty)
        XCTAssertEqual(result.videoBytes, 0)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testVideoDiscoveryExcludesProtectedCloudSymlinkAndHardlinkedFiles() throws {
        let safe = try file("Downloads/safe.mp4", bytes: 20)
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("shortcut.mov"), withDestinationURL: safe)
        let hard = try file("Downloads/hard.mp4", bytes: 30)
        try FileManager.default.linkItem(at: hard, to: downloads.appendingPathComponent("hard-copy.mp4"))
        try file("Downloads/Dropbox/cloud.mp4", bytes: 40)
        try file("Downloads/Test.app/Contents/movie.mov", bytes: 50)
        try file("Downloads/Pictures.photoslibrary/movie.m4v", bytes: 60)
        try file("Downloads/.git/movie.mp4", bytes: 70)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 80).write(to: outside.appendingPathComponent("movie.mp4"))
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("linked"), withDestinationURL: outside)

        let result = try scanner.scan(videoOnlyOptions())

        XCTAssertEqual(result.videos.map(\.url), [safe])
        XCTAssertEqual(result.videoBytes, 20)
    }

    func testVideoOnlyProgressGrowsMonotonicallyAndKeepsSizeOrder() throws {
        let first = try file("Downloads/first/small.mp4", bytes: 20)
        let largest = try file("Downloads/second/large.mov", bytes: 80)
        let medium = try file("Downloads/second/medium.m4v", bytes: 40)
        var options = videoOnlyOptions()
        options.folders = [downloads.appendingPathComponent("first"), downloads.appendingPathComponent("second")]
        let updates = Updates()
        let result = try scanner.scan(options) { snapshot, _ in updates.add(snapshot) }
        let snapshots = updates.snapshots
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.contains { $0.videos.map(\.url) == [first] })
        var previous = Set<String>()
        for snapshot in snapshots {
            let ids = Set(snapshot.videos.map(\.id))
            XCTAssertTrue(previous.isSubset(of: ids))
            let sorted = snapshot.videos.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
            XCTAssertEqual(snapshot.videos.map(\.id), sorted.map(\.id))
            XCTAssertEqual(snapshot.videoBytes, snapshot.videos.reduce(0) { $0 + $1.bytes })
            XCTAssertTrue(snapshot.files.isEmpty)
            previous = ids
        }
        XCTAssertEqual(result.videos.map(\.url), [largest, medium, first])
        XCTAssertEqual(snapshots.last?.videos.map(\.id), result.videos.map(\.id))
    }

    func testDuplicateVideoAlsoUsesSeparateVideoInventoryWithoutDoubleCountingCleanup() throws {
        try file("Downloads/original.mp4", bytes: 20)
        try file("Downloads/copy.mp4", bytes: 20)
        var options = videoOnlyOptions(); options.duplicates = true
        let result = try scanner.scan(options)
        XCTAssertEqual(result.videos.count, 2)
        XCTAssertEqual(result.videoBytes, 40)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.files.filter(\.keeper).count, 1)
        XCTAssertEqual(result.categoryCounts[.duplicates], 1)
        XCTAssertEqual(result.candidateBytes, 20)
    }
}
