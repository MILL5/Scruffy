import XCTest
@testable import CleanupCore

final class SystemPurgeTests: XCTestCase {
    func testOnlyAllowlistedDataAndCacheServicesCanPass() throws {
        let reply: [String: Any] = ["CACHE_DELETE_VOLUME": SystemPurgePolicy.volume,
                                   "com.apple.fspurgeable_data": NSNumber(value: 2048),
                                   "com.apple.cache_delete_app_container_caches": NSNumber(value: 1024)]
        XCTAssertEqual(try SystemPurgePolicy.verifiedBytes(reply), 3072)
        for excluded in ["com.apple.fspurgeable_document", "com.apple.TMCacheDelete", "com.apple.mobileassetd.cache-delete", "unknown-service"] {
            var unsafe = reply; unsafe[excluded] = NSNumber(value: 0)
            XCTAssertThrowsError(try SystemPurgePolicy.verifiedBytes(unsafe))
        }
    }
    func testMalformedQueryFailsClosed() {
        XCTAssertThrowsError(try SystemPurgePolicy.verifiedBytes([:]))
        XCTAssertThrowsError(try SystemPurgePolicy.verifiedBytes(["CACHE_DELETE_VOLUME": "/", "CACHE_DELETE_ERROR": "denied"]))
        XCTAssertThrowsError(try SystemPurgePolicy.verifiedBytes(["CACHE_DELETE_VOLUME": "/", "com.apple.fspurgeable_data": -1]))
    }
    func testPurgeRequestsEntireEligibleAmountWithRestrictedServicesAndUrgency() throws {
        let info = try SystemPurgePolicy.purgeInfo(cleanableBytes: 8_000_000_000_000)
        XCTAssertEqual(info["CACHE_DELETE_VOLUME"] as? String, "/System/Volumes/Data")
        XCTAssertEqual(info["CACHE_DELETE_AMOUNT"] as? Int64, 8_000_000_000_000)
        XCTAssertEqual(info["CACHE_DELETE_URGENCY"] as? Int, 3)
        XCTAssertEqual(info["CACHE_DELETE_SERVICES"] as? [String], SystemPurgePolicy.services)
    }
    func testNoEligibleSpaceCannotCreateAPurgeRequest() {
        XCTAssertThrowsError(try SystemPurgePolicy.purgeInfo(cleanableBytes: 0))
        XCTAssertThrowsError(try SystemPurgePolicy.purgeInfo(cleanableBytes: -1))
    }
    func testCleanAllProtocolHasNoSizeArgument() throws {
        let client = SystemPurgeClient(helper: URL(fileURLWithPath: "/test/helper")) { executable, arguments in
            XCTAssertEqual(executable, "/test/helper")
            XCTAssertEqual(arguments, ["purge"])
            return SystemCommandResult(status: 0, output: "{\"cleanableBytes\":8000000000000,\"removedBytes\":7000000000000}")
        }
        let reply = try client.clean()
        XCTAssertEqual(reply.cleanableBytes, 8_000_000_000_000)
        XCTAssertEqual(reply.removedBytes, 7_000_000_000_000)
    }
    func testClientProbeNeverRequestsPurge() throws {
        let client = SystemPurgeClient(helper: URL(fileURLWithPath: "/test/helper")) { executable, arguments in
            XCTAssertEqual(executable, "/test/helper"); XCTAssertEqual(arguments, ["probe"])
            return SystemCommandResult(status: 0, output: "{\"cleanableBytes\":1234}")
        }
        XCTAssertEqual(try client.probe().cleanableBytes, 1234)
    }
    func testHelperFailureIsNotReportedAsSuccess() {
        let client = SystemPurgeClient(helper: URL(fileURLWithPath: "/test/helper")) { _, _ in
            SystemCommandResult(status: 1, output: "Filter refused")
        }
        XCTAssertThrowsError(try client.clean())
    }
}
