import XCTest
@testable import Scruffy

final class SingleInstanceTests: XCTestCase {
    private func lockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("instance.lock")
    }

    func testSecondInstanceCannotAcquireTheLock() throws {
        let url = try lockURL()
        let first = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        try withExtendedLifetime(first) {
            XCTAssertNil(try SingleInstanceLock.acquire(at: url))
            XCTAssertNil(try SingleInstanceLock.acquire(at: url))
        }
    }

    func testNextInstanceCanStartAfterTheOwnerExits() throws {
        let url = try lockURL()
        do {
            let first = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
            try withExtendedLifetime(first) {
                XCTAssertNil(try SingleInstanceLock.acquire(at: url))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try SingleInstanceLock.acquire(at: url))
    }

    func testPreexistingUnlockedFileDoesNotPreventLaunch() throws {
        let url = try lockURL()
        try Data("stale lock file".utf8).write(to: url)
        XCTAssertNotNil(try SingleInstanceLock.acquire(at: url))
    }

    func testInaccessibleLockPathThrowsInsteadOfAllowingAnotherInstance() throws {
        let url = try lockURL().appendingPathComponent("missing/instance.lock")
        XCTAssertThrowsError(try SingleInstanceLock.acquire(at: url))
    }

    func testLockDoesNotFollowSymlinks() throws {
        let url = try lockURL()
        let destination = url.deletingLastPathComponent().appendingPathComponent("other")
        try Data().write(to: destination)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        XCTAssertThrowsError(try SingleInstanceLock.acquire(at: url))
    }
}
