import XCTest
@testable import CleanupCore

final class PurgeableTests: XCTestCase {
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
    func testReclaimUsesFixedPathConservativeUrgencyAndEnumAmount() {
        XCTAssertEqual(PurgeableStorage.reclaimScript(target: .five), "do shell script \"/usr/bin/tmutil thinlocalsnapshots / 5000000000 1\" with administrator privileges")
    }
    func testNoSnapshotsNeverRequestsAdminOrDeletion() {
        let service = PurgeableStorage { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/tmutil")
            XCTAssertEqual(arguments, ["listlocalsnapshots", "/"])
            return SystemCommandResult(status: 0, output: "com.apple.os.update-ABC")
        }
        XCTAssertThrowsError(try service.reclaim(target: .ten))
    }
    func testListingFailureNeverRequestsAdminOrDeletion() {
        let service = PurgeableStorage { executable, _ in
            XCTAssertEqual(executable, "/usr/bin/tmutil")
            return SystemCommandResult(status: 1, output: "Access denied")
        }
        XCTAssertThrowsError(try service.reclaim(target: .ten))
    }
    func testReclaimRunsOnlyReviewedCommand() throws {
        let service = PurgeableStorage { executable, arguments in
            if executable == "/usr/bin/tmutil" {
                XCTAssertEqual(arguments, ["listlocalsnapshots", "/"])
                return SystemCommandResult(status: 0, output: "com.apple.TimeMachine.2026-11-08-120000.local")
            }
            XCTAssertEqual(executable, "/usr/bin/osascript")
            XCTAssertEqual(arguments, ["-e", PurgeableStorage.reclaimScript(target: .one)])
            return SystemCommandResult(status: 0, output: "")
        }
        try service.reclaim(target: .one)
    }
    func testDeniedAdminApprovalIsReported() {
        let service = PurgeableStorage { executable, _ in
            executable == "/usr/bin/tmutil"
                ? SystemCommandResult(status: 0, output: "com.apple.TimeMachine.2026-11-08-120000.local")
                : SystemCommandResult(status: 1, output: "User canceled. (-128)")
        }
        XCTAssertThrowsError(try service.reclaim(target: .one)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled"))
        }
    }
}
