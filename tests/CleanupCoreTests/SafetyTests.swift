import XCTest
import Darwin
@testable import CleanupCore

final class SafetyTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    var home: URL!
    var downloads: URL!
    var scanner: CleanupScanner!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-tests-\(UUID())")
        home = root.appendingPathComponent("home")
        downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult
    func file(_ path: String, _ text: String = "identical content") throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func options() -> ScanOptions {
        var options = ScanOptions(folders: [downloads]); options.browsers = false
        return options
    }
    func age(_ url: URL, days: Int) throws {
        let seconds = Int(Date().timeIntervalSince1970) - days * 86400
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        guard utimes(url.path, &times) == 0 else { throw POSIXError(.EIO) }
    }
    func testOldDownloadsRequireReviewAndRecentFilesAreExcluded() throws {
        let old = try file("Downloads/installer.dmg", "installer")
        try age(old, days: 40)
        try file("Downloads/recent.txt", "recent")
        var options = options(); options.duplicates = false
        let found = try scanner.scan(options)
        XCTAssertEqual(found.files.map(\.url), [old])
        XCTAssertEqual(found.files.first?.category, .downloads)
    }
    func testOnlyIdenticalContentFormsGroupAndOneOriginalIsProtected() throws {
        try file("Downloads/a.txt"); try file("Downloads/b.txt")
        try file("Downloads/c.txt", "different content") // Same byte count, different content.
        let found = try scanner.scan(options())
        XCTAssertEqual(found.files.count, 2)
        XCTAssertEqual(found.files.filter(\.keeper).count, 1)
        let copies = found.files.filter { !$0.keeper }
        XCTAssertNoThrow(try scanner.validateSelection(copies, all: found.files, folders: [downloads]))
        XCTAssertThrowsError(try scanner.validateSelection(found.files, all: found.files, folders: [downloads]))
    }
    func testChangedOriginalPreventsCleanup() throws {
        try file("Downloads/a.txt"); try file("Downloads/b.txt")
        let found = try scanner.scan(options())
        let keeper = try XCTUnwrap(found.files.first(where: \.keeper))
        try Data("changed".utf8).write(to: keeper.url)
        XCTAssertThrowsError(try scanner.validateSelection(found.files.filter { !$0.keeper }, all: found.files, folders: [downloads]))
    }
    func testResourceForkIsNotDiscardedAsADuplicate() throws {
        let original = try file("Downloads/a.txt"); try file("Downloads/b.txt")
        let resource = Data("extra document data".utf8)
        let result = resource.withUnsafeBytes { bytes in
            setxattr(original.path, "com.apple.ResourceFork", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        XCTAssertEqual(result, 0)
        XCTAssertTrue(try scanner.scan(options()).files.isEmpty)
    }
    func testDeletedOriginalPreventsCleanup() throws {
        try file("Downloads/a.txt"); try file("Downloads/b.txt")
        let found = try scanner.scan(options())
        let keeper = try XCTUnwrap(found.files.first(where: \.keeper))
        try FileManager.default.removeItem(at: keeper.url)
        XCTAssertThrowsError(try scanner.validateSelection(found.files.filter { !$0.keeper }, all: found.files, folders: [downloads]))
    }
    func testSymlinksHardLinksCloudAndPackagesAreExcluded() throws {
        let original = try file("Downloads/a.txt")
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("link.txt"), withDestinationURL: original)
        try FileManager.default.linkItem(at: original, to: downloads.appendingPathComponent("hard.txt"))
        try file("Downloads/Dropbox/cloud.txt")
        try file("Downloads/Test.app/Contents/data.txt")
        try file("Downloads/Pictures.photoslibrary/data.txt")
        try file("Downloads/.git/data.txt")
        let protected = home.appendingPathComponent("Library/Mobile Documents")
        XCTAssertFalse(scanner.allowed(protected))
        XCTAssertTrue(try scanner.scan(options()).files.isEmpty)
    }
    func testSymlinkAncestorIsRejected() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let link = downloads.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(scanner.allowed(link.appendingPathComponent("secret.txt")))
        XCTAssertTrue(try scanner.scan(options()).files.isEmpty)
    }
    func testBrowserAllowlistExcludesCredentialsAndHistory() throws {
        let cache = try file("Library/Application Support/Google/Chrome/Default/Cache/data")
        try file("Library/Application Support/Google/Chrome/Default/Login Data")
        try file("Library/Application Support/Google/Chrome/Default/History")
        try age(cache, days: 3)
        var options = options(); options.browsers = true
        let found = try scanner.scan(options)
        XCTAssertEqual(found.files.map(\.url), [cache])
        let credentials = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Login Data")
        let forged = Candidate(url: credentials, category: .browsers, fingerprint: try Fingerprint.read(credentials))
        XCTAssertThrowsError(try scanner.validateLocation(forged, folders: [downloads]))
    }
    func testRunningBrowserPreventsTrash() async throws {
        let cache = try file("Library/Caches/com.apple.Safari/cache-data")
        try age(cache, days: 3)
        var options = options(); options.browsers = true
        let found = try scanner.scan(options)
        XCTAssertEqual(found.files.count, 1)
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json"))
        let outcome = try await service.clean(found.files, all: found.files, folders: [downloads], browsersRunning: { true }, moveToTrash: { _ in
            XCTFail("Browser cache must not be moved while a browser is running"); throw SafetyError.browserRunning
        })
        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }
    func testWholeBatchValidatesBeforeAnyMove() async throws {
        try file("Downloads/first-a.txt", "first group contents")
        try file("Downloads/first-b.txt", "first group contents")
        try file("Downloads/second-a.txt", "second group contents are longer")
        try file("Downloads/second-b.txt", "second group contents are longer")
        let found = try scanner.scan(options())
        let validCopy = try XCTUnwrap(found.files.first { !$0.keeper && $0.url.lastPathComponent.hasPrefix("first-") })
        let unsafeCopy = try XCTUnwrap(found.files.first { !$0.keeper && $0.url.lastPathComponent.hasPrefix("second-") })
        try FileManager.default.removeItem(at: unsafeCopy.url)
        try FileManager.default.createSymbolicLink(at: unsafeCopy.url, withDestinationURL: validCopy.url)
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json"))
        do {
            _ = try await service.clean([validCopy, unsafeCopy], all: found.files, folders: [downloads], browsersRunning: { false }, moveToTrash: { _ in
                XCTFail("No move should occur after validation fails"); throw SafetyError.keeper
            })
            XCTFail("Expected rejection")
        } catch { }
        XCTAssertTrue(try service.records().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: validCopy.url.path))
    }
    func testTrashJournalRestoreAndNoOverwrite() async throws {
        try file("Downloads/a.txt"); try file("Downloads/b.txt")
        let found = try scanner.scan(options())
        let copy = try XCTUnwrap(found.files.first { !$0.keeper })
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json"))
        let trashDestination = root.appendingPathComponent("fake-trash.txt")
        let outcome = try await service.clean([copy], all: found.files, folders: [downloads], browsersRunning: { false }, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: trashDestination); return trashDestination
        })
        XCTAssertEqual(outcome.count, 1)
        let record = try XCTUnwrap(service.records().first)
        try Data("new user work".utf8).write(to: copy.url)
        XCTAssertThrowsError(try service.restore(record))
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "new user work")
        try FileManager.default.removeItem(at: copy.url)
        try service.restore(record)
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "identical content")
        XCTAssertTrue(try service.records().isEmpty)
    }
}
