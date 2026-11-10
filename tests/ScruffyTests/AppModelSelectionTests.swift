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
    func testBulkSelectionRemainsAvailableDuringOtherCleanup() async {
        let model = AppModel()
        let first = candidate("first", category: .downloads)
        let second = candidate("second", category: .downloads)
        model.result = ScanResult(files: [first, second], notes: [])
        model.selection = [first.id]
        model.isCleaning = true

        model.setVisibleSelection(true)
        XCTAssertEqual(model.selection, [first.id, second.id])
        model.setVisibleSelection(false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.chosen.isEmpty)
        XCTAssertEqual(model.selectedBytes, 0)
    }

    @MainActor
    func testCategorySwitchShowsItsOwnRowsImmediatelyWithoutFiltering() async {
        let model = AppModel(loadHistory: false)
        let browser = candidate("browser", category: .browsers, bytes: 5)
        let small = candidate("small", category: .downloads, bytes: 10)
        let big = candidate("big", category: .downloads, bytes: 30)
        model.result = ScanResult(files: [small, browser, big], notes: [])

        model.activeCategory = .downloads
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.visible.map(\.id), [big.id, small.id])
        model.activeCategory = .browsers
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.visible.map(\.id), [browser.id])
        model.activeCategory = .large
        XCTAssertFalse(model.isFiltering)
        XCTAssertTrue(model.visible.isEmpty)
        model.activeCategory = nil
        XCTAssertEqual(model.visible.map(\.id), [big.id, small.id, browser.id])
    }

    @MainActor
    func testPendingSearchInAnotherCategoryNeverShowsPreviousCategoryRows() async {
        let model = AppModel(loadHistory: false)
        let browser = candidate("browser", category: .browsers)
        let download = candidate("download", category: .downloads)
        model.result = ScanResult(files: [browser, download], notes: [])
        model.activeCategory = .browsers
        model.query = "browser"
        await waitForVisible(model, ids: [browser.id])

        // Downloads has no saved search, so its rows appear at once.
        model.activeCategory = .downloads
        XCTAssertEqual(model.visible.map(\.id), [download.id])
        // Browser caches restores its saved search: rows clear until that search finishes.
        model.activeCategory = .browsers
        XCTAssertTrue(model.isFiltering)
        XCTAssertTrue(model.visible.isEmpty)
        await waitForVisible(model, ids: [browser.id])
    }

    @MainActor
    func testBulkSelectionWaitsForCurrentFilter() async {
        let model = AppModel()
        let browser = candidate("browser", category: .browsers)
        let download = candidate("download", category: .downloads)
        model.result = ScanResult(files: [browser, download], notes: [])
        model.selection = [download.id]
        model.activeCategory = .browsers
        model.query = "browser"
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
    func testRepeatedClicksAddOneDuplicateAtATimeOriginalLastThenClear() async {
        let model = AppModel(loadHistory: false)
        let first = candidate("copy-a", category: .duplicates, bytes: 20, hash: "group")
        let second = candidate("copy-b", category: .duplicates, bytes: 20, hash: "group")
        let keeper = candidate("original", category: .duplicates, bytes: 20, hash: "group", keeper: true)
        let other = candidate("other-copy", category: .duplicates, bytes: 5, hash: "other")
        let otherKeeper = candidate("other-original", category: .duplicates, bytes: 5, hash: "other", keeper: true)
        model.result = ScanResult(files: [keeper, first, second, other, otherKeeper], notes: [])

        // Clicking the original's row never picks the original while a copy is still unselected.
        model.advanceSelection(keeper)
        XCTAssertEqual(model.selection, [first.id])
        model.advanceSelection(second)
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertTrue(model.fullySelectedGroups.isEmpty)
        XCTAssertEqual(model.selectedBytes, 40)

        model.advanceSelection(second)
        XCTAssertEqual(model.selection, [first.id, second.id, keeper.id])
        XCTAssertEqual(model.fullySelectedGroups, ["group"])
        XCTAssertEqual(Set(model.chosen.map(\.id)), [first.id, second.id, keeper.id])
        XCTAssertEqual(model.selectedBytes, 60)

        model.advanceSelection(first)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.fullySelectedGroups.isEmpty)

        // Control-click chooses the whole group at once and leaves other groups alone.
        model.advanceSelection(first, all: true)
        XCTAssertEqual(model.selection, [first.id, second.id, keeper.id])
        XCTAssertEqual(model.fullySelectedGroups, ["group"])

        // Select all never adds an original; clearing releases a chosen one.
        model.setVisibleSelection(true)
        XCTAssertFalse(model.selection.contains(otherKeeper.id))
        XCTAssertEqual(model.fullySelectedGroups, ["group"])
        model.setVisibleSelection(false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.chosen.isEmpty)
    }

    @MainActor
    func testRowToggleWaitsForFiltering() async {
        let model = AppModel()
        let browser = candidate("browser", category: .browsers)
        let download = candidate("download", category: .downloads)
        model.result = ScanResult(files: [browser, download], notes: [])
        model.toggleSelection(download)
        model.activeCategory = .browsers
        model.query = "browser"
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
