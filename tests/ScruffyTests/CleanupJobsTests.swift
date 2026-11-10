import Combine
import SwiftUI
import AppKit
import XCTest
@testable import CleanupCore
@testable import Scruffy

final class CleanupJobsTests: XCTestCase, @unchecked Sendable {
    private struct Call: Sendable {
        let selected: [Candidate]
        let all: [Candidate]
        let folders: [URL]
    }

    private actor RunnerGate {
        private(set) var calls: [Call] = []
        private var waiting: [CleanupCategory: CheckedContinuation<CleanupOutcome, Error>] = [:]
        let started: @Sendable (CleanupCategory) -> Void
        init(started: @escaping @Sendable (CleanupCategory) -> Void) { self.started = started }
        func run(_ selected: [Candidate], all: [Candidate], folders: [URL],
                 progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> CleanupOutcome {
            let category = selected[0].category
            calls.append(Call(selected: selected, all: all, folders: folders))
            return try await withCheckedThrowingContinuation { continuation in
                waiting[category] = continuation
                progress(CleanupProgress(phase: .moving, total: selected.count, checked: selected.count,
                                         moved: 0, skipped: 0, bytes: 0, currentFile: selected[0].url.lastPathComponent))
                started(category)
            }
        }
        func finish(_ category: CleanupCategory, outcome: CleanupOutcome) {
            waiting.removeValue(forKey: category)?.resume(returning: outcome)
        }
        func cancelAll() {
            let continuations = waiting.values; waiting.removeAll()
            for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private func candidate(_ name: String, category: CleanupCategory, bytes: Int64 = 10) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/fixture/\(name)"), category: category,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0), device: 1, inode: 1, links: 1))
    }

    private func moved(_ files: [Candidate]) -> CleanupOutcome {
        var outcome = CleanupOutcome()
        outcome.count = files.count; outcome.bytes = files.reduce(0) { $0 + $1.bytes }
        outcome.movedIDs = files.map(\.id)
        return outcome
    }

    @MainActor
    private func waitForJobs(_ model: AppModel, timeout: TimeInterval = 3,
                             matching predicate: @escaping @Sendable ([CleanupJob]) -> Bool) async {
        if predicate(model.cleanupJobs) { return }
        let ready = expectation(description: "Cleanup jobs publish expected state")
        let subscription = model.$cleanupJobs.filter(predicate).prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: timeout)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    private func waitForFileIDs(_ model: AppModel, _ ids: Set<String>) async {
        if Set(model.files.map(\.id)) == ids { return }
        let ready = expectation(description: "Background result publication removes all finished paths")
        let subscription = model.$result
            .filter { Set($0?.files.map(\.id) ?? []) == ids }
            .prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    private func renderDockFixturesIfRequested() {
        guard ProcessInfo.processInfo.environment["SCRUFFY_RENDER_CLEANUP_JOBS"] == "1" else { return }
        _ = NSApplication.shared
        var running = CleanupJob(category: .browsers, total: 120_350)
        running.update(CleanupProgress(phase: .moving, total: 120_350, checked: 120_350, moved: 42_100,
                                       skipped: 37, bytes: 2_100_000_000, currentFile: "example-cache-file-with-a-long-name.data"))
        var checking = CleanupJob(category: .downloads, total: 240)
        checking.update(CleanupProgress(phase: .checking, total: 240, checked: 57, moved: 0, skipped: 2,
                                        bytes: 0, currentFile: "example-download.zip"))
        var failed = CleanupJob(category: .caches, total: 80)
        failed.update(CleanupProgress(phase: .moving, total: 80, checked: 80, moved: 24, skipped: 3, bytes: 100_000_000))
        failed.finish(error: "Fixture permission denied. Remaining files were left untouched.")
        var completed = CleanupJob(category: .large, total: 2)
        var outcome = CleanupOutcome(); outcome.count = 2; outcome.bytes = 3_000_000_000
        completed.finish(outcome)
        let jobs = [running, checking, failed, completed]
        for (name, size) in [("wide", CGSize(width: 1280, height: 720)), ("compact", CGSize(width: 720, height: 540))] {
            let content = VStack(alignment: .leading, spacing: 0) {
                Text("Offscreen layout fixture · illustrative background jobs")
                    .font(.title3).padding(24)
                Spacer()
                CleanupJobsView(jobs: jobs, historyError: nil, availableSize: size)
            }.frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: URL(fileURLWithPath: "/tmp/scruffy-cleanup-jobs-\(name).png")) }
                    catch { print("Optional cleanup dock render could not be saved: \(error)") }
                }
            }
            window.close()
        }
    }

    @MainActor
    func testCategoryWorkersRunConcurrentlyWithFrozenQueuesAndAllowAnotherCategoryToStart() async throws {
        let firstTwoStarted = expectation(description: "Two independent categories enter runner")
        firstTwoStarted.expectedFulfillmentCount = 2
        let thirdStarted = expectation(description: "Third category starts before earlier workers finish")
        let gate = RunnerGate { category in
            if category == .large { thirdStarted.fulfill() } else { firstTwoStarted.fulfill() }
        }
        defer { Task { await gate.cancelAll() } }
        let model = AppModel(loadHistory: false, cleanupRunner: { selected, all, folders, progress in
            try await gate.run(selected, all: all, folders: folders, progress: progress)
        })
        let downloadA = candidate("download-a", category: .downloads, bytes: 10)
        let downloadB = candidate("download-b", category: .downloads, bytes: 20)
        let cache = candidate("cache", category: .browsers, bytes: 30)
        let large = candidate("large", category: .large, bytes: 40)
        let extraDownload = candidate("new-download", category: .downloads, bytes: 50)
        let initial = [downloadA, downloadB, cache, large]
        let originalFolders = [URL(fileURLWithPath: "/fixture/original-folder")]
        model.options.folders = originalFolders
        model.result = ScanResult(files: initial, notes: [])
        model.selection = [downloadA.id, downloadB.id, cache.id]
        model.clean()
        await fulfillment(of: [firstTwoStarted], timeout: 3)
        await waitForJobs(model) { $0.count == 2 && $0.allSatisfy { $0.state == .moving } }

        XCTAssertEqual(model.activeCleanupPaths, [downloadA.id, downloadB.id, cache.id])
        XCTAssertEqual(model.activeCleanupCategories, [.downloads, .browsers])
        XCTAssertTrue(model.isCleaning)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(Set(model.cleanupJobs.map(\.name)), ["Old downloads cleanup", "Browser cache cleanup"])
        XCTAssertTrue(model.cleanupJobs.allSatisfy { $0.status.contains("1 of") })

        model.result = ScanResult(files: initial + [extraDownload], notes: [])
        model.options.folders = [URL(fileURLWithPath: "/fixture/later-folder")]
        XCTAssertTrue(model.isQueued(extraDownload))
        model.toggleSelection(downloadA)
        model.toggleSelection(extraDownload)
        XCTAssertTrue(model.selection.isEmpty)
        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [large.id])
        model.clean()
        await fulfillment(of: [thirdStarted], timeout: 3)
        await waitForJobs(model) { $0.count == 3 && $0.allSatisfy { $0.state == .moving } }

        let calls = await gate.calls
        let downloadCall = try XCTUnwrap(calls.first { $0.selected.first?.category == .downloads })
        XCTAssertEqual(downloadCall.selected.map(\.id), [downloadA.id, downloadB.id])
        XCTAssertEqual(downloadCall.all.map(\.id), initial.map(\.id))
        XCTAssertEqual(downloadCall.folders, originalFolders)
        XCTAssertFalse(downloadCall.selected.contains { $0.id == extraDownload.id })
        XCTAssertEqual(model.activeCleanupCategories, [.downloads, .browsers, .large])

        await gate.finish(.downloads, outcome: moved([downloadA, downloadB]))
        await gate.finish(.browsers, outcome: moved([cache]))
        await gate.finish(.large, outcome: moved([large]))
        await waitForJobs(model) { $0.count == 3 && $0.allSatisfy { $0.state == .completed } }
        await waitForFileIDs(model, [extraDownload.id])
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(model.activeCleanupPaths.isEmpty)
        XCTAssertTrue(model.activeCleanupCategories.isEmpty)
        XCTAssertEqual(model.files.map(\.id), [extraDownload.id])
        XCTAssertNil(model.error)
        renderDockFixturesIfRequested()
    }

    @MainActor
    func testFailedWorkerStaysVisibleWithoutRetryOrModalWhileOtherWorkerContinues() async {
        let started = expectation(description: "Both category workers started")
        started.expectedFulfillmentCount = 2
        let gate = RunnerGate { _ in started.fulfill() }
        defer { Task { await gate.cancelAll() } }
        let model = AppModel(loadHistory: false, cleanupRunner: { selected, all, folders, progress in
            try await gate.run(selected, all: all, folders: folders, progress: progress)
        })
        let download = candidate("download", category: .downloads)
        let cache = candidate("cache", category: .browsers)
        model.result = ScanResult(files: [download, cache], notes: [])
        model.selection = [download.id, cache.id]
        model.clean()
        await fulfillment(of: [started], timeout: 3)
        var failure = CleanupOutcome(); failure.errors = ["Fixture permission failure"]
        await gate.finish(.downloads, outcome: failure)
        await waitForJobs(model) { $0.contains { $0.category == CleanupCategory.downloads.rawValue && $0.state == .failed } }

        let failed = model.cleanupJobs.first { $0.category == CleanupCategory.downloads.rawValue }
        XCTAssertEqual(failed?.failure, "Fixture permission failure")
        XCTAssertEqual(failed?.processed, 0)
        XCTAssertNotNil(failed?.finishedAt)
        XCTAssertTrue(model.isCleaning)
        XCTAssertEqual(model.activeCleanupCategories, [.browsers])
        XCTAssertNil(model.error)
        model.refreshHistory()
        model.result = ScanResult(files: model.files, notes: [])
        model.clean() // Empty selection must not restart the failed worker.
        await gate.finish(.browsers, outcome: moved([cache]))
        await waitForJobs(model) { $0.count == 2 && !$0.contains { $0.state.isRunning } }
        await waitForFileIDs(model, [download.id])
        let calls = await gate.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(model.cleanupJobs.filter { $0.state == .failed }.count, 1)
        XCTAssertFalse(model.isCleaning)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testInterruptedMetadataLoadsAsFailedWithoutRestoringOrExecutingQueues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scruffy-job-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        var interrupted = CleanupJob(category: .downloads, total: 3)
        interrupted.update(CleanupProgress(phase: .moving, total: 3, checked: 3, moved: 1, skipped: 1,
                                           bytes: 20, currentFile: "fixture-file"))
        var completed = CleanupJob(category: .caches, total: 1)
        completed.finish(moved([candidate("finished", category: .caches)]))
        let store = CleanupJobStore(url: url)
        try await store.save([interrupted, completed], revision: 1)
        let calls = Counter()
        let model = AppModel(loadHistory: false, cleanupRunner: { _, _, _, _ in
            await calls.increment()
            XCTFail("Persisted status must never execute a restored file queue")
            return CleanupOutcome()
        }, jobHistoryURL: url)
        await waitForJobs(model) { $0.count == 2 }

        let restored = try XCTUnwrap(model.cleanupJobs.first { $0.id == interrupted.id })
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(restored.moved, 1)
        XCTAssertEqual(restored.skipped, 1)
        XCTAssertTrue(restored.failure?.contains("will not resume") == true)
        XCTAssertNil(restored.currentFile)
        XCTAssertEqual(model.cleanupJobs.first { $0.id == completed.id }?.state, .completed)
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(model.activeCleanupPaths.isEmpty)
        XCTAssertTrue(model.activeCleanupCategories.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        let count = await calls.value
        XCTAssertEqual(count, 0)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertTrue(saved.allSatisfy { $0["queue"] == nil && $0["files"] == nil && $0["paths"] == nil })
    }

    @MainActor
    func testLargeOutcomeKeepsMainActorResponsiveAndQueueLockedWhileFinishing() async throws {
        let started = expectation(description: "Large fixture cleanup entered fake runner")
        let gate = RunnerGate { _ in started.fulfill() }
        defer { Task { await gate.cancelAll() } }
        let model = AppModel(loadHistory: false, cleanupRunner: { selected, all, folders, progress in
            try await gate.run(selected, all: all, folders: folders, progress: progress)
        })
        let queue = (0..<100_000).map { candidate("large-outcome-\($0).bin", category: .downloads) }
        let retained = candidate("retained", category: .large)
        model.result = ScanResult(files: queue + [retained], notes: [])
        model.selection = Set(queue.map(\.id))
        model.clean()
        await fulfillment(of: [started], timeout: 10)

        let heartbeat = expectation(description: "MainActor runs while result pruning is finishing")
        let subscription = model.$cleanupJobs
            .filter { $0.contains { $0.state == .finishing } }
            .prefix(1).sink { _ in
                Task { @MainActor in
                    XCTAssertTrue(model.cleanupJobs.contains { $0.state == .finishing })
                    XCTAssertTrue(model.activeCleanupCategories.contains(.downloads))
                    XCTAssertTrue(model.isQueued(queue[0]))
                    heartbeat.fulfill()
                }
            }
        await gate.finish(.downloads, outcome: moved(queue))
        await fulfillment(of: [heartbeat], timeout: 10)
        await waitForJobs(model, timeout: 10) { $0.count == 1 && $0[0].state == .completed }
        withExtendedLifetime(subscription) { }
        XCTAssertEqual(model.files.map(\.id), [retained.id])
        XCTAssertEqual(model.cleanupJobs.first?.moved, queue.count)
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(model.activeCleanupPaths.isEmpty)
        model.result = nil
    }

    @MainActor
    func testCleanupDuringPendingFinalScanPublicationPreservesNewlyDiscoveredRows() async throws {
        let model = AppModel(loadHistory: false)
        let files = (0..<150_000).map { candidate("publication-race-\($0).bin", category: .downloads) }
        let marker = candidate("newly-discovered-marker", category: .large)
        let finalSource = ScanResult(files: files + [marker], notes: ["final scan source"])
        model.result = ScanResult(files: [files[0], files[1]], notes: ["old committed source"])
        await model.applyCleanupOutcome(moved([files[0]]))
        XCTAssertEqual(model.files.map(\.id), [files[1].id])

        let publication = Task { @MainActor in await model.publish(finalSource, final: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.latestScanSnapshot?.id != finalSource.id && ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(model.latestScanSnapshot?.id, finalSource.id)
        XCTAssertNil(model.result?.filesByID[marker.id], "Fixture must overlap the pending final publication with the old committed snapshot")
        await model.applyCleanupOutcome(moved([files[1]]))
        _ = await publication.value

        XCTAssertEqual(model.latestScanSnapshot?.id, finalSource.id)
        XCTAssertNotNil(model.result?.filesByID[marker.id])
        XCTAssertNil(model.result?.filesByID[files[0].id])
        XCTAssertNil(model.result?.filesByID[files[1].id])
        XCTAssertEqual(model.files.count, 149_999)
        XCTAssertEqual(model.result?.notes, finalSource.notes)
        model.result = nil
    }

    func testJobCanBeRemovedOnlyWhenStoppedWithNothingLeftInTrash() {
        var job = CleanupJob(category: .downloads, total: 2)
        XCTAssertFalse(job.canRemove(restorable: []), "a running job stays")
        job.finish(error: nil)
        XCTAssertFalse(job.canRemove(restorable: [job.id]), "files still in Trash")
        XCTAssertTrue(job.canRemove(restorable: []))
    }
    func testUndoSummaryIsNumbersOnlyAndOlderJobHistoryStillLoads() throws {
        var undo = UndoOutcome(); undo.total = 1_219; undo.restored = 1_204; undo.missing = 12; undo.failed = 3
        XCTAssertEqual(CleanupJob.undoSummary(undo), "Undone · 1,204 restored · 12 already deleted · 3 not restored")
        undo.missing = 0; undo.failed = 0
        XCTAssertEqual(CleanupJob.undoSummary(undo), "Undone · 1,204 restored")
        XCTAssertEqual(CleanupJob.undoSummary(UndoOutcome()), "Undone · nothing left to restore")

        var job = CleanupJob(category: .downloads, total: 5)
        XCTAssertFalse(job.canUndo)
        var outcome = CleanupOutcome(); outcome.count = 5
        job.finish(outcome)
        XCTAssertTrue(job.canUndo)
        // A job saved before timings and undo existed has neither key.
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        saved.removeValue(forKey: "timings"); saved.removeValue(forKey: "undo")
        let loaded = try JSONDecoder().decode(CleanupJob.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(loaded.moved, 5)
        XCTAssertNil(loaded.undo)
    }
}
