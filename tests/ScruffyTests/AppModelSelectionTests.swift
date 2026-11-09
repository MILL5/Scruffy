import Combine
import XCTest
@testable import CleanupCore
@testable import Scruffy

final class AppModelSelectionTests: XCTestCase, @unchecked Sendable {
    private func candidate(_ name: String, category: CleanupCategory, bytes: Int64 = 10,
                           hash: String? = nil, keeper: Bool = false) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: category,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0),
                                           device: 1, inode: 1, links: 1),
                  duplicateHash: hash, keeper: keeper)
    }

    @MainActor
    private func waitForVisible(_ model: AppModel, ids: Set<String>) async {
        if !model.isFiltering && Set(model.visible.map(\.id)) == ids { return }
        let ready = expectation(description: "Matching files become visible")
        let subscription = model.$visible
            .combineLatest(model.$isFiltering)
            .filter { !$0.1 && Set($0.0.map(\.id)) == ids }
            .prefix(1)
            .sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    func testSelectAllIncludesEveryPageAndExcludesDuplicateKeeper() async {
        let model = AppModel()
        let keeper = candidate("original", category: .duplicates, hash: "same-content", keeper: true)
        let copies = (0..<251).map { candidate("copy-\($0)", category: .duplicates, hash: "same-content") }
        let cache = candidate("cache", category: .browsers, bytes: 40)
        model.result = ScanResult(files: [keeper] + copies + [cache], notes: [])
        model.isScanning = true

        XCTAssertEqual(model.visibleSelectableCount, 252)
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.count(.duplicates), 251)
        XCTAssertEqual(model.bytes(.duplicates), 2_510)
        XCTAssertEqual(model.count(.browsers), 1)
        XCTAssertEqual(model.bytes(.browsers), 40)
        XCTAssertEqual(model.count(.temporary), 0)
        XCTAssertEqual(model.bytes(.temporary), 0)
        XCTAssertEqual(model.candidateBytes, 2_550)

        model.setVisibleSelection(true)

        XCTAssertEqual(model.selection, Set(copies.map(\.id) + [cache.id]))
        XCTAssertFalse(model.selection.contains(keeper.id))
        XCTAssertEqual(model.chosen.count, 252)
        XCTAssertEqual(model.chosen.map(\.id), copies.map(\.id) + [cache.id])
        XCTAssertEqual(model.selectedBytes, 2_550)
        XCTAssertTrue(model.allVisibleSelected)

        model.selection.remove(copies[0].id)
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertEqual(model.chosen.count, 251)
        XCTAssertEqual(model.selectedBytes, 2_540)
    }

    @MainActor
    func testDeselectCurrentFilterPreservesSelectionsOutsideIt() async {
        let model = AppModel()
        let matching = [candidate("matching-a", category: .browsers, bytes: 20),
                        candidate("matching-b", category: .browsers, bytes: 30)]
        let otherBrowser = candidate("other-browser", category: .browsers, bytes: 40)
        let outside = candidate("matching-developer-cache", category: .caches, bytes: 50)
        model.result = ScanResult(files: matching + [otherBrowser, outside], notes: [])
        model.selection = [outside.id]
        model.activeCategory = .browsers
        model.query = "MATCHING"
        await waitForVisible(model, ids: Set(matching.map(\.id)))

        XCTAssertEqual(model.visibleSelectableCount, 2)
        XCTAssertFalse(model.allVisibleSelected)
        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, Set(matching.map(\.id) + [outside.id]))
        XCTAssertTrue(model.allVisibleSelected)
        XCTAssertEqual(model.selectedBytes, 100)

        model.setVisibleSelection(false)
        XCTAssertEqual(model.selection, [outside.id])
        XCTAssertEqual(model.chosen.map(\.id), [outside.id])
        XCTAssertEqual(model.selectedBytes, 50)
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertEqual(model.bytes(.browsers), 90)
    }

    @MainActor
    func testEmptyAndKeeperOnlyResultsHaveNoSelectableFiles() async {
        let model = AppModel()
        model.result = ScanResult(files: [], notes: [])
        model.setVisibleSelection(true)
        XCTAssertEqual(model.visibleSelectableCount, 0)
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.chosen.isEmpty)
        XCTAssertEqual(model.selectedBytes, 0)

        let keeper = candidate("original", category: .duplicates, hash: "same-content", keeper: true)
        model.result = ScanResult(files: [keeper], notes: [])
        model.setVisibleSelection(true)
        XCTAssertEqual(model.visibleSelectableCount, 0)
        XCTAssertFalse(model.allVisibleSelected)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.count(.duplicates), 0)
        XCTAssertEqual(model.bytes(.duplicates), 0)
    }

    @MainActor
    func testBulkSelectionDoesNotChangeDuringCleanup() async {
        let model = AppModel()
        let first = candidate("first", category: .downloads)
        let second = candidate("second", category: .downloads)
        model.result = ScanResult(files: [first, second], notes: [])
        model.selection = [first.id]
        model.isCleaning = true

        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [first.id])
        model.setVisibleSelection(false)
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertEqual(model.chosen.map(\.id), [first.id])
        XCTAssertEqual(model.selectedBytes, first.bytes)
    }

    @MainActor
    func testBulkSelectionWaitsForCurrentFilter() async {
        let model = AppModel()
        let browser = candidate("browser", category: .browsers)
        let download = candidate("download", category: .downloads)
        model.result = ScanResult(files: [browser, download], notes: [])
        model.selection = [download.id]
        model.activeCategory = .browsers
        XCTAssertTrue(model.isFiltering)

        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [download.id])
        model.setVisibleSelection(false)
        XCTAssertEqual(model.selection, [download.id])

        await waitForVisible(model, ids: [browser.id])
        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [browser.id, download.id])
        XCTAssertEqual(model.chosen.map(\.id), [browser.id, download.id])
    }

    @MainActor
    func testRowToggleSelectsAndDeselectsButNeverSelectsKeeper() async {
        let model = AppModel()
        let copy = candidate("copy", category: .duplicates, bytes: 20, hash: "group")
        let keeper = candidate("original", category: .duplicates, bytes: 20, hash: "group", keeper: true)
        model.result = ScanResult(files: [keeper, copy], notes: [])

        model.toggleSelection(copy)
        XCTAssertEqual(model.selection, [copy.id])
        XCTAssertEqual(model.chosen.map(\.id), [copy.id])
        XCTAssertEqual(model.selectedBytes, 20)

        model.toggleSelection(copy)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.chosen.isEmpty)
        XCTAssertEqual(model.selectedBytes, 0)

        model.toggleSelection(keeper)
        XCTAssertTrue(model.selection.isEmpty)
    }

    @MainActor
    func testRowToggleDoesNotChangeSelectionDuringCleanupOrFiltering() async {
        let model = AppModel()
        let browser = candidate("browser", category: .browsers)
        let download = candidate("download", category: .downloads)
        model.result = ScanResult(files: [browser, download], notes: [])
        model.toggleSelection(download)
        model.isCleaning = true
        model.toggleSelection(download)
        model.toggleSelection(browser)
        XCTAssertEqual(model.selection, [download.id])

        model.isCleaning = false
        model.activeCategory = .browsers
        XCTAssertTrue(model.isFiltering)
        model.toggleSelection(download)
        model.toggleSelection(browser)
        XCTAssertEqual(model.selection, [download.id])
        await waitForVisible(model, ids: [browser.id])
        model.toggleSelection(browser)
        XCTAssertEqual(model.selection, [browser.id, download.id])
    }

    @MainActor
    func testRowToggleRejectsRemovedIDsAndUsesCurrentKeeperProtection() async {
        let model = AppModel()
        let stale = candidate("former-copy", category: .duplicates, hash: "group")
        model.result = ScanResult(files: [stale], notes: [])
        model.result = ScanResult(files: [], notes: [])
        model.toggleSelection(stale)
        XCTAssertTrue(model.selection.isEmpty)

        let currentKeeper = candidate("former-copy", category: .duplicates, hash: "group", keeper: true)
        model.result = ScanResult(files: [currentKeeper], notes: [])
        model.toggleSelection(stale)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.selectedBytes, 0)
    }

    @MainActor
    func testBulkSelectionUsesAllIndexedMatchesAcrossPages() async {
        let model = AppModel()
        let copies = (0..<225).map {
            candidate("zip-archive-\($0)/london-notes.bin", category: .duplicates, hash: "group")
        }
        let keeper = candidate("london/original.zip", category: .duplicates, hash: "group", keeper: true)
        let unmatched = candidate("paris/other.zip", category: .duplicates, hash: "other-group")
        let outside = candidate("london/browser.zip", category: .browsers)
        model.result = ScanResult(files: copies + [keeper, unmatched, outside], notes: [])
        model.selection = [outside.id]
        model.activeCategory = .duplicates
        model.query = "london zip"
        await waitForVisible(model, ids: Set(copies.map(\.id) + [keeper.id]))

        XCTAssertEqual(model.visibleSelectableCount, 225)
        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, Set(copies.map(\.id) + [outside.id]))
        XCTAssertFalse(model.selection.contains(keeper.id))
        XCTAssertFalse(model.selection.contains(unmatched.id))
        XCTAssertTrue(model.allVisibleSelected)
        model.setVisibleSelection(false)
        XCTAssertEqual(model.selection, [outside.id])
    }

    @MainActor
    func testSupportedBrowserIdentifiersRequireExactNameOrDottedVariant() async {
        for id in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
                   "org.mozilla.nightly", "com.microsoft.edgemac",
                   "com.brave.Browser", "company.thebrowser.Browser", "com.apple.SafariTechnologyPreview"] {
            XCTAssertTrue(AppModel.isSupportedBrowser(id), id)
            XCTAssertTrue(AppModel.isSupportedBrowser(id + ".helper"), id)
        }
        for id in ["", "com.apple.Safari2", "com.google.ChromeBeta", "org.mozilla.firefoxtool",
                   "com.microsoft.edgemacOther", "com.brave.BrowserBackup", "company.thebrowser.BrowserExtra",
                   "com.apple.SafariTechnologyPreviewBackup", "com.example.Chrome", "com.apple.finder"] {
            XCTAssertFalse(AppModel.isSupportedBrowser(id), id)
        }
    }

    @MainActor
    func testBrowserBlockerRequiresSelectedBrowserCacheAndRunningBrowserSnapshot() async {
        let model = AppModel()
        let browserCache = candidate("browser-cache", category: .browsers)
        let download = candidate("download", category: .downloads)
        model.result = ScanResult(files: [browserCache, download], notes: [])
        await waitForVisible(model, ids: [browserCache.id, download.id])
        model.refreshRunningBrowsers()
        let snapshotHasBrowsers = !model.runningBrowserNames.isEmpty

        XCTAssertFalse(model.browserCleanupBlocked)
        model.toggleSelection(download)
        XCTAssertFalse(model.browserCleanupBlocked)
        model.toggleSelection(browserCache)
        XCTAssertEqual(model.browserCleanupBlocked, snapshotHasBrowsers)
        model.toggleSelection(browserCache)
        XCTAssertFalse(model.browserCleanupBlocked)
    }
}
