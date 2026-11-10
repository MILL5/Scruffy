import Foundation

/// Searches a fixed list of paths the way the file lists do: NGramSearch per word,
/// every word must match, in any order.
public struct PathSearch: Sendable {
    private let index: NGramSearch
    public init(_ paths: [String]) throws { index = try NGramSearch(strings: paths) }

    /// Positions of matching paths, in input order. A query without words matches every path.
    public func matches(_ query: String) throws -> [Int] {
        let words = Array(Set(query.split(whereSeparator: \.isWhitespace).map { NGramSearch.normalize(String($0)) }))
        guard !words.isEmpty else { return Array(0..<index.count) }
        var found: [[Int]] = []
        for word in words {
            let positions = try index.search(word)
            if positions.isEmpty { return [] }
            found.append(positions)
        }
        found.sort { $0.count < $1.count }
        var result = found[0]
        for other in found.dropFirst() {
            result = try NGramSearch.intersect(result, other)
            if result.isEmpty { break }
        }
        return result
    }
}
