import XCTest
@testable import CleanupCore

final class NGramSearchTests: XCTestCase, @unchecked Sendable {
    func testShortLongCaseAndUnicodeQueriesMatchSubstringOracle() throws {
        let strings = ["London report.zip", "LONDON summer 2026.pdf", "xbcabcx", "abcab", "repeated repeated",
                       "Café résumé", "Cafe\u{301} Re\u{301}sume\u{301}", "東京写真.heic", "🚀Rocket.txt", "", "a"]
        let index = try NGramSearch(strings: strings)
        for term in ["l", "LO", "lon", "LONDON", "summer", "abcab", "repeated", "Café", "résumé", "東京", "写真", "🚀", "rocket", "a", "missing"] {
            let normalized = NGramSearch.normalize(term)
            let expected = strings.indices.filter { NGramSearch.normalize(strings[$0]).contains(normalized) }
            XCTAssertEqual(try index.search(term), expected, term)
        }
        XCTAssertEqual(index.count, strings.count)
        XCTAssertGreaterThan(index.encodedPostingBytes, 0)
        XCTAssertGreaterThan(index.indexedTextBytes, 0)
    }

    func testGramsAreOnlyCandidatesUntilContiguousTextVerification() throws {
        let index = try NGramSearch(strings: ["xbcabcx", "abcab", "abxxbcxxcd", "abcd"])
        XCTAssertEqual(try index.search("abcab"), [1])
        XCTAssertEqual(try index.search("abcd"), [3])
    }

    func testInputPositionsRemainDistinctAndRepeatedOccurrencesDoNotDuplicateThem() throws {
        let index = try NGramSearch(strings: ["banana banana", "banana banana", "unrelated"])
        XCTAssertEqual(try index.search("ana"), [0, 1])
        XCTAssertEqual(try index.search("banana"), [0, 1])
        XCTAssertEqual(try index.search(""), [])
        XCTAssertEqual(try index.search("a\0b"), [])
    }

    func testDenseAndSparsePostingListsMatchOracleAcrossByteBoundaries() throws {
        let strings = (0..<2_200).map { "common-\($0)-\($0 % 257 == 0 ? "needle" : "other")" }
        let index = try NGramSearch(strings: strings)
        for term in ["c", "co", "com", "common", "needle", "2199", "0", "00"] {
            let expected = strings.indices.filter { strings[$0].contains(term) }
            XCTAssertEqual(try index.search(term), expected, term)
        }
    }

    func testDeterministicMixedTextFixtureMatchesOracle() throws {
        let strings = (0..<600).map {
            "/test/\($0 % 3 == 0 ? "Downloads" : "Documents")/Project-\($0 % 17)/file-\($0)-\($0 % 7 == 0 ? "Été" : "winter").\($0 % 2 == 0 ? "zip" : "pdf")"
        }
        let index = try NGramSearch(strings: strings)
        for term in ["/", "fi", "file", "file-59", "project-1", "ÉTÉ", "documents/project", "winter.zip", "not-found", "-17-"] {
            let normalized = NGramSearch.normalize(term)
            XCTAssertEqual(try index.search(term), strings.indices.filter { NGramSearch.normalize(strings[$0]).contains(normalized) }, term)
        }
    }

    func testConstructionAndSearchHonorTaskCancellation() async throws {
        let index = try NGramSearch(strings: ["a file"])
        let cancelledBuild = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NGramSearch(strings: ["must not build"])
        }
        let cancelledSearch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try index.search("file")
        }
        do { _ = try await cancelledBuild.value; XCTFail("Expected cancelled construction") }
        catch is CancellationError { }
        do { _ = try await cancelledSearch.value; XCTFail("Expected cancelled search") }
        catch is CancellationError { }
    }
}
