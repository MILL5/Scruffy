import XCTest
@testable import CleanupCore
@testable import Scruffy

final class KeepOriginalAndSettingsTests: XCTestCase, @unchecked Sendable {
    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func release() { released = true; waiting?.resume(); waiting = nil }
    }

    private func candidate(_ name: String, category: CleanupCategory = .duplicates, bytes: Int64 = 10,
                           hash: String? = "same-content", keeper: Bool = false) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: category,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0),
                                           device: 1, inode: 1, links: 1),
                  duplicateHash: hash, keeper: keeper)
    }
    private func defaults() -> (UserDefaults, String) {
        let name = "scruffy-tests-\(UUID())"
        return (UserDefaults(suiteName: name)!, name)
    }

    @MainActor
    func testKeepInsteadProtectsTheChosenCopyAndOffersTheOldOriginal() async {
        let model = AppModel(loadHistory: false)
        let original = candidate("original", keeper: true)
        let first = candidate("copy-1"), second = candidate("copy-2")
        let other = candidate("unrelated", category: .downloads, hash: nil)
        model.result = ScanResult(files: [original, first, second, other], notes: [])
        model.selection = [first.id, second.id, other.id]

        XCTAssertTrue(model.canKeepInstead(first))
        XCTAssertFalse(model.canKeepInstead(original))
        XCTAssertFalse(model.canKeepInstead(other))
        await model.keepInstead(first)

        XCTAssertEqual(model.result?.keepersByHash["same-content"]?.id, first.id)
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [first.id])
        XCTAssertEqual(model.result?.duplicateCounts["same-content"], 3)
        // The newly protected copy leaves the selection; everything else stays as chosen.
        XCTAssertEqual(model.selection, [second.id, other.id])
        XCTAssertEqual(Set(model.chosen.map(\.id)), [second.id, other.id])
        XCTAssertEqual(model.count(.duplicates), 2)
        XCTAssertTrue(model.fullySelectedGroups.isEmpty)
        // The previous original is now an ordinary copy; the protected one cannot be selected alone.
        let demoted = try? XCTUnwrap(model.result?.filesByID[original.id])
        XCTAssertEqual(demoted?.keeper, false)
        if let demoted { model.setSelection(demoted, selected: true) }
        XCTAssertTrue(model.selection.contains(original.id))
        if let protected = model.result?.filesByID[first.id] { model.setSelection(protected, selected: true) }
        XCTAssertFalse(model.selection.contains(first.id))
        XCTAssertFalse(model.canKeepInstead(first))
    }

    @MainActor
    func testChosenOriginalSurvivesLaterScanResultsAndCleanupRefresh() async {
        let model = AppModel(loadHistory: false)
        let original = candidate("original", keeper: true)
        let first = candidate("copy-1"), second = candidate("copy-2")
        await model.publish(ScanResult(files: [original, first, second], notes: []))
        await model.keepInstead(second)
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [second.id])

        // A later snapshot of the same scan still carries the scanner's own pick.
        let late = candidate("late-download", category: .downloads, bytes: 99, hash: nil)
        await model.publish(ScanResult(files: [late, original, first, second], notes: []))
        XCTAssertEqual(model.files.count, 4)
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [second.id])

        // The old original was cleaned as a copy: the chosen one remains protected.
        var outcome = CleanupOutcome()
        outcome.count = 1; outcome.movedIDs = [original.id]
        await model.applyCleanupOutcome(outcome)
        XCTAssertEqual(Set(model.files.map(\.id)), [late.id, first.id, second.id])
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [second.id])

        // Changed scan settings start over with the scanner's choice.
        model.invalidate()
        await model.publish(ScanResult(files: [original, first, second], notes: []))
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [original.id])
    }

    /// Another publication can overtake the one carrying the choice, and then be cancelled itself.
    /// The choice must still land, and results must never disagree with the recorded choice.
    @MainActor
    func testChosenOriginalLandsEvenWhenItsPublicationIsOvertaken() async {
        let model = AppModel(loadHistory: false)
        let original = candidate("original", keeper: true)
        let first = candidate("copy-1"), second = candidate("copy-2")
        let unrelated = candidate("unrelated", category: .downloads, hash: nil)
        let snapshot = ScanResult(files: [original, first, second, unrelated], notes: [])
        await model.publish(snapshot)
        // A removed file makes every later publication rebuild its results off the main actor.
        var outcome = CleanupOutcome()
        outcome.count = 1; outcome.movedIDs = [unrelated.id]
        await model.applyCleanupOutcome(outcome)

        let keep = Task { @MainActor in await model.keepInstead(first) }
        let overtaking = Task { @MainActor in _ = await model.publish(snapshot, final: true, recordsSource: false) }
        overtaking.cancel()
        await keep.value; await overtaking.value
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [first.id])

        // Cleaning the old original and then a copy leaves exactly one protected file throughout.
        await model.keepInstead(second)
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [second.id])
        outcome.movedIDs = [original.id]
        await model.applyCleanupOutcome(outcome)
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [second.id])
        outcome.movedIDs = [first.id]
        await model.applyCleanupOutcome(outcome)
        XCTAssertEqual(model.files.map(\.id), [second.id])
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [second.id])
    }

    @MainActor
    func testOriginalCannotBeChangedWhileItsGroupIsBeingCleaned() async {
        let gate = Gate()
        let started = expectation(description: "Cleanup job is running")
        let model = AppModel(loadHistory: false, cleanupRunner: { selected, _, _, _ in
            started.fulfill()
            await gate.wait()
            var outcome = CleanupOutcome()
            outcome.count = selected.count; outcome.movedIDs = selected.map(\.id)
            return outcome
        })
        let original = candidate("original", keeper: true)
        let first = candidate("copy-1"), second = candidate("copy-2")
        model.result = ScanResult(files: [original, first, second], notes: [])
        model.selection = [first.id]
        model.clean()
        await fulfillment(of: [started], timeout: 3)

        XCTAssertFalse(model.canKeepInstead(second))
        await model.keepInstead(second)
        XCTAssertEqual(model.files.filter(\.keeper).map(\.id), [original.id])
        await gate.release()
    }

    @MainActor
    func testRestoringOneFileKeepsTheScanResultsAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), downloads = home.appendingPathComponent("Downloads")
        let trash = root.appendingPathComponent("fake-trash")
        for folder in [downloads, trash] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("support/trash-history.json"))
        func old(_ name: String) throws -> Candidate {
            let url = downloads.appendingPathComponent(name)
            try Data("contents of \(name)".utf8).write(to: url)
            let seconds = Int(Date().timeIntervalSince1970) - 40 * 86400
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            XCTAssertEqual(utimes(url.path, &times), 0)
            return Candidate(url: url, category: .downloads, fingerprint: try Fingerprint.read(url))
        }
        let cleaned = try old("cleaned.txt"), first = try old("first.txt"), second = try old("second.txt")
        let outcome = try await service.clean([cleaned], all: [cleaned, first, second], folders: [downloads],
                                              browsersRunning: { false }, moveToTrash: { url in
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        XCTAssertEqual(outcome.movedIDs, [cleaned.id])

        let model = AppModel(loadHistory: false, trashService: service)
        model.result = ScanResult(files: [first, second], notes: [])
        model.hasScanned = true
        model.selection = [first.id]
        model.restore(try XCTUnwrap(try service.records().first))

        XCTAssertNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.url.path))
        XCTAssertTrue(try service.records().isEmpty)
        XCTAssertEqual(Set(model.files.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertTrue(model.hasScanned)
        XCTAssertTrue(model.status.contains("Restored cleaned.txt"))
    }

    @MainActor
    func testTidyingRecoveryHistoryIsLeftToTheAppAndRunsAgainstItsOwnJournal() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-tidy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), trash = root.appendingPathComponent("fake-trash")
        for folder in [home, trash] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let journalURL = root.appendingPathComponent("support/trash-history.json")
        let service = TrashService(scanner: CleanupScanner(home: home, temp: root.appendingPathComponent("temp")), journal: journalURL)
        // The file was on the Trash folder's volume and is no longer in that folder.
        let gone = trash.appendingPathComponent("gone.txt")
        try Data("x".utf8).write(to: gone)
        let fingerprint = try Fingerprint.read(gone)
        try FileManager.default.removeItem(at: gone)
        let journal = TrashJournal(url: journalURL)
        try journal.append(TrashRecord(id: UUID(), original: home.appendingPathComponent("gone.txt"),
                                       trashed: gone, fingerprint: fingerprint, date: Date()))
        // A model that does not load history never tidies it.
        await AppModel(loadHistory: false, trashService: service).tidyRecoveryHistory()
        XCTAssertEqual(try service.records().count, 1)

        let model = AppModel(loadHistory: true, jobHistoryURL: root.appendingPathComponent("jobs.json"), trashService: service)
        await model.tidyRecoveryHistory()
        XCTAssertTrue(try service.records().isEmpty)
    }

    @MainActor
    func testScanChoicesAreRememberedBetweenLaunches() {
        let (settings, suite) = defaults()
        defer { settings.removePersistentDomain(forName: suite) }
        let first = AppModel(loadHistory: false, settings: settings)
        first.options.videos = false
        first.options.browsers = false
        first.options.folders = []

        let second = AppModel(loadHistory: false, settings: settings)
        XCTAssertFalse(second.options.videos)
        XCTAssertFalse(second.options.browsers)
        XCTAssertTrue(second.options.duplicates)
        XCTAssertTrue(second.options.large)
        XCTAssertTrue(second.options.folders.isEmpty)

        // Without a settings store nothing is read or written.
        let unsaved = AppModel(loadHistory: false)
        unsaved.options.large = false
        XCTAssertTrue(AppModel(loadHistory: false).options.large)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: AppModel.optionsKey))
    }

    @MainActor
    func testSavedFoldersAreCheckedAgainAndUnsafeOnesAreLeftOut() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let documents = home.appendingPathComponent("Documents"), outside = root.appendingPathComponent("outside")
        let library = home.appendingPathComponent("Library/Caches/Thing"), link = home.appendingPathComponent("Linked")
        for folder in [documents, outside, library] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
        let (settings, suite) = defaults()
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertNil(AppModel.savedOptions(in: settings, scanner: scanner))

        settings.set(["folders": [documents.path, home.appendingPathComponent("Removed").path, outside.path, library.path, link.path],
                      "caches": false], forKey: AppModel.optionsKey)
        let options = try XCTUnwrap(AppModel.savedOptions(in: settings, scanner: scanner))
        XCTAssertEqual(options.folders.map(\.path), [documents.path])
        XCTAssertFalse(options.caches)
        XCTAssertTrue(options.duplicates)   // A choice missing from older saved settings stays on.
    }
}
