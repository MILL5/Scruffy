import XCTest
@testable import CleanupCore

final class ScanResultTests: XCTestCase {
    private func candidate(_ name: String, category: CleanupCategory, bytes: Int64,
                           hash: String? = nil, keeper: Bool = false) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(name)"), category: category,
                  fingerprint: Fingerprint(size: bytes, modified: Date(timeIntervalSince1970: 0),
                                           device: 1, inode: 1, links: 1),
                  duplicateHash: hash, keeper: keeper)
    }

    func testSummariesExcludeKeepersWhileDuplicateIndexesIncludeThem() throws {
        let keeper = candidate("original", category: .duplicates, bytes: 100, hash: "group-a", keeper: true)
        let copy = candidate("copy", category: .duplicates, bytes: 100, hash: "group-a")
        let anotherCopy = candidate("another-copy", category: .duplicates, bytes: 100, hash: "group-a")
        let otherKeeper = candidate("other-original", category: .duplicates, bytes: 200, hash: "group-b", keeper: true)
        let otherCopy = candidate("other-copy", category: .duplicates, bytes: 200, hash: "group-b")
        let cache = candidate("cache", category: .browsers, bytes: 30)
        let download = candidate("download", category: .downloads, bytes: 50)
        let files = [keeper, copy, anotherCopy, otherKeeper, otherCopy, cache, download]
        let result = ScanResult(files: files, notes: ["A skipped location"])

        XCTAssertEqual(result.files.map(\.id), files.map(\.id))
        XCTAssertEqual(result.notes, ["A skipped location"])
        XCTAssertEqual(Set(result.filesByID.keys), Set(files.map(\.id)))
        for file in files {
            let indexed = try XCTUnwrap(result.filesByID[file.id])
            XCTAssertEqual(indexed.url, file.url)
            XCTAssertEqual(indexed.fingerprint, file.fingerprint)
            XCTAssertEqual(indexed.category, file.category)
            XCTAssertEqual(indexed.duplicateHash, file.duplicateHash)
            XCTAssertEqual(indexed.keeper, file.keeper)
        }
        XCTAssertEqual(result.categoryCounts[.duplicates], 3)
        XCTAssertEqual(result.categoryBytes[.duplicates], 400)
        XCTAssertEqual(result.categoryCounts[.browsers], 1)
        XCTAssertEqual(result.categoryBytes[.browsers], 30)
        XCTAssertEqual(result.categoryCounts[.downloads], 1)
        XCTAssertEqual(result.categoryBytes[.downloads], 50)
        XCTAssertEqual(result.categoryCounts[.temporary, default: 0], 0)
        XCTAssertEqual(result.categoryBytes[.temporary, default: 0], 0)
        XCTAssertEqual(result.candidateBytes, 480)
        XCTAssertEqual(result.duplicateCounts, ["group-a": 3, "group-b": 2])
        XCTAssertEqual(Set(result.keepersByHash.keys), ["group-a", "group-b"])
        XCTAssertEqual(result.keepersByHash["group-a"]?.id, keeper.id)
        XCTAssertEqual(result.keepersByHash["group-b"]?.id, otherKeeper.id)
    }

    func testEmptyResultHasEmptyIndexesAndZeroCandidateBytes() {
        let result = ScanResult(files: [], notes: [])
        XCTAssertTrue(result.filesByID.isEmpty)
        XCTAssertTrue(result.categoryCounts.isEmpty)
        XCTAssertTrue(result.categoryBytes.isEmpty)
        XCTAssertTrue(result.duplicateCounts.isEmpty)
        XCTAssertTrue(result.keepersByHash.isEmpty)
        XCTAssertEqual(result.candidateBytes, 0)
    }

    func testValueCopiesKeepIdentityButFreshResultsHaveNewIdentity() {
        let result = ScanResult(files: [candidate("cache", category: .caches, bytes: 10)], notes: [])
        let copy = result
        let fresh = ScanResult(files: result.files, notes: result.notes)
        XCTAssertEqual(copy.id, result.id)
        XCTAssertNotEqual(fresh.id, result.id)
        XCTAssertEqual(fresh.candidateBytes, result.candidateBytes)
        XCTAssertEqual(fresh.files.map(\.id), result.files.map(\.id))
    }

    func testCandidateIdentityMatchesItsFilePathAndDefaultsHaveNoDuplicateMetadata() {
        let file = candidate("a file.txt", category: .downloads, bytes: 10)
        XCTAssertEqual(file.id, file.url.path)
        XCTAssertNil(file.duplicateHash)
        XCTAssertFalse(file.keeper)
    }
}
