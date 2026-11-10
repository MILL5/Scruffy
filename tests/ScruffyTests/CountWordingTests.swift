import XCTest
@testable import CleanupCore
@testable import Scruffy

/// A count of one reads in the singular wherever the app shows it.
final class CountWordingTests: XCTestCase {
    func testCountedUsesTheSingularOnlyForOne() {
        XCTAssertEqual(counted(1, "file"), "1 file")
        XCTAssertEqual(counted(0, "file"), "0 files")
        XCTAssertEqual(counted(2, "video"), "2 videos")
        XCTAssertEqual(counted(1, "copy", "copies"), "1 copy")
        XCTAssertEqual(counted(3, "copy", "copies"), "3 copies")
        XCTAssertEqual(counted(1_234, "file"), "\(1_234.formatted()) files")
        XCTAssertEqual(fileCount(1), "1 file")
    }

    @MainActor
    func testStatusAfterMovingAndSkippingOneFileIsSingular() async {
        let model = AppModel(loadHistory: false)
        var outcome = CleanupOutcome()
        outcome.count = 1; outcome.bytes = 10; outcome.movedIDs = ["/fixture/moved"]; outcome.skippedIDs = ["/fixture/skipped"]
        await model.applyCleanupOutcome(outcome)
        XCTAssertTrue(model.status.hasPrefix("1 file ("), model.status)
        XCTAssertTrue(model.status.contains("1 changed or missing file left untouched. Scan again to review it."), model.status)

        outcome.count = 2; outcome.movedIDs = ["/fixture/a", "/fixture/b"]; outcome.skippedIDs = ["/fixture/c", "/fixture/d"]
        await model.applyCleanupOutcome(outcome)
        XCTAssertTrue(model.status.hasPrefix("2 files ("), model.status)
        XCTAssertTrue(model.status.contains("2 changed or missing files left untouched. Scan again to review them."), model.status)
    }

    func testJobStatusForOneFileIsSingular() {
        var job = CleanupJob(category: .downloads, total: 1)
        XCTAssertEqual(job.status, "Queued · 0 of 1 file")
        var outcome = CleanupOutcome()
        outcome.count = 1; outcome.movedIDs = ["/fixture/moved"]
        job.finish(outcome)
        XCTAssertEqual(job.status, "Completed · 1 of 1 file processed")

        var larger = CleanupJob(category: .downloads, total: 3)
        XCTAssertEqual(larger.status, "Queued · 0 of 3 files")
        larger.finish(error: "stopped")
        XCTAssertEqual(larger.status, "Failed · 0 of 3 files processed")
    }
}
