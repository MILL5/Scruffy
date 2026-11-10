import XCTest
import os
@testable import CleanupCore

final class PurgeableTests: XCTestCase, @unchecked Sendable {
    func testCapacityEstimateIsOptionalAndNeverNegative() {
        XCTAssertNil(StorageCapacity(free: 50, available: nil, total: 100).reclaimableEstimate)
        XCTAssertEqual(StorageCapacity(free: 50, available: 40, total: 100).reclaimableEstimate, 0)
        XCTAssertEqual(StorageCapacity(free: 30, available: 75, total: 100).reclaimableEstimate, 45)
    }
    func testOnlyTimeMachineSnapshotsAreEligible() {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.os.update-ABC
        com.apple.os.update-MSUPrepareUpdate
        com.apple.TimeMachine.2026-11-08-120000.local
        com.apple.TimeMachine.2026-11-08-130000.local; rm -rf /
        com.apple.TimeMachine.invalid.local
        """
        XCTAssertEqual(PurgeableStorage.snapshotNames(in: output), ["com.apple.TimeMachine.2026-11-08-120000.local"])
    }
    func testReclaimUsesFixedPathConservativeUrgencyAndTrustedCapacity() throws {
        XCTAssertEqual(try PurgeableStorage.reclaimScript(requesting: 8_000_000_000_000), "do shell script \"/usr/bin/tmutil thinlocalsnapshots / 8000000000000 1\" with administrator privileges")
        XCTAssertThrowsError(try PurgeableStorage.reclaimScript(requesting: 0))
        XCTAssertThrowsError(try PurgeableStorage.reclaimScript(requesting: -1))
    }
    func testUnavailableVolumeCapacityNeverRequestsAdminOrDeletion() {
        let service = PurgeableStorage(capacity: { StorageCapacity(free: 0, available: nil, total: 0) }) { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/tmutil")
            XCTAssertEqual(arguments, ["listlocalsnapshots", "/"])
            return SystemCommandResult(status: 0, output: "com.apple.TimeMachine.2026-11-08-120000.local")
        }
        XCTAssertThrowsError(try service.reclaim())
    }
    func testNoSnapshotsNeverRequestsAdminOrDeletion() {
        let service = PurgeableStorage { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/tmutil")
            XCTAssertEqual(arguments, ["listlocalsnapshots", "/"])
            return SystemCommandResult(status: 0, output: "com.apple.os.update-ABC")
        }
        XCTAssertThrowsError(try service.reclaim())
    }
    func testListingFailureNeverRequestsAdminOrDeletion() {
        let service = PurgeableStorage { executable, _ in
            XCTAssertEqual(executable, "/usr/bin/tmutil")
            return SystemCommandResult(status: 1, output: "Access denied")
        }
        XCTAssertThrowsError(try service.reclaim())
    }
    func testReclaimRunsOnlyReviewedCommand() throws {
        let service = PurgeableStorage(capacity: { StorageCapacity(free: 0, available: nil, total: 8_000_000_000_000) }) { executable, arguments in
            if executable == "/usr/bin/tmutil" {
                XCTAssertEqual(arguments, ["listlocalsnapshots", "/"])
                return SystemCommandResult(status: 0, output: "com.apple.TimeMachine.2026-11-08-120000.local")
            }
            XCTAssertEqual(executable, "/usr/bin/osascript")
            XCTAssertEqual(arguments, ["-e", "do shell script \"/usr/bin/tmutil thinlocalsnapshots / 8000000000000 1\" with administrator privileges"])
            return SystemCommandResult(status: 0, output: "")
        }
        try service.reclaim()
    }
    func testDeniedAdminApprovalIsReported() {
        let service = PurgeableStorage { executable, _ in
            executable == "/usr/bin/tmutil"
                ? SystemCommandResult(status: 0, output: "com.apple.TimeMachine.2026-11-08-120000.local")
                : SystemCommandResult(status: 1, output: "User canceled. (-128)")
        }
        XCTAssertThrowsError(try service.reclaim()) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled"))
        }
    }

    func testMeasurementReportsNetFreeSpaceIndependentlyOfCommandReply() async throws {
        for (after, expected) in [(140, 40), (100, 0), (90, -10)] as [(Int64, Int64)] {
            let free = OSAllocatedUnfairLock(initialState: Int64(100))
            let service = PurgeableStorage(capacity: {
                StorageCapacity(free: free.withLock { $0 }, available: 500, total: 1000)
            }, runner: { _, _ in throw PurgeableError.unsupportedCapacity })
            let measurement = await service.measureReclaim(settle: .zero) {
                free.withLock { $0 = after }
                return Int64(400)
            }
            XCTAssertEqual(try measurement.result.get(), 400)
            XCTAssertEqual(measurement.freeSpaceChange, expected)
        }
    }

    func testMeasurementKeepsCommandErrorWhenCleanupPartiallySucceeds() async {
        let free = OSAllocatedUnfairLock(initialState: Int64(100))
        let service = PurgeableStorage(capacity: {
            StorageCapacity(free: free.withLock { $0 }, available: nil, total: 1000)
        }, runner: { _, _ in throw PurgeableError.unsupportedCapacity })
        let measurement = await service.measureReclaim(settle: .zero) { () -> Void in
            free.withLock { $0 = 125 }
            throw PurgeableError.command("The second purge failed.")
        }
        XCTAssertThrowsError(try measurement.result.get())
        XCTAssertEqual(measurement.freeSpaceChange, 25)
    }

    func testMissingBaselinePreventsCleanup() async {
        let service = PurgeableStorage(capacity: { throw PurgeableError.unsupportedCapacity }, runner: { _, _ in
            throw PurgeableError.unsupportedCapacity
        })
        let measurement = await service.measureReclaim(settle: .zero) {
            XCTFail("Cleanup started without a free-space baseline")
        }
        XCTAssertThrowsError(try measurement.result.get())
        XCTAssertNil(measurement.freeSpaceChange)
    }
}
