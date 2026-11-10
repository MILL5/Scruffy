import XCTest
import Darwin
@testable import CleanupCore

final class VolumeAndOriginalTests: XCTestCase, @unchecked Sendable {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CleanupProgress] = []
        func add(_ update: CleanupProgress) { lock.lock(); values.append(update); lock.unlock() }
        var snapshots: [CleanupProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private var root: URL!
    private var home: URL!
    private var downloads: URL!
    private var documents: URL!
    private var scanner: CleanupScanner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-volume-\(UUID())")
        home = root.appendingPathComponent("home")
        downloads = home.appendingPathComponent("Downloads")
        documents = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ url: URL, _ text: String = "identical content", daysOld: Int = 0) throws -> URL {
        try Data(text.utf8).write(to: url)
        let seconds = Int(Date().timeIntervalSince1970) - daysOld * 86400
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        guard utimes(url.path, &times) == 0 else { throw POSIXError(.EIO) }
        return url
    }
    private func options(_ folders: [URL]) -> ScanOptions {
        var options = ScanOptions(folders: folders)
        options.browsers = false; options.caches = false; options.temporary = false; options.videos = false
        return options
    }
    private func hdiutil(_ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func testFilesOnAnotherVolumeMountedInsideHomeAreExcluded() throws {
        let image = root.appendingPathComponent("other.dmg")
        let mount = downloads.appendingPathComponent("Mounted")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard try hdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", "ScruffyTest", image.path]),
              try hdiutil(["attach", image.path, "-mountpoint", mount.path, "-nobrowse"]) else {
            throw XCTSkip("Disk images cannot be mounted in this environment.")
        }
        defer { _ = try? hdiutil(["detach", mount.path, "-force"]) }
        let mounted = try file(mount.appendingPathComponent("a.txt"))
        try file(downloads.appendingPathComponent("b.txt"))
        try file(downloads.appendingPathComponent("c.txt"))

        XCTAssertFalse(scanner.allowed(mounted))
        XCTAssertFalse(scanner.allowed(mount))
        XCTAssertTrue(scanner.allowed(downloads.appendingPathComponent("b.txt")))
        let found = try scanner.scan(options([downloads]))
        XCTAssertEqual(Set(found.files.map(\.url.lastPathComponent)), ["b.txt", "c.txt"])
        // A file that was listed stays ineligible if its location is on another volume at cleanup time.
        let foreign = Candidate(url: mounted, category: .downloads, fingerprint: try Fingerprint.read(mounted))
        XCTAssertThrowsError(try scanner.validateLocation(foreign, folders: [downloads]))
        // Choosing the mounted volume itself as a folder finds nothing and says why.
        let direct = try scanner.scan(options([mount]))
        XCTAssertTrue(direct.files.isEmpty)
        XCTAssertTrue(direct.notes.contains { $0.hasPrefix("Skipped protected location") })
    }

    /// Swift treats a slash followed by a combining mark, or preceded by a prepending mark, as one
    /// character. Folder boundaries must still be found there, or that folder escapes every check.
    func testNamesThatFuseWithTheSlashDoNotHideAProtectedFolder() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try file(outside.appendingPathComponent("\u{301}secret.txt"))
        try file(outside.appendingPathComponent("plain.txt"))
        let link = downloads.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(scanner.allowed(link.appendingPathComponent("\u{301}secret.txt")))
        let prepending = downloads.appendingPathComponent("linked\u{600}")
        try FileManager.default.createSymbolicLink(at: prepending, withDestinationURL: outside)
        XCTAssertFalse(scanner.allowed(prepending.appendingPathComponent("plain.txt")))

        for folder in ["Downloads/node_modules", "Downloads/Tool.app", ".ssh", "Library/Mail"] {
            let directory = home.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let hidden = try file(directory.appendingPathComponent("\u{301}x.txt"))
            XCTAssertFalse(scanner.allowed(hidden), folder)
        }
        // Library stays out of personal-folder results even for such a name directly inside it.
        let odd = home.appendingPathComponent("Library/\u{301}odd")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let inLibrary = try file(odd.appendingPathComponent("a.txt"))
        try file(odd.appendingPathComponent("b.txt"))
        XCTAssertTrue(scanner.isInLibrary(inLibrary))
        XCTAssertFalse(scanner.isInLibrary(downloads.appendingPathComponent("a.txt")))
        let candidate = Candidate(url: inLibrary, category: .downloads, fingerprint: try Fingerprint.read(inLibrary))
        XCTAssertThrowsError(try scanner.validateLocation(candidate, folders: [home]))

        // An ordinary file with such a name in an ordinary folder is still eligible.
        let ordinary = try file(documents.appendingPathComponent("\u{301}notes.txt"))
        try file(documents.appendingPathComponent("notes-copy.txt"))
        XCTAssertTrue(scanner.allowed(ordinary))
        // Scanning the whole home folder lists that pair and nothing from the protected places.
        let found = try scanner.scan(options([scanner.home]))
        XCTAssertFalse(found.notes.contains { $0.hasPrefix("Skipped protected location") })
        XCTAssertEqual(Set(found.files.map(\.url.lastPathComponent)), ["\u{301}notes.txt", "notes-copy.txt"])
    }

    func testScanActivityReportsOnlyAListingThatHasWaitedLongEnough() throws {
        let activity = ScanActivity()
        XCTAssertNil(activity.waiting(atLeast: .zero))
        activity.willList("/somewhere/Documents")
        XCTAssertEqual(activity.waiting(atLeast: .zero), "/somewhere/Documents")
        XCTAssertNil(activity.waiting(atLeast: .seconds(60)))
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertEqual(activity.waiting(atLeast: .milliseconds(50)), "/somewhere/Documents")
        activity.didList()
        XCTAssertNil(activity.waiting(atLeast: .zero))

        // A scan that runs to the end leaves nothing waiting.
        try file(downloads.appendingPathComponent("a.txt")); try file(downloads.appendingPathComponent("b.txt"))
        XCTAssertEqual(try scanner.scan(options([downloads]), activity: activity).files.count, 2)
        XCTAssertNil(activity.waiting(atLeast: .zero))
    }

    /// Recovery records are dropped only when nothing can be restored from them for certain.
    func testHistoryTidyDropsOnlyRecordsThatAreCertainlyBeyondRecovery() async throws {
        let trash = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let journalURL = root.appendingPathComponent("support/trash-history.json")
        let service = TrashService(scanner: scanner, journal: journalURL)
        var candidates: [Candidate] = []
        for name in ["still-in-trash.txt", "emptied.txt", "put-back.txt"] {
            let url = try file(downloads.appendingPathComponent(name), "contents of \(name)", daysOld: 40)
            candidates.append(Candidate(url: url, category: .downloads, fingerprint: try Fingerprint.read(url)))
        }
        let outcome = try await service.clean(candidates, all: candidates, folders: [downloads], browsersRunning: { false },
                                              moveToTrash: { url in
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        XCTAssertEqual(outcome.count, 3)
        try FileManager.default.removeItem(at: trash.appendingPathComponent("emptied.txt"))
        try FileManager.default.moveItem(at: trash.appendingPathComponent("put-back.txt"), to: downloads.appendingPathComponent("put-back.txt"))

        let journal = TrashJournal(url: journalURL)
        func intent(_ url: URL, fingerprint: Fingerprint) -> TrashRecord {
            TrashRecord(id: UUID(), original: url, trashed: nil, fingerprint: fingerprint, date: Date())
        }
        // Interrupted before the move: the original is still the same file in place.
        let untouched = try file(downloads.appendingPathComponent("never-moved.txt"), daysOld: 40)
        let neverMoved = intent(untouched, fingerprint: try Fingerprint.read(untouched))
        // Interrupted after the move: the original is gone and only Finder's Trash can help.
        let lost = intent(downloads.appendingPathComponent("moved-without-record.txt"),
                          fingerprint: Fingerprint(size: 9, modified: Date(timeIntervalSince1970: 5), device: 1, inode: 2, links: 1))
        // The Trash folder itself is not there, as with an unmounted volume: nothing is proven.
        var unmounted = intent(downloads.appendingPathComponent("on-unmounted-volume.txt"), fingerprint: lost.fingerprint)
        unmounted.trashed = root.appendingPathComponent("missing-volume/.Trashes/501/on-unmounted-volume.txt")
        for record in [neverMoved, lost, unmounted] { try journal.append(record) }
        XCTAssertEqual(try service.records().count, 6)

        XCTAssertEqual(try service.tidyHistory(), 3)

        XCTAssertEqual(Set(try service.records().map(\.original.lastPathComponent)),
                       ["still-in-trash.txt", "moved-without-record.txt", "on-unmounted-volume.txt"])
        XCTAssertEqual(try service.tidyHistory(), 0)
        // What is still in Trash can still be restored afterwards.
        let record = try XCTUnwrap(try service.records().first { $0.original.lastPathComponent == "still-in-trash.txt" })
        try service.restore(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("still-in-trash.txt").path))
        XCTAssertEqual(try service.records().count, 2)
    }

    func testCloudPlaceholderFlagIsRecognized() {
        XCTAssertTrue(CleanupScanner.isCloudPlaceholder(flags: UInt32(SF_DATALESS)))
        XCTAssertTrue(CleanupScanner.isCloudPlaceholder(flags: UInt32(SF_DATALESS) | UInt32(UF_HIDDEN)))
        XCTAssertFalse(CleanupScanner.isCloudPlaceholder(flags: UInt32(UF_COMPRESSED) | UInt32(UF_HIDDEN)))
    }

    func testLargeFileThresholdMatchesTheDisplayed500MB() throws {
        for (name, bytes) in [("exactly-500-MB.bin", 500_000_000), ("just-under.bin", 499_999_999)] {
            let url = documents.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))   // Sparse: nothing is allocated or read.
            try handle.close()
        }
        var options = options([documents]); options.duplicates = false
        let found = try scanner.scan(options)
        XCTAssertEqual(found.files.map(\.url.lastPathComponent), ["exactly-500-MB.bin"])
        XCTAssertEqual(found.files.first?.category, .large)
        XCTAssertEqual(CleanupScanner.largeFileBytes, 500_000_000)
    }

    func testOriginalOutsideDownloadsIsProtectedEvenWhenTheDownloadIsOlder() throws {
        try file(downloads.appendingPathComponent("report.pdf"), daysOld: 20)
        try file(downloads.appendingPathComponent("report (1).pdf"), daysOld: 10)
        let filed = try file(documents.appendingPathComponent("report.pdf"), daysOld: 1)
        let found = try scanner.scan(options([downloads, documents]))
        XCTAssertEqual(found.files.count, 3)
        XCTAssertEqual(found.files.filter(\.keeper).map(\.url.path), [filed.standardizedFileURL.path])
    }

    func testOldestCopyIsProtectedWhenEveryCopyIsInDownloads() throws {
        try file(downloads.appendingPathComponent("b-newer.txt"), daysOld: 5)
        try file(downloads.appendingPathComponent("a-newest.txt"), daysOld: 1)
        try file(downloads.appendingPathComponent("c-oldest.txt"), daysOld: 30)
        let found = try scanner.scan(options([downloads]))
        XCTAssertEqual(found.files.filter(\.keeper).map(\.url.lastPathComponent), ["c-oldest.txt"])
    }

    func testFolderWithoutReadPermissionIsReportedAsAPermissionNote() throws {
        let locked = documents.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try file(locked.appendingPathComponent("hidden.txt"))
        try file(documents.appendingPathComponent("visible-a.txt"))
        try file(documents.appendingPathComponent("visible-b.txt"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { chmod(locked.path, 0o700) }
        guard getuid() != 0 else { throw XCTSkip("Root can read every folder.") }

        let found = try scanner.scan(options([documents]))
        XCTAssertEqual(Set(found.files.map(\.url.lastPathComponent)), ["visible-a.txt", "visible-b.txt"])
        let denied = found.notes.filter { $0.hasPrefix(CleanupScanner.permissionNotePrefix) }
        XCTAssertEqual(denied.count, 1)
        XCTAssertTrue(denied.first?.hasSuffix("/Documents/Locked") == true)
        XCTAssertEqual(found.permissionDeniedCount, 1)
    }

    /// After "Keep this copy instead", cleanup protects whichever file carries the original flag.
    func testCleanupVerifiesCopiesAgainstTheOriginalTheUserChose() async throws {
        try file(documents.appendingPathComponent("a.txt"), daysOld: 30)
        try file(downloads.appendingPathComponent("b.txt"), daysOld: 20)
        let found = try scanner.scan(options([downloads, documents]))
        let scanned = try XCTUnwrap(found.files.first(where: \.keeper))
        XCTAssertEqual(scanned.url.lastPathComponent, "a.txt")
        // Swap the flags, as the app does when the user keeps the Downloads copy.
        let swapped = found.files.map { item -> Candidate in var item = item; item.keeper.toggle(); return item }
        let demoted = try XCTUnwrap(swapped.first { !$0.keeper }), chosen = try XCTUnwrap(swapped.first(where: \.keeper))
        let trash = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json"))

        let outcome = try await service.clean([demoted], all: swapped, folders: [downloads, documents],
                                              browsersRunning: { false }, moveToTrash: { url in
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })

        XCTAssertEqual(outcome.movedIDs, [demoted.id])
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scanned.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.url.path))
        // The chosen original alone can never be cleaned.
        await XCTAssertThrowsErrorAsync(try await service.clean([chosen], all: swapped, folders: [downloads, documents],
                                                               browsersRunning: { false }, moveToTrash: { $0 }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.url.path))
    }

    private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) } catch { }
    }

    /// The pass over the whole batch checks locations and fingerprints only. Contents are read
    /// once, right before each move, so a silently changed original is caught there.
    func testDuplicateContentsAreVerifiedJustBeforeEachMoveNotInTheBatchPass() async throws {
        let text = "identical contents"
        let original = try file(documents.appendingPathComponent("original.txt"), text, daysOld: 40)
        let hash = try scanner.digest(original)
        let keeper = Candidate(url: original, category: .duplicates, fingerprint: try Fingerprint.read(original),
                               duplicateHash: hash, keeper: true)
        let copyURL = try file(downloads.appendingPathComponent("copy.txt"), text, daysOld: 40)
        let copy = Candidate(url: copyURL, category: .duplicates, fingerprint: try Fingerprint.read(copyURL), duplicateHash: hash)
        // Same size and modification time, different bytes.
        let handle = try FileHandle(forWritingTo: original)
        try handle.write(contentsOf: Data(repeating: 90, count: Int(keeper.bytes)))
        try handle.close()
        let seconds = Int(keeper.fingerprint.modified.timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(original.path, &times), 0)
        XCTAssertEqual(try Fingerprint.read(original), keeper.fingerprint)

        let updates = Updates()
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json"))
        let outcome = try await service.clean([copy], all: [keeper, copy], folders: [downloads, documents],
                                              browsersRunning: { false }, progress: { updates.add($0) },
                                              moveToTrash: { _ in XCTFail("Nothing may move"); throw POSIXError(.EIO) })

        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.skippedIDs, [copy.id])
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertTrue(try service.records().isEmpty)
        // The batch pass approved the file; the skip happened in the moving phase.
        let moving = updates.snapshots.filter { $0.phase == .moving }
        XCTAssertEqual(moving.first?.skipped, 0)
        XCTAssertEqual(moving.last?.skipped, 1)
    }
}
