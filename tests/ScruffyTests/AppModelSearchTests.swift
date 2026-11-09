import Combine
import XCTest
@testable import CleanupCore
@testable import Scruffy

final class AppModelSearchTests: XCTestCase, @unchecked Sendable {
    private func candidate(_ name: String, category: CleanupCategory, bytes: Int64 = 10) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: category,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0),
                                           device: 1, inode: 1, links: 1))
    }

    @MainActor
    private func waitForVisible(_ model: AppModel, ids: Set<String>) async {
        if !model.isFiltering && Set(model.visible.map(\.id)) == ids { return }
        let ready = expectation(description: "Current indexed search finishes")
        let subscription = model.$visible.combineLatest(model.$isFiltering)
            .filter { !$0.1 && Set($0.0.map(\.id)) == ids }
            .prefix(1)
            .sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    func testEachCategoryAndOverviewRememberIndependentQueries() async {
        let model = AppModel()
        let browser = candidate("chrome/download-cache.bin", category: .browsers)
        let download = candidate("london/travel.zip", category: .downloads)
        let large = candidate("paris/video.mov", category: .large)
        model.result = ScanResult(files: [browser, download, large], notes: [])

        model.query = "paris"
        await waitForVisible(model, ids: [large.id])
        model.activeCategory = .browsers
        XCTAssertEqual(model.query, "")
        model.query = "chrome cache"
        await waitForVisible(model, ids: [browser.id])
        model.activeCategory = .downloads
        XCTAssertEqual(model.query, "")
        model.query = "london zip"
        await waitForVisible(model, ids: [download.id])

        model.activeCategory = nil
        XCTAssertEqual(model.query, "paris")
        await waitForVisible(model, ids: [large.id])
        model.activeCategory = .browsers
        XCTAssertEqual(model.query, "chrome cache")
        await waitForVisible(model, ids: [browser.id])
        model.activeCategory = .downloads
        XCTAssertEqual(model.query, "london zip")
        await waitForVisible(model, ids: [download.id])
    }

    @MainActor
    func testIndependentWordsMatchInEitherOrderAcrossPathComponents() async {
        let model = AppModel()
        let reversed = candidate("zip-archives/travel LONDON itinerary.txt", category: .downloads)
        let forward = candidate("london/photos/souvenirs.zip", category: .downloads)
        let londonOnly = candidate("london/notes.txt", category: .downloads)
        let zipOnly = candidate("paris/archive.zip", category: .downloads)
        let otherCategory = candidate("london/browser.zip", category: .browsers)
        model.result = ScanResult(files: [reversed, forward, londonOnly, zipOnly, otherCategory], notes: [])
        model.activeCategory = .downloads
        model.query = "  LoNdOn  zip  "
        await waitForVisible(model, ids: [reversed.id, forward.id])

        XCTAssertEqual(model.visible.map(\.id), [forward.id, reversed.id])
        XCTAssertEqual(model.visibleSelectableCount, 2)
        model.query = "zip london"
        await waitForVisible(model, ids: [reversed.id, forward.id])
        XCTAssertEqual(model.visible.map(\.id), [forward.id, reversed.id])
    }

    @MainActor
    func testRapidQueryCategoryAndSnapshotChangesKeepOnlyLatestMatches() async {
        let model = AppModel()
        let oldFiles = (0..<500).map { candidate("london-\($0)/old.zip", category: .browsers) }
        let current = candidate("paris/new.zip", category: .downloads)
        let wrongCategory = candidate("paris/other.zip", category: .browsers)
        let wrongTerms = candidate("london/other.zip", category: .downloads)
        model.result = ScanResult(files: oldFiles, notes: [])
        model.activeCategory = .browsers
        model.query = "london zip"
        model.query = "missing terms"
        model.activeCategory = .downloads
        model.query = "london"
        model.result = ScanResult(files: [wrongCategory, current, wrongTerms], notes: [])
        model.activeCategory = .browsers
        model.query = "other"
        model.activeCategory = .downloads
        model.query = "zip paris"
        await waitForVisible(model, ids: [current.id])

        XCTAssertEqual(model.activeCategory, .downloads)
        XCTAssertEqual(model.query, "zip paris")
        XCTAssertEqual(model.visible.map(\.id), [current.id])
        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [current.id])
        XCTAssertEqual(model.chosen.map(\.id), [current.id])
    }

    @MainActor
    func testOverviewCategoriesAndWordMatchesSortBySizeThenPath() async {
        let model = AppModel()
        let small = candidate("london/small.zip", category: .downloads, bytes: 10)
        let tieZ = candidate("london/z archive.zip", category: .browsers, bytes: 100)
        let largest = candidate("paris/big.bin", category: .large, bytes: 500)
        let tieA = candidate("london/a archive.zip", category: .browsers, bytes: 100)
        let download = candidate("zip/london-big.txt", category: .downloads, bytes: 200)
        let input = [small, tieZ, largest, tieA, download]
        let result = ScanResult(files: input, notes: [])
        XCTAssertEqual(result.files.map(\.id), input.map(\.id))
        XCTAssertEqual(result.filesBySize.map(\.id), [largest.id, download.id, tieA.id, tieZ.id, small.id])
        model.result = result
        await waitForVisible(model, ids: Set(input.map(\.id)))
        XCTAssertEqual(model.visible.map(\.id), result.filesBySize.map(\.id))

        model.activeCategory = .browsers
        await waitForVisible(model, ids: [tieA.id, tieZ.id])
        XCTAssertEqual(model.visible.map(\.id), [tieA.id, tieZ.id])

        model.activeCategory = nil
        model.query = "london zip"
        await waitForVisible(model, ids: [download.id, tieA.id, tieZ.id, small.id])
        XCTAssertEqual(model.visible.map(\.id), [download.id, tieA.id, tieZ.id, small.id])

        model.activeCategory = .downloads
        model.query = "ZIP LONDON"
        await waitForVisible(model, ids: [download.id, small.id])
        XCTAssertEqual(model.visible.map(\.id), [download.id, small.id])
    }

    @MainActor
    func testVideoTotalsStaySeparateFromPrimaryCleanupTotals() async {
        let model = AppModel()
        let cache = candidate("cache", category: .browsers, bytes: 40)
        let small = candidate("small.mp4", category: .videos, bytes: 20)
        let large = candidate("large.mov", category: .videos, bytes: 80)
        model.result = ScanResult(files: [cache], notes: [], videos: [small, large])
        XCTAssertEqual(model.count(.videos), 2)
        XCTAssertEqual(model.bytes(.videos), 100)
        XCTAssertEqual(model.count(.browsers), 1)
        XCTAssertEqual(model.bytes(.browsers), 40)
        XCTAssertEqual(model.candidateBytes, 40)
        XCTAssertEqual(model.files.map(\.id), [cache.id])
        XCTAssertEqual(model.visible.map(\.id), [cache.id])
        XCTAssertTrue(model.selection.isEmpty)
    }
}
