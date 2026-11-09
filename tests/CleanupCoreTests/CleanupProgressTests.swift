import XCTest
import Darwin
@testable import CleanupCore

final class CleanupProgressTests: XCTestCase, @unchecked Sendable {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CleanupProgress] = []
        func add(_ update: CleanupProgress) { lock.lock(); values.append(update); lock.unlock() }
        var snapshots: [CleanupProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private actor StartBarrier {
        private var arrivals = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var timer: Task<Void, Never>?
        private(set) var timedOut = false
        func pass() async {
            arrivals += 1
            if arrivals >= 2 {
                timer?.cancel()
                let continuations = waiting; waiting.removeAll()
                for continuation in continuations { continuation.resume() }
                return
            }
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                timer = Task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    timedOut = true
                    let continuations = waiting; waiting.removeAll()
                    for continuation in continuations { continuation.resume() }
                }
            }
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scruffy-cleanup-progress-\(UUID())")
        var home: URL { root.appendingPathComponent("home") }
        var downloads: URL { home.appendingPathComponent("Downloads") }
        var scanner: CleanupScanner { CleanupScanner(home: home, temp: root.appendingPathComponent("temp")) }
        var service: TrashService { TrashService(scanner: scanner, journal: root.appendingPathComponent("journal.json")) }
        func candidate(_ name: String) throws -> Candidate {
            let url = home.appendingPathComponent("Library/Caches/com.apple.Safari/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture cache contents".utf8).write(to: url)
            let seconds = Int(Date().timeIntervalSince1970) - 3 * 86400
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            guard utimes(url.path, &times) == 0 else { throw POSIXError(.EIO) }
            return Candidate(url: url, category: .browsers, fingerprint: try Fingerprint.read(url))
        }
        func mover() throws -> @Sendable (URL) throws -> URL {
            let destination = root.appendingPathComponent("fake-trash")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return { url in
                let target = destination.appendingPathComponent("\(UUID())-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testFinalProgressIncludesMovedAndSkippedTotalsWithoutTimingAssumptions() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let first = try fixture.candidate("first"), changed = try fixture.candidate("changed")
        let missing = try fixture.candidate("missing"), last = try fixture.candidate("last")
        let selected = [first, changed, missing, last]
        try Data("changed contents".utf8).write(to: changed.url)
        try FileManager.default.removeItem(at: missing.url)
        let updates = Updates()
        let service = fixture.service
        let outcome = try await service.clean(selected, all: selected, folders: [fixture.downloads],
                                              browsersRunning: { false }, progress: { updates.add($0) }, moveToTrash: try fixture.mover())
        let snapshots = updates.snapshots
        let initial = try XCTUnwrap(snapshots.first), final = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(initial.phase, .checking)
        XCTAssertEqual(initial.checked, 0)
        XCTAssertTrue(snapshots.contains { $0.phase == .moving })
        XCTAssertEqual(final.total, 4)
        XCTAssertEqual(final.checked, 4)
        XCTAssertEqual(final.moved, 2)
        XCTAssertEqual(final.skipped, 2)
        XCTAssertEqual(final.processed, 4)
        XCTAssertEqual(final.bytes, first.bytes + last.bytes)
        XCTAssertEqual(final.moved, outcome.count)
        XCTAssertEqual(final.skipped, outcome.skippedIDs.count)
        XCTAssertTrue(outcome.errors.isEmpty)
        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.checked, next.checked)
            XCTAssertLessThanOrEqual(previous.moved, next.moved)
            XCTAssertLessThanOrEqual(previous.skipped, next.skipped)
            XCTAssertEqual(next.total, selected.count)
        }
        XCTAssertEqual(try service.records().count, 2)
    }

    func testFailedMoveReportsPartialFinalProgressAndOneTerminalError() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let changed = try fixture.candidate("changed"), first = try fixture.candidate("first")
        let failing = try fixture.candidate("failing"), untouched = try fixture.candidate("untouched")
        let selected = [changed, first, failing, untouched]
        try Data("changed contents".utf8).write(to: changed.url)
        let mover = try fixture.mover(), updates = Updates()
        let outcome = try await fixture.service.clean(selected, all: selected, folders: [fixture.downloads], browsersRunning: { false }, progress: { updates.add($0) }, moveToTrash: { url in
            if url == failing.url { throw POSIXError(.EACCES) }
            return try mover(url)
        })
        let final = try XCTUnwrap(updates.snapshots.last)
        XCTAssertEqual(final.checked, 4)
        XCTAssertEqual(final.moved, 1)
        XCTAssertEqual(final.skipped, 1)
        XCTAssertEqual(final.processed, 2)
        XCTAssertEqual(final.bytes, first.bytes)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.movedIDs, [first.id])
        XCTAssertEqual(outcome.skippedIDs, [changed.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: failing.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.url.path))
    }

    func testConcurrentCleanupCallsShareOneServiceWithoutLosingRecoveryRecords() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let left = try [fixture.candidate("left-a"), fixture.candidate("left-b")]
        let right = try [fixture.candidate("right-a"), fixture.candidate("right-b")]
        let all = left + right, service = fixture.service, mover = try fixture.mover(), barrier = StartBarrier()
        let leftUpdates = Updates(), rightUpdates = Updates()
        async let leftOutcome = service.clean(left, all: all, folders: [fixture.downloads], browsersRunning: {
            await barrier.pass(); return false
        }, progress: { leftUpdates.add($0) }, moveToTrash: mover)
        async let rightOutcome = service.clean(right, all: all, folders: [fixture.downloads], browsersRunning: {
            await barrier.pass(); return false
        }, progress: { rightUpdates.add($0) }, moveToTrash: mover)
        let outcomes = try await (leftOutcome, rightOutcome)
        XCTAssertEqual(outcomes.0.count + outcomes.1.count, 4)
        XCTAssertTrue(outcomes.0.errors.isEmpty)
        XCTAssertTrue(outcomes.1.errors.isEmpty)
        let timedOut = await barrier.timedOut
        XCTAssertFalse(timedOut)
        let records = try service.records()
        XCTAssertEqual(Set(records.map(\.original)), Set(all.map(\.url)))
        XCTAssertEqual(Set(records.map(\.id)).count, 4)
        XCTAssertTrue(records.allSatisfy { $0.trashed != nil })
        XCTAssertEqual(leftUpdates.snapshots.last?.processed, 2)
        XCTAssertEqual(rightUpdates.snapshots.last?.processed, 2)
        let reloaded = TrashService(scanner: fixture.scanner, journal: service.journal)
        XCTAssertEqual(Set(try reloaded.records().map(\.id)), Set(records.map(\.id)))
    }
}
