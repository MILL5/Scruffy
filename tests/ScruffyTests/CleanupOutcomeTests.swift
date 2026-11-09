import XCTest
@testable import CleanupCore
@testable import Scruffy

final class CleanupOutcomeTests: XCTestCase, @unchecked Sendable {
    private func candidate(_ name: String, category: CleanupCategory = .browsers,
                           bytes: Int64, keeper: Bool = false) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: category,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0),
                                           device: 1, inode: 1, links: 1), keeper: keeper)
    }

    private func outcome(moved: [Candidate] = [], skipped: [Candidate] = [], errors: [String] = []) -> CleanupOutcome {
        var outcome = CleanupOutcome()
        outcome.count = moved.count
        outcome.bytes = moved.reduce(0) { $0 + $1.bytes }
        outcome.movedIDs = moved.map(\.id)
        outcome.skippedIDs = skipped.map(\.id)
        outcome.errors = errors
        return outcome
    }

    @MainActor
    private func makeModel(files: [Candidate], selected: Set<String>) -> AppModel {
        let model = AppModel(loadHistory: false)
        model.result = ScanResult(files: files.sorted(by: Candidate.largestFirst), notes: [])
        model.selection = selected
        model.error = nil
        return model
    }

    @MainActor
    func testMixedOutcomeRemovesMovedAndStaleFilesAndPreservesOtherSelections() async {
        let moved = candidate("moved-cache", bytes: 100)
        let stale = candidate("changed-download", category: .downloads, bytes: 70)
        let pending = candidate("pending-cache", bytes: 50)
        let download = candidate("pending-download", category: .downloads, bytes: 200)
        let unselected = candidate("unselected-cache", bytes: 30)
        let keeper = candidate("protected-original", category: .duplicates, bytes: 500, keeper: true)
        let model = makeModel(files: [moved, stale, pending, download, unselected, keeper],
                          selected: [moved.id, stale.id, pending.id, download.id])
        model.isScanning = true

        await model.applyCleanupOutcome(outcome(moved: [moved], skipped: [stale]))

        let remaining: Set<String> = [pending.id, download.id, unselected.id, keeper.id]
        XCTAssertEqual(Set(model.files.map(\.id)), remaining)
        XCTAssertEqual(Set(model.visible.map(\.id)), remaining)
        XCTAssertEqual(model.selection, [pending.id, download.id])
        XCTAssertEqual(Set(model.chosen.map(\.id)), [pending.id, download.id])
        XCTAssertEqual(model.selectedBytes, 250)
        XCTAssertEqual(model.count(.browsers), 2)
        XCTAssertEqual(model.bytes(.browsers), 80)
        XCTAssertEqual(model.candidateBytes, 280)
        XCTAssertEqual(model.visibleSelectableCount, 3)
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testSkipOnlyOutcomeReportsOneSummaryWithoutAnErrorAlert() async {
        let changed = candidate("changed-download", category: .downloads, bytes: 70)
        let missing = candidate("missing-cache", bytes: 40)
        let remaining = candidate("unchanged-cache", bytes: 20)
        let model = makeModel(files: [changed, missing, remaining], selected: [changed.id, missing.id, remaining.id])

        await model.applyCleanupOutcome(outcome(skipped: [changed, missing]))

        XCTAssertEqual(model.files.map(\.id), [remaining.id])
        XCTAssertEqual(model.selection, [remaining.id])
        XCTAssertEqual(model.chosen.count, 1)
        XCTAssertEqual(model.selectedBytes, 20)
        XCTAssertEqual(model.count(.browsers), 1)
        XCTAssertEqual(model.bytes(.browsers), 20)
        XCTAssertTrue(model.allVisibleSelected)
        XCTAssertNil(model.error)
        let summary = "2 changed or missing files left untouched. Scan again to review them."
        XCTAssertTrue(model.status.contains(summary))
        XCTAssertEqual(model.status.components(separatedBy: summary).count - 1, 1)
    }

    @MainActor
    func testRealErrorsRemainVisibleAlongsideSuccessfulMovesAndSoftSkips() async {
        let moved = candidate("moved-cache", bytes: 100)
        let stale = candidate("changed-cache", bytes: 70)
        let failed = candidate("permission-denied-cache", bytes: 200)
        let untouched = candidate("unselected-cache", bytes: 30)
        let model = makeModel(files: [moved, stale, failed, untouched], selected: [moved.id, stale.id, failed.id])
        let failures = ["Permission denied for the next file.", "Recovery history could not be updated."]

        await model.applyCleanupOutcome(outcome(moved: [moved], skipped: [stale], errors: failures))

        XCTAssertEqual(Set(model.files.map(\.id)), [failed.id, untouched.id])
        XCTAssertEqual(model.selection, [failed.id])
        XCTAssertEqual(model.chosen.map(\.id), [failed.id])
        XCTAssertEqual(model.selectedBytes, 200)
        for failure in failures { XCTAssertTrue(model.error?.contains(failure) == true) }
    }

    @MainActor
    func testErrorOnlyOutcomeDoesNotRemoveOrDeselectUntouchedFiles() async {
        let first = candidate("first-cache", bytes: 200)
        let second = candidate("second-cache", bytes: 100)
        let model = makeModel(files: [first, second], selected: [first.id, second.id])

        await model.applyCleanupOutcome(outcome(errors: ["Cannot write the recovery journal."]))

        XCTAssertEqual(model.files.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(model.chosen.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedBytes, 300)
        XCTAssertEqual(model.candidateBytes, 300)
        XCTAssertTrue(model.allVisibleSelected)
        XCTAssertEqual(model.error, "Cannot write the recovery journal.")
    }

    @MainActor
    func testReapplyingOutcomeDoesNotRemoveOtherFilesOrChangeTheirTotals() async {
        let moved = candidate("moved-cache", bytes: 100)
        let stale = candidate("changed-cache", bytes: 70)
        let pending = candidate("pending-cache", bytes: 50)
        let model = makeModel(files: [moved, stale, pending], selected: [moved.id, stale.id, pending.id])
        let completed = outcome(moved: [moved], skipped: [stale])

        await model.applyCleanupOutcome(completed)
        await model.applyCleanupOutcome(completed)

        XCTAssertEqual(model.files.map(\.id), [pending.id])
        XCTAssertEqual(model.selection, [pending.id])
        XCTAssertEqual(model.chosen.map(\.id), [pending.id])
        XCTAssertEqual(model.selectedBytes, 50)
        XCTAssertEqual(model.count(.browsers), 1)
        XCTAssertEqual(model.bytes(.browsers), 50)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testLaterProgressCannotReintroduceMovedOrSkippedFiles() async {
        let moved = candidate("moved-cache", bytes: 100)
        let stale = candidate("changed-download.mov", category: .downloads, bytes: 70)
        let pending = candidate("pending-cache", bytes: 50)
        let unselected = candidate("unselected-download", category: .downloads, bytes: 30)
        let staleVideo = Candidate(url: stale.url, category: .videos, fingerprint: stale.fingerprint)
        let model = makeModel(files: [moved, stale, pending, unselected], selected: [moved.id, stale.id, pending.id])
        model.result = ScanResult(files: model.files, notes: [], videos: [staleVideo])
        model.isScanning = true
        await model.applyCleanupOutcome(outcome(moved: [moved], skipped: [stale]))
        let discoveredLater = candidate("new-large-file", category: .large, bytes: 400)

        let later = ScanResult(files: [moved, stale, pending, unselected, discoveredLater].sorted(by: Candidate.largestFirst),
                               notes: [], videos: [staleVideo])
        await model.publish(later)

        let remaining: Set<String> = [pending.id, unselected.id, discoveredLater.id]
        XCTAssertEqual(Set(model.files.map(\.id)), remaining)
        XCTAssertEqual(Set(model.visible.map(\.id)), remaining)
        XCTAssertTrue(model.result?.videos.isEmpty == true)
        XCTAssertEqual(model.selection, [pending.id])
        XCTAssertEqual(model.chosen.map(\.id), [pending.id])
        XCTAssertEqual(model.selectedBytes, 50)
        XCTAssertFalse(model.selection.contains(discoveredLater.id))
        XCTAssertNil(model.error)
    }
}
