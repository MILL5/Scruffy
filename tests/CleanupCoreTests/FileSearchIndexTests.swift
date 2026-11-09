import XCTest
@testable import CleanupCore

final class FileSearchIndexTests: XCTestCase, @unchecked Sendable {
    private func candidate(_ path: String, category: CleanupCategory = .downloads, keeper: Bool = false) -> Candidate {
        Candidate(url: URL(fileURLWithPath: "/test/\(path)"), category: category,
                  fingerprint: Fingerprint(size: 10, modified: Date(timeIntervalSince1970: 0), device: 1, inode: 1, links: 1),
                  keeper: keeper)
    }

    func testEachWordMatchesIndependentlyThenIntersectsInSnapshotOrder() async throws {
        let files = [candidate("London/2026 summer holiday.zip"), candidate("winter/London summer.pdf"),
                     candidate("London/winter.zip"), candidate("Paris/summer.zip"), candidate("London summer.zip", category: .browsers)]
        let result = ScanResult(files: files, notes: [])
        let index = FileSearchIndex(), generation = UUID()
        let forward = try await index.search("  LONDON\t summer \n", category: .downloads, result: result, generation: generation)
        let reversed = try await index.search("summer london london", category: .downloads, result: result, generation: generation)
        XCTAssertEqual(forward.map(\.id), files.prefix(2).map(\.id))
        XCTAssertEqual(reversed.map(\.id), forward.map(\.id))
        let all = try await index.search("london summer", category: nil, result: result, generation: generation)
        XCTAssertEqual(all.map(\.id), [files[0], files[1], files[4]].map(\.id))
        let separated = try await index.search("zip London", category: .downloads, result: result, generation: generation)
        XCTAssertEqual(separated.map(\.id), [files[0], files[2]].map(\.id))
        let short = try await index.search("l z", category: .downloads, result: result, generation: generation)
        XCTAssertEqual(short.map(\.id), [files[0], files[2]].map(\.id))
    }

    func testEmptyQueryReturnsOnlyCurrentSectionWithoutLosingKeepersOrOrder() async throws {
        let files = [candidate("original", category: .duplicates, keeper: true),
                     candidate("cache", category: .browsers), candidate("copy", category: .duplicates)]
        let index = FileSearchIndex(), result = ScanResult(files: files, notes: []), generation = UUID()
        let section = try await index.search(" \n ", category: .duplicates, result: result, generation: generation)
        let all = try await index.search("", category: nil, result: result, generation: generation)
        let empty = try await index.search("", category: .temporary, result: result, generation: generation)
        XCTAssertEqual(section.map(\.id), [files[0], files[2]].map(\.id))
        XCTAssertEqual(all.map(\.id), files.map(\.id))
        XCTAssertTrue(empty.isEmpty)
    }

    func testProgressAddsSegmentsAndQueriesReuseTheBuiltSnapshot() async throws {
        let initial = (0..<2_049).map { candidate("archive-\($0).zip") }
        let index = FileSearchIndex(), generation = UUID()
        let first = ScanResult(files: initial, notes: [])
        try await index.update(first, generation: generation)
        let firstStats = await index.statistics
        XCTAssertEqual(firstStats.segmentCount, 2)
        XCTAssertEqual(firstStats.indexedItemCount, initial.count)
        let appended = candidate("new/archive-4000.zip")
        let second = ScanResult(files: [appended] + initial, notes: [])
        let found = try await index.search("archive zip", category: .downloads, result: second, generation: generation)
        XCTAssertEqual(found.map(\.id), second.files.map(\.id))
        let secondStats = await index.statistics
        XCTAssertEqual(secondStats.segmentCount, 3)
        XCTAssertEqual(secondStats.indexedItemCount, initial.count + 1)
        _ = try await index.search("4000", category: nil, result: second, generation: generation)
        let afterQuery = await index.statistics
        XCTAssertEqual(afterQuery.segmentCount, secondStats.segmentCount)
        XCTAssertEqual(afterQuery.indexedItemCount, secondStats.indexedItemCount)
    }

    func testRemovedFilesAndOldCategoriesNeverLeakFromRetainedSegments() async throws {
        let old = candidate("archive-a.zip"), retained = candidate("archive-b.zip")
        let index = FileSearchIndex(), generation = UUID()
        try await index.update(ScanResult(files: [old, retained], notes: []), generation: generation)
        var recategorized = retained; recategorized.category = .large
        let current = ScanResult(files: [recategorized], notes: [])
        let oldSection = try await index.search("archive", category: .downloads, result: current, generation: generation)
        let newSection = try await index.search("archive", category: .large, result: current, generation: generation)
        let all = try await index.search("archive", category: nil, result: current, generation: generation)
        XCTAssertTrue(oldSection.isEmpty)
        XCTAssertEqual(newSection.map(\.id), [retained.id])
        XCTAssertEqual(all.map(\.id), [retained.id])
        let stats = await index.statistics
        XCTAssertEqual(stats.activeItemCount, 1)
    }

    func testNewScanGenerationDropsOldSegments() async throws {
        let index = FileSearchIndex()
        try await index.update(ScanResult(files: [candidate("old-only.zip")], notes: []), generation: UUID())
        let fresh = ScanResult(files: [candidate("fresh-only.pdf")], notes: [])
        let generation = UUID()
        let old = try await index.search("old", category: nil, result: fresh, generation: generation)
        let new = try await index.search("fresh", category: nil, result: fresh, generation: generation)
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.map(\.id), fresh.files.map(\.id))
        let stats = await index.statistics
        XCTAssertEqual(stats.indexedItemCount, 1)
    }

    func testCancelledUpdateCannotReplaceCurrentGenerationOrResults() async throws {
        let index = FileSearchIndex(), generation = UUID()
        let current = ScanResult(files: [candidate("current.zip")], notes: [])
        try await index.update(current, generation: generation)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await index.update(ScanResult(files: [self.candidate("stale.zip")], notes: []), generation: UUID())
        }
        do { try await cancelled.value; XCTFail("Expected cancelled update") }
        catch is CancellationError { }
        let found = try await index.search("current", category: nil, result: current, generation: generation)
        XCTAssertEqual(found.map(\.id), current.files.map(\.id))
        let stats = await index.statistics
        XCTAssertEqual(stats.indexedItemCount, 1)
    }
}
