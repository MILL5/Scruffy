import XCTest
import Darwin
@testable import CleanupCore

final class BrowserCacheCleanupTests: XCTestCase, @unchecked Sendable {
    private final class Moves: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []
        func add(_ url: URL) { lock.lock(); values.append(url); lock.unlock() }
        var sources: [URL] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private final class BrowserState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func setRunning() { lock.lock(); value = true; lock.unlock() }
        func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private var root: URL!
    private var home: URL!
    private var downloads: URL!
    private var scanner: CleanupScanner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scruffy-browser-cleanup-\(UUID())")
        home = root.appendingPathComponent("home")
        downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func file(_ path: String, text: String = "original cache data", daysOld: Int = 3) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let seconds = Int(Date().timeIntervalSince1970) - daysOld * 86400
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        guard utimes(url.path, &times) == 0 else { throw POSIXError(.EIO) }
        return url
    }

    private func cache(_ name: String) throws -> Candidate {
        let url = try file("Library/Caches/com.apple.Safari/\(name)")
        return Candidate(url: url, category: .browsers, fingerprint: try Fingerprint.read(url))
    }

    private func personal(_ name: String, category: CleanupCategory = .downloads) throws -> Candidate {
        let url = try file("Downloads/\(name)", text: "personal file contents", daysOld: 40)
        return Candidate(url: url, category: category, fingerprint: try Fingerprint.read(url))
    }

    private func duplicateGroup(_ name: String, copies: Int = 2) throws -> (keeper: Candidate, copies: [Candidate]) {
        let text = "identical contents for \(name)"
        let original = try file("Downloads/\(name)-original.txt", text: text, daysOld: 40)
        let hash = try scanner.digest(original)
        let keeper = Candidate(url: original, category: .duplicates, fingerprint: try Fingerprint.read(original),
                               duplicateHash: hash, keeper: true)
        let candidates = try (0..<copies).map { index in
            let url = try file("Downloads/\(name)-copy-\(index).txt", text: text, daysOld: 40)
            return Candidate(url: url, category: .duplicates, fingerprint: try Fingerprint.read(url), duplicateHash: hash)
        }
        return (keeper, candidates)
    }

    private func service() -> TrashService {
        TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json"))
    }

    private func fakeTrash(_ moves: Moves) throws -> @Sendable (URL) throws -> URL {
        let directory = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return { url in
            moves.add(url)
            let destination = directory.appendingPathComponent("\(UUID())-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private func assertUnsafeBatchRejectsBeforeAnyMove(_ selected: [Candidate],
                                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let service = service(), moves = Moves(), mover = try fakeTrash(moves)
        var rejected = false
        do {
            let outcome = try await service.clean(selected, all: selected, folders: [downloads],
                                                  browsersRunning: { false }, moveToTrash: mover)
            rejected = !outcome.errors.isEmpty
            XCTAssertEqual(outcome.count, 0, file: file, line: line)
            XCTAssertTrue(outcome.skippedIDs.isEmpty, file: file, line: line)
        } catch { rejected = true }
        XCTAssertTrue(rejected, "Unsafe existing files must be rejected, not treated as stale caches", file: file, line: line)
        XCTAssertTrue(moves.sources.isEmpty, file: file, line: line)
        XCTAssertTrue(try service.records().isEmpty, file: file, line: line)
    }

    func testChangedFirstCacheIsLeftUntouchedWhileUnchangedCacheMoves() async throws {
        let changed = try cache("changed"), unchanged = try cache("unchanged")
        let replacement = "new browser-written cache contents"
        try Data(replacement.utf8).write(to: changed.url)
        let service = service(), moves = Moves()

        let outcome = try await service.clean([changed, unchanged], all: [changed, unchanged], folders: [downloads],
                                              browsersRunning: { false }, moveToTrash: try fakeTrash(moves))

        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.bytes, unchanged.bytes)
        XCTAssertEqual(outcome.movedIDs, [unchanged.id])
        XCTAssertEqual(outcome.skippedIDs, [changed.id])
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(moves.sources, [unchanged.url])
        XCTAssertEqual(try String(contentsOf: changed.url, encoding: .utf8), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unchanged.url.path))
        let records = try service.records()
        XCTAssertEqual(records.map(\.original), [unchanged.url])
        XCTAssertNotNil(records.first?.trashed)
    }

    func testSeveralChangedAndDeletedCachesAreSkippedOnceWithoutFakeHistory() async throws {
        let changedA = try cache("changed-a"), changedB = try cache("changed-b")
        let deletedA = try cache("deleted-a"), deletedB = try cache("deleted-b")
        let selected = [changedA, deletedA, changedB, deletedB]
        try Data("changed A".utf8).write(to: changedA.url)
        try Data("changed B".utf8).write(to: changedB.url)
        try FileManager.default.removeItem(at: deletedA.url)
        try FileManager.default.removeItem(at: deletedB.url)
        let service = service(), moves = Moves()

        let outcome = try await service.clean(selected, all: selected, folders: [downloads],
                                              browsersRunning: { false }, moveToTrash: try fakeTrash(moves))

        XCTAssertEqual(Set(outcome.skippedIDs), Set(selected.map(\.id)))
        XCTAssertEqual(outcome.skippedIDs.count, selected.count)
        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.bytes, 0)
        XCTAssertTrue(outcome.movedIDs.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertTrue(moves.sources.isEmpty)
        XCTAssertTrue(try service.records().isEmpty)
        XCTAssertEqual(try String(contentsOf: changedA.url, encoding: .utf8), "changed A")
        XCTAssertEqual(try String(contentsOf: changedB.url, encoding: .utf8), "changed B")
    }

    func testCachesChangedOrDeletedBetweenMovesAreSkippedAndLaterCacheStillMoves() async throws {
        let first = try cache("first"), changed = try cache("changed-later")
        let deleted = try cache("deleted-later"), last = try cache("last")
        let selected = [first, changed, deleted, last]
        let service = service(), moves = Moves(), mover = try fakeTrash(moves)
        let replacement = "cache changed after cleanup started"

        let outcome = try await service.clean(selected, all: selected, folders: [downloads], browsersRunning: { false }, moveToTrash: { url in
            let destination = try mover(url)
            if url == first.url {
                try Data(replacement.utf8).write(to: changed.url)
                try FileManager.default.removeItem(at: deleted.url)
            }
            return destination
        })

        XCTAssertEqual(outcome.count, 2)
        XCTAssertEqual(outcome.bytes, first.bytes + last.bytes)
        XCTAssertEqual(outcome.movedIDs, [first.id, last.id])
        XCTAssertEqual(Set(outcome.skippedIDs), [changed.id, deleted.id])
        XCTAssertEqual(outcome.skippedIDs.count, 2)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(moves.sources, [first.url, last.url])
        XCTAssertEqual(try String(contentsOf: changed.url, encoding: .utf8), replacement)
        XCTAssertEqual(Set(try service.records().map(\.original)), [first.url, last.url])
    }

    func testExistingCacheSymlinkAbortsWholeBatchBeforeAnyMove() async throws {
        let valid = try cache("valid"), unsafe = try cache("replaced-by-link")
        let target = try file("Documents/important.txt", text: "important user document")
        try FileManager.default.removeItem(at: unsafe.url)
        try FileManager.default.createSymbolicLink(at: unsafe.url, withDestinationURL: target)

        try await assertUnsafeBatchRejectsBeforeAnyMove([valid, unsafe])
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.url.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "important user document")
    }

    func testExistingHardlinkedCacheAbortsWholeBatchBeforeAnyMove() async throws {
        let valid = try cache("valid"), unsafe = try cache("now-hardlinked")
        let alias = downloads.appendingPathComponent("hardlink-to-cache")
        try FileManager.default.linkItem(at: unsafe.url, to: alias)

        try await assertUnsafeBatchRejectsBeforeAnyMove([valid, unsafe])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafe.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }

    func testDanglingSymlinkIsUnsafeExistingCacheRatherThanMissingCache() async throws {
        let valid = try cache("valid"), unsafe = try cache("dangling-link")
        let missingTarget = home.appendingPathComponent("Documents/missing-target.txt")
        try FileManager.default.removeItem(at: unsafe.url)
        try FileManager.default.createSymbolicLink(at: unsafe.url, withDestinationURL: missingTarget)

        try await assertUnsafeBatchRejectsBeforeAnyMove([valid, unsafe])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unsafe.url.path), missingTarget.path)
    }

    func testExistingNonAllowlistedBrowserPathAbortsWholeBatchBeforeAnyMove() async throws {
        let valid = try cache("valid")
        let credentials = try file("Library/Application Support/Google/Chrome/Default/Login Data")
        let forged = Candidate(url: credentials, category: .browsers, fingerprint: try Fingerprint.read(credentials))

        try await assertUnsafeBatchRejectsBeforeAnyMove([valid, forged])
        XCTAssertTrue(FileManager.default.fileExists(atPath: credentials.path))
    }

    func testChangedPersonalFileIsSkippedWhileValidBrowserCacheMoves() async throws {
        let validCache = try cache("valid")
        let url = try file("Downloads/important-download.txt", text: "old personal download", daysOld: 40)
        let personal = Candidate(url: url, category: .downloads, fingerprint: try Fingerprint.read(url))
        try Data("new personal work".utf8).write(to: url)
        let service = service(), moves = Moves()

        let outcome = try await service.clean([validCache, personal], all: [validCache, personal], folders: [downloads],
                                              browsersRunning: { false }, moveToTrash: try fakeTrash(moves))

        XCTAssertEqual(outcome.movedIDs, [validCache.id])
        XCTAssertEqual(outcome.skippedIDs, [personal.id])
        XCTAssertEqual(outcome.count, 1)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(moves.sources, [validCache.url])
        XCTAssertEqual(try service.records().map(\.original), [validCache.url])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new personal work")
    }

    func testChangedAndMissingDownloadsAndLargeFilesAreSkippedWhileValidItemsMove() async throws {
        for category in [CleanupCategory.downloads, .large] {
            let tag = category == .downloads ? "downloads" : "large"
            let valid = try personal("\(tag)-valid.txt", category: category)
            let changed = try personal("\(tag)-changed.txt", category: category)
            let deleted = try personal("\(tag)-deleted.txt", category: category)
            let selected = [valid, changed, deleted]
            try Data("new personal work".utf8).write(to: changed.url)
            try FileManager.default.removeItem(at: deleted.url)
            let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("\(tag)-journal.json"))
            let moves = Moves()

            let outcome = try await service.clean(selected, all: selected, folders: [downloads],
                                                  browsersRunning: { false }, moveToTrash: try fakeTrash(moves))

            XCTAssertEqual(outcome.count, 1)
            XCTAssertEqual(outcome.movedIDs, [valid.id])
            XCTAssertEqual(Set(outcome.skippedIDs), [changed.id, deleted.id])
            XCTAssertEqual(outcome.skippedIDs.count, 2)
            XCTAssertTrue(outcome.errors.isEmpty)
            XCTAssertEqual(moves.sources, [valid.url])
            XCTAssertEqual(try String(contentsOf: changed.url, encoding: .utf8), "new personal work")
            XCTAssertEqual(try service.records().map(\.original), [valid.url])
        }
    }

    func testChangedOrDeletedDuplicateKeeperSkipsDependentCopiesAndContinuesIndependentFiles() async throws {
        for deleteKeeper in [false, true] {
            let tag = deleteKeeper ? "deleted-keeper" : "changed-keeper"
            let group = try duplicateGroup(tag)
            let independent = try personal("\(tag)-independent.txt")
            let all = [group.keeper] + group.copies + [independent]
            let selected = [group.copies[0], independent, group.copies[1]]
            if deleteKeeper { try FileManager.default.removeItem(at: group.keeper.url) }
            else { try Data("changed original document".utf8).write(to: group.keeper.url) }
            let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("\(tag)-journal.json"))
            let moves = Moves()

            let outcome = try await service.clean(selected, all: all, folders: [downloads],
                                                  browsersRunning: { false }, moveToTrash: try fakeTrash(moves))

            XCTAssertEqual(outcome.count, 1)
            XCTAssertEqual(outcome.movedIDs, [independent.id])
            XCTAssertEqual(Set(outcome.skippedIDs), Set(group.copies.map(\.id)))
            XCTAssertEqual(outcome.skippedIDs.count, group.copies.count)
            XCTAssertTrue(outcome.errors.isEmpty)
            XCTAssertEqual(moves.sources, [independent.url])
            XCTAssertTrue(group.copies.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            XCTAssertEqual(try service.records().map(\.original), [independent.url])
        }
    }

    func testPersonalFilesChangedOrDeletedDuringCleanupAreSkippedAndLaterItemsContinue() async throws {
        let first = try personal("first.txt")
        let changed = try personal("changed-later.txt")
        let deleted = try personal("deleted-large.txt", category: .large)
        let last = try personal("last-large.txt", category: .large)
        let selected = [first, changed, deleted, last]
        let service = service(), moves = Moves(), mover = try fakeTrash(moves)

        let outcome = try await service.clean(selected, all: selected, folders: [downloads], browsersRunning: { false }, moveToTrash: { url in
            let destination = try mover(url)
            if url == first.url {
                try Data("new personal work".utf8).write(to: changed.url)
                try FileManager.default.removeItem(at: deleted.url)
            }
            return destination
        })

        XCTAssertEqual(outcome.count, 2)
        XCTAssertEqual(outcome.movedIDs, [first.id, last.id])
        XCTAssertEqual(Set(outcome.skippedIDs), [changed.id, deleted.id])
        XCTAssertEqual(outcome.skippedIDs.count, 2)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(moves.sources, [first.url, last.url])
        XCTAssertEqual(try String(contentsOf: changed.url, encoding: .utf8), "new personal work")
        XCTAssertEqual(Set(try service.records().map(\.original)), [first.url, last.url])
    }

    func testChangedDuplicateCopyWithMatchingFingerprintIsSkippedWhileOtherCopyMoves() async throws {
        let group = try duplicateGroup("same-fingerprint")
        let changed = group.copies[0], unchanged = group.copies[1]
        let handle = try FileHandle(forWritingTo: changed.url)
        try handle.write(contentsOf: Data(repeating: 90, count: Int(changed.bytes)))
        try handle.close()
        let seconds = Int(changed.fingerprint.modified.timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(changed.url.path, &times), 0)
        XCTAssertEqual(try Fingerprint.read(changed.url), changed.fingerprint)
        let service = service(), moves = Moves()

        let outcome = try await service.clean([changed, unchanged], all: [group.keeper] + group.copies, folders: [downloads],
                                              browsersRunning: { false }, moveToTrash: try fakeTrash(moves))

        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.movedIDs, [unchanged.id])
        XCTAssertEqual(outcome.skippedIDs, [changed.id])
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(moves.sources, [unchanged.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
        XCTAssertEqual(try service.records().map(\.original), [unchanged.url])
    }

    func testWholeDuplicateGroupCanBeRemovedWithOriginalMovedLast() async throws {
        let group = try duplicateGroup("whole-group", copies: 3)
        let all = [group.keeper] + group.copies
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("whole-group-journal.json"))
        let moves = Moves()
        let outcome = try await service.clean(all, all: all, folders: [downloads], browsersRunning: { false },
                                              moveToTrash: { moves.add($0); return $0 })
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
        XCTAssertEqual(outcome.count, 4)
        XCTAssertEqual(moves.sources.last, group.keeper.url)
        XCTAssertEqual(Set(moves.sources), Set(all.map(\.url)))
    }

    func testOriginalStaysProtectedWhenAnyCopyIsLeftOut() async throws {
        let group = try duplicateGroup("partial-group", copies: 3)
        let all = [group.keeper] + group.copies
        let service = TrashService(scanner: scanner, journal: root.appendingPathComponent("partial-group-journal.json"))
        let moves = Moves()
        do {
            _ = try await service.clean([group.keeper] + group.copies.dropLast(), all: all, folders: [downloads],
                                        browsersRunning: { false }, moveToTrash: { moves.add($0); return $0 })
            XCTFail("An original must not move while one of its copies is unselected")
        } catch { }
        XCTAssertTrue(moves.sources.isEmpty)
        XCTAssertTrue(all.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testExplicitlySelectedDuplicateKeeperStillAbortsBeforeAnyMove() async throws {
        let group = try duplicateGroup("protected-keeper")
        let independent = try personal("independent.txt")
        try await assertUnsafeBatchRejectsBeforeAnyMove([independent, group.keeper])
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: independent.url.path))
    }

    func testRunningBrowserBlocksBeforeSkippingStaleCachesOrMovingAnything() async throws {
        let changed = try cache("changed"), valid = try cache("valid")
        try Data("browser is still writing".utf8).write(to: changed.url)
        let service = service(), moves = Moves()

        let outcome = try await service.clean([changed, valid], all: [changed, valid], folders: [downloads],
                                              browsersRunning: { true }, moveToTrash: try fakeTrash(moves))

        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.skippedIDs.isEmpty)
        XCTAssertTrue(outcome.movedIDs.isEmpty)
        XCTAssertTrue(moves.sources.isEmpty)
        XCTAssertTrue(try service.records().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.url.path))
    }

    func testBrowserReopeningAfterFirstMoveStopsRemainingBatch() async throws {
        let first = try cache("first"), second = try cache("second"), third = try cache("third")
        let selected = [first, second, third]
        let service = service(), moves = Moves(), mover = try fakeTrash(moves), browser = BrowserState()

        let outcome = try await service.clean(selected, all: selected, folders: [downloads], browsersRunning: { browser.isRunning() }, moveToTrash: { url in
            let destination = try mover(url)
            browser.setRunning()
            return destination
        })

        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.movedIDs, [first.id])
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.skippedIDs.isEmpty)
        XCTAssertEqual(moves.sources, [first.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.url.path))
        XCTAssertEqual(try service.records().map(\.original), [first.url])
    }

    func testTrashMoveFailureStopsRatherThanBeingClassifiedAsStale() async throws {
        let first = try cache("first"), second = try cache("second")
        let service = service(), moves = Moves()

        let outcome = try await service.clean([first, second], all: [first, second], folders: [downloads], browsersRunning: { false }, moveToTrash: { url in
            moves.add(url)
            throw POSIXError(.EACCES)
        })

        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.skippedIDs.isEmpty)
        XCTAssertTrue(outcome.movedIDs.isEmpty)
        XCTAssertEqual(moves.sources, [first.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }
}
