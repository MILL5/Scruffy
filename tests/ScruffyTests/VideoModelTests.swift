import Combine
import XCTest
@testable import CleanupCore
@testable import Scruffy

final class VideoModelTests: XCTestCase, @unchecked Sendable {
    private actor Calls {
        private var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
        func values() -> [String] { ids }
    }

    private func candidate(_ name: String, bytes: Int64 = 100, keeper: Bool = false, inode: UInt64 = 1) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: .videos,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0),
                                           device: 1, inode: inode, links: 1), keeper: keeper)
    }

    @MainActor
    private func waitForVisible(_ model: VideoModel, ids: Set<String>) async {
        if !model.isFiltering && Set(model.visible.map(\.id)) == ids { return }
        let ready = expectation(description: "Indexed video search finishes")
        let subscription = model.$visible.combineLatest(model.$isFiltering)
            .filter { !$0.1 && Set($0.0.map(\.id)) == ids }
            .prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    private func waitForIdle(_ model: VideoModel) async {
        if !model.busy { return }
        let ready = expectation(description: "Video compression batch finishes")
        let subscription = model.$busy.filter { !$0 }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    func testVideosAndIndexedMatchesSortLargestFirst() async {
        let model = VideoModel()
        let small = candidate("london/film.mp4", bytes: 10)
        let big = candidate("film/london.mov", bytes: 300)
        let other = candidate("paris/film.mp4", bytes: 400)
        model.update([small, other, big], folders: [])
        XCTAssertEqual(model.files.map(\.id), [other.id, big.id, small.id])
        XCTAssertEqual(model.visible.map(\.id), [other.id, big.id, small.id])
        XCTAssertEqual(model.totalBytes, 710)

        model.query = "  FILM london "
        await waitForVisible(model, ids: [big.id, small.id])
        XCTAssertEqual(model.visible.map(\.id), [big.id, small.id])
        model.query = "london film"
        await waitForVisible(model, ids: [big.id, small.id])
        XCTAssertEqual(model.visible.map(\.id), [big.id, small.id])
    }

    @MainActor
    func testBulkSelectCoversAllFilteredPagesAndPreservesOutsideSelections() async {
        let model = VideoModel()
        let matches = (0..<225).map { candidate("london/film-\($0).mp4") }
        let outside = candidate("paris/film.mp4", bytes: 30)
        let keeper = candidate("london/original-film.mp4", keeper: true)
        model.update(matches + [outside, keeper], folders: [])
        model.toggleSelection(outside)
        model.query = "film london"
        await waitForVisible(model, ids: Set(matches.map(\.id) + [keeper.id]))

        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, Set(matches.map(\.id) + [outside.id]))
        XCTAssertTrue(model.allVisibleSelected)
        XCTAssertEqual(model.visibleSelectableCount, 225)
        XCTAssertEqual(model.selectedBytes, 22_530)
        XCTAssertFalse(model.selection.contains(keeper.id))
        model.setVisibleSelection(false)
        XCTAssertEqual(model.selection, [outside.id])
        XCTAssertEqual(model.selectedBytes, 30)
    }

    @MainActor
    func testRowToggleRejectsKeeperRemovedAndChangedFiles() {
        let model = VideoModel()
        let item = candidate("film.mp4")
        let keeper = candidate("original.mov", keeper: true)
        model.update([item, keeper], folders: [])
        model.toggleSelection(item)
        XCTAssertEqual(model.selection, [item.id])
        model.toggleSelection(item)
        XCTAssertTrue(model.selection.isEmpty)
        model.toggleSelection(keeper)
        XCTAssertTrue(model.selection.isEmpty)

        model.toggleSelection(item)
        let changed = candidate("film.mp4", bytes: 200, inode: 2)
        model.update([changed], folders: [])
        XCTAssertTrue(model.selection.isEmpty)
        model.toggleSelection(item)
        XCTAssertTrue(model.selection.isEmpty)
        model.toggleSelection(changed)
        XCTAssertEqual(model.selectedBytes, 200)
        model.update([], folders: [])
        model.toggleSelection(changed)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.totalBytes, 0)
    }

    @MainActor
    func testSequentialCompressionRemovesOldCandidatesAndReportsSavingsOnce() async {
        let calls = Calls()
        let model = VideoModel(compressor: { item, _, progress in
            await calls.add(item.id)
            progress?(0.5)
            return VideoCompressionOutcome(url: item.url, originalBytes: item.bytes, compressedBytes: item.bytes / 2)
        })
        let small = candidate("small.mp4", bytes: 100)
        let large = candidate("large.mov", bytes: 300)
        model.update([small, large], folders: [])
        model.setVisibleSelection(true)
        var callbacks = 0
        model.compressSelection { callbacks += 1 }
        XCTAssertTrue(model.busy)
        model.toggleSelection(large)
        model.clearSelection()
        XCTAssertEqual(model.selection, [small.id, large.id])
        await waitForIdle(model)

        let order = await calls.values()
        XCTAssertEqual(order, [large.id, small.id])
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(model.savedBytes, 200)
        XCTAssertTrue(model.message?.contains("smaller") == true)
        XCTAssertTrue(model.message?.contains("empty Trash yourself") == true)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.error)
        model.update([small, large], folders: [])
        XCTAssertTrue(model.files.isEmpty, "An old progressive scan must not reintroduce completed inputs")
        let replacement = candidate("large.mov", bytes: 150, inode: 2)
        model.update([replacement], folders: [])
        XCTAssertEqual(model.files.map(\.id), [replacement.id])
        XCTAssertTrue(model.selection.isEmpty)
        model.update([], folders: [])
        model.update([small], folders: [])
        XCTAssertEqual(model.files.map(\.id), [small.id], "A fresh scan can rediscover an original restored from Trash")
    }

    @MainActor
    func testSafeNonSmallerSkipLeavesOriginalAndContinuesBatch() async {
        let model = VideoModel(compressor: { item, _, _ in
            if item.url.lastPathComponent == "unchanged.mov" { throw VideoCompressionError.notSmaller }
            return VideoCompressionOutcome(url: item.url, originalBytes: item.bytes, compressedBytes: item.bytes / 2)
        })
        let skipped = candidate("unchanged.mov", bytes: 300)
        let compressed = candidate("compressed.mp4", bytes: 100)
        model.update([skipped, compressed], folders: [])
        model.setVisibleSelection(true)
        var callbacks = 0
        model.compressSelection { callbacks += 1 }
        await waitForIdle(model)
        XCTAssertEqual(model.files.map(\.id), [skipped.id])
        XCTAssertEqual(model.selection, [skipped.id])
        XCTAssertEqual(model.savedBytes, 50)
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(model.message?.contains("1 skipped") == true)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testQueuedCancellationDoesNotInvokeCompressorOrCompletion() async {
        let calls = Calls()
        let model = VideoModel(compressor: { item, _, _ in
            await calls.add(item.id)
            return VideoCompressionOutcome(url: item.url, originalBytes: item.bytes, compressedBytes: 1)
        })
        let item = candidate("film.mp4")
        model.update([item], folders: [])
        model.setVisibleSelection(true)
        var callbacks = 0
        model.compressSelection { callbacks += 1 }
        model.cancel()
        await waitForIdle(model)
        let invoked = await calls.values()
        XCTAssertTrue(invoked.isEmpty)
        XCTAssertEqual(model.files.map(\.id), [item.id])
        XCTAssertEqual(model.selection, [item.id])
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(model.message?.contains("cancelled") == true)
    }

    @MainActor
    func testNewScanResultsAreNotSelectedAutomatically() {
        let model = VideoModel()
        let first = candidate("first.mp4")
        let discoveredLater = candidate("later.mov", bytes: 300)
        model.update([first], folders: [])
        model.setVisibleSelection(true)
        model.update([first, discoveredLater], folders: [])
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertEqual(model.chosen.map(\.id), [first.id])
        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [first.id, discoveredLater.id])
        XCTAssertEqual(model.chosen.map(\.id), [discoveredLater.id, first.id])
    }

    @MainActor
    func testCancellationDuringInjectedCompressionKeepsInputSelected() async {
        let started = expectation(description: "Injected encoder starts")
        let model = VideoModel(compressor: { _, _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(10))
            throw CancellationError()
        })
        let item = candidate("film.mp4")
        model.update([item], folders: [])
        model.setVisibleSelection(true)
        var callbacks = 0
        model.compressSelection { callbacks += 1 }
        await fulfillment(of: [started], timeout: 3)
        model.cancel()
        await waitForIdle(model)
        XCTAssertEqual(model.files.map(\.id), [item.id])
        XCTAssertEqual(model.selection, [item.id])
        XCTAssertEqual(model.savedBytes, 0)
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(model.message?.contains("cancelled") == true)
    }

    @MainActor
    func testBulkSkipFeedbackIsBounded() async {
        let model = VideoModel(compressor: { _, _, _ in throw VideoCompressionError.notSmaller })
        let files = (0..<30).map { candidate("film-\($0).mp4") }
        model.update(files, folders: [])
        model.setVisibleSelection(true)
        model.compressSelection { XCTFail("Skipped videos must not report a replacement") }
        await waitForIdle(model)
        XCTAssertEqual(model.files.count, 30)
        XCTAssertEqual(model.selection.count, 30)
        XCTAssertTrue(model.message?.contains("30 skipped") == true)
        XCTAssertTrue(model.message?.contains("10 more skipped") == true)
        XCTAssertLessThanOrEqual(model.message?.split(separator: "\n").count ?? .max, 22)
        XCTAssertNil(model.error)
    }
}
