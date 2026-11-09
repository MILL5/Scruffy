import XCTest
@testable import CleanupCore
@testable import Scruffy

final class CategorySummaryTests: XCTestCase {
    @MainActor
    func testEmptyCategoryDoesNotShowOtherCategoriesBytesOrLegend() {
        let model = makeModel()
        model.activeCategory = .duplicates
        XCTAssertEqual(model.summaryBytes, 0)
        XCTAssertTrue(model.summaryCategories.isEmpty)
        XCTAssertEqual(model.candidateBytes, 100)
    }

    @MainActor
    func testCategorySummaryUsesItsOwnBytesAndLegend() {
        let model = makeModel()
        model.activeCategory = .browsers
        XCTAssertEqual(model.summaryBytes, 40)
        XCTAssertEqual(model.summaryCategories, [.browsers])
    }

    @MainActor
    func testOverviewRestoresAllCleanupCategoriesAndExcludesVideos() {
        let model = makeModel()
        model.activeCategory = .browsers
        model.activeCategory = nil
        XCTAssertEqual(model.summaryBytes, 100)
        XCTAssertEqual(Set(model.summaryCategories), [.browsers, .downloads])
    }

    @MainActor
    func testSelectionsInOtherCategoriesStaySelectedAndAreClearlyIdentified() {
        let model = makeModel()
        model.selection = ["/test/cache"]
        model.activeCategory = .duplicates
        XCTAssertTrue(model.hasSelectionOutsideCategory)
        XCTAssertEqual(model.selectedBytes, 40)
        model.activeCategory = .browsers
        XCTAssertFalse(model.hasSelectionOutsideCategory)
        model.activeCategory = nil
        XCTAssertFalse(model.hasSelectionOutsideCategory)
        XCTAssertEqual(model.selection, ["/test/cache"])
    }

    func testZeroBytesUsesANumericLabel() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        XCTAssertEqual(formatBytes(0), formatter.string(fromByteCount: 0))
    }

    @MainActor
    private func makeModel() -> AppModel {
        let model = AppModel(loadHistory: false)
        func candidate(_ name: String, _ category: CleanupCategory, _ bytes: Int64) -> Candidate {
            Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: category,
                      fingerprint: Fingerprint(size: bytes, modified: .distantPast, device: 1, inode: 1, links: 1))
        }
        model.result = ScanResult(files: [candidate("cache", .browsers, 40), candidate("download", .downloads, 60)],
                                  notes: [], videos: [candidate("movie.mov", .videos, 500)])
        return model
    }
}
