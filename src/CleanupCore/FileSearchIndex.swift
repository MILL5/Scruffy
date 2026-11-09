import Foundation

public struct FileSearchIndexStatistics: Sendable {
    public let segmentCount: Int
    public let indexedItemCount: Int
    public let activeItemCount: Int
    public let encodedPostingBytes: Int
    public let indexedTextBytes: Int
}

/// Keeps a logical NGramSearch index per section, extended in bounded immutable segments.
public actor FileSearchIndex {
    private struct Segment {
        let ids: [String]
        let index: NGramSearch
    }
    private let segmentSize = 2_048
    private var generation: UUID?
    private var snapshot: ScanResult?
    private var segments: [CleanupCategory: [Segment]] = [:]
    private var indexed: [CleanupCategory: Set<String>] = [:]
    private var positions: [String: Int] = [:]
    private var sectionFiles: [CleanupCategory: [Candidate]] = [:]

    public init() { }

    public var statistics: FileSearchIndexStatistics {
        let all = segments.values.flatMap { $0 }
        return FileSearchIndexStatistics(segmentCount: all.count,
                                         indexedItemCount: all.reduce(0) { $0 + $1.ids.count },
                                         activeItemCount: snapshot?.files.count ?? 0,
                                         encodedPostingBytes: all.reduce(0) { $0 + $1.index.encodedPostingBytes },
                                         indexedTextBytes: all.reduce(0) { $0 + $1.index.indexedTextBytes })
    }

    public func update(_ result: ScanResult, generation: UUID) throws {
        try Task.checkCancellation()
        if self.generation != generation {
            self.generation = generation
            snapshot = nil; segments = [:]; indexed = [:]; positions = [:]; sectionFiles = [:]
        }
        guard snapshot?.id != result.id else { return }
        var additions: [CleanupCategory: [String]] = [:]
        var positions: [String: Int] = [:]
        var sectionFiles: [CleanupCategory: [Candidate]] = [:]
        positions.reserveCapacity(result.files.count)
        for (position, item) in result.files.enumerated() {
            if position & 255 == 0 { try Task.checkCancellation() }
            positions[item.id] = position
            sectionFiles[item.category, default: []].append(item)
            if indexed[item.category]?.contains(item.id) != true {
                additions[item.category, default: []].append(item.id)
            }
        }
        for category in CleanupCategory.allCases {
            let ids = additions[category] ?? []
            for start in stride(from: 0, to: ids.count, by: segmentSize) {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(start + segmentSize, ids.count)])
                let index = try NGramSearch(strings: batch)
                try Task.checkCancellation()
                // A completed segment remains useful if a newer scan snapshot cancels
                // the remainder. Current result/order is committed only at the end.
                segments[category, default: []].append(Segment(ids: batch, index: index))
                indexed[category, default: []].formUnion(batch)
            }
        }
        try Task.checkCancellation()
        self.positions = positions; self.sectionFiles = sectionFiles; snapshot = result
    }

    /// Each word searches independently; their posting results are intersected (AND).
    public func search(_ query: String, category: CleanupCategory?, result: ScanResult,
                       generation: UUID) throws -> [Candidate] {
        try update(result, generation: generation)
        let words = Array(Set(query.split(whereSeparator: \.isWhitespace).map { NGramSearch.normalize(String($0)) }))
        guard !words.isEmpty else { return category.map { sectionFiles[$0] ?? [] } ?? result.files }
        let categories = category.map { [$0] } ?? CleanupCategory.allCases
        var matches: [(position: Int, file: Candidate)] = []
        var seen = Set<String>()
        for section in categories {
            for segment in segments[section] ?? [] {
                try Task.checkCancellation()
                var wordMatches: [[Int]] = []
                for word in words {
                    let found = try segment.index.search(word)
                    if found.isEmpty { wordMatches = []; break }
                    wordMatches.append(found)
                }
                guard !wordMatches.isEmpty else { continue }
                wordMatches.sort { $0.count < $1.count }
                var candidates = wordMatches[0]
                for other in wordMatches.dropFirst() {
                    candidates = try NGramSearch.intersect(candidates, other)
                    if candidates.isEmpty { break }
                }
                for (offset, candidate) in candidates.enumerated() {
                    if offset & 255 == 0 { try Task.checkCancellation() }
                    let id = segment.ids[candidate]
                    guard let position = positions[id], let current = result.filesByID[id],
                          current.category == section, seen.insert(id).inserted else { continue }
                    matches.append((position, current))
                }
            }
        }
        try Task.checkCancellation()
        matches.sort { $0.position < $1.position }
        return matches.map(\.file)
    }
}
