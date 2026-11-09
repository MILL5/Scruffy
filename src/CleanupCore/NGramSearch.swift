import Foundation

// Copyright (c) 2021–2026 MILL5, LLC.
// Native Swift adaptation of FastSearch's packed n-gram posting-list algorithm.
public struct NGramSearch: Sendable {
    public let count: Int
    public var encodedPostingBytes: Int { postings.count }
    public var indexedTextBytes: Int { text.count * MemoryLayout<UInt16>.stride }

    private let grams: [UInt64: Int]
    private let postingStarts: [Int]
    private let postingCounts: [Int]
    private let dense: [Bool]
    private let postings: [UInt8]
    private let text: [UInt16]
    private let textStarts: [Int]

    static func normalize(_ value: String) -> String {
        value.lowercased().precomposedStringWithCanonicalMapping
    }

    public init(strings: [String]) throws {
        try Task.checkCancellation()
        count = strings.count
        var text: [UInt16] = [], starts: [Int] = []
        starts.reserveCapacity(strings.count + 1)
        for value in strings {
            try Task.checkCancellation()
            starts.append(text.count)
            text.append(contentsOf: Self.normalize(value).utf16)
        }
        starts.append(text.count)

        var grams: [UInt64: Int] = [:]
        var last: [Int] = [], counts: [Int] = [], sizes: [Int] = []
        for item in strings.indices {
            try Task.checkCancellation()
            for position in starts[item]..<starts[item + 1] {
                var key: UInt64 = 0
                for offset in 0..<min(3, starts[item + 1] - position) {
                    let character = text[position + offset]
                    if character == 0 { break }
                    key = (key << 16) | UInt64(character)
                    let gram: Int
                    if let existing = grams[key] { gram = existing }
                    else {
                        gram = grams.count; grams[key] = gram
                        last.append(-1); counts.append(0); sizes.append(0)
                    }
                    if last[gram] == item { continue }
                    var gap = item - last[gram] - 1
                    repeat { sizes[gram] += 1; gap >>= 7 } while gap > 0
                    counts[gram] += 1; last[gram] = item
                }
            }
        }

        let bitmapBytes = ((strings.count + 63) / 64) * 8
        var postingStarts = [Int](repeating: 0, count: grams.count + 1)
        var dense = [Bool](repeating: false, count: grams.count)
        for gram in 0..<grams.count {
            dense[gram] = bitmapBytes < sizes[gram]
            postingStarts[gram + 1] = postingStarts[gram] + (dense[gram] ? bitmapBytes : sizes[gram])
        }
        var postings = [UInt8](repeating: 0, count: postingStarts.last ?? 0)
        var cursors = Array(postingStarts.dropLast())
        last = [Int](repeating: -1, count: grams.count)
        for item in strings.indices {
            try Task.checkCancellation()
            for position in starts[item]..<starts[item + 1] {
                var key: UInt64 = 0
                for offset in 0..<min(3, starts[item + 1] - position) {
                    let character = text[position + offset]
                    if character == 0 { break }
                    key = (key << 16) | UInt64(character)
                    guard let gram = grams[key], last[gram] != item else { continue }
                    if dense[gram] {
                        postings[postingStarts[gram] + (item >> 3)] |= UInt8(1 << (item & 7))
                    } else {
                        var gap = item - last[gram] - 1
                        repeat {
                            let byte = UInt8(gap & 0x7f)
                            gap >>= 7
                            postings[cursors[gram]] = byte | (gap > 0 ? 0x80 : 0)
                            cursors[gram] += 1
                        } while gap > 0
                    }
                    last[gram] = item
                }
            }
        }
        try Task.checkCancellation()
        self.grams = grams; self.postingStarts = postingStarts
        postingCounts = counts; self.dense = dense; self.postings = postings
        self.text = text; textStarts = starts
    }

    /// Returns matching input positions once, in input order. Empty queries return no matches.
    public func search(_ query: String) throws -> [Int] {
        try Task.checkCancellation()
        let pattern = Array(Self.normalize(query).utf16)
        guard !pattern.isEmpty, !pattern.contains(0) else { return [] }
        if pattern.count <= 3 {
            guard let gram = grams[Self.key(pattern, start: 0, length: pattern.count)] else { return [] }
            return try decode(gram)
        }
        var seen = Set<Int>(), order: [Int] = []
        for start in 0...(pattern.count - 3) {
            guard let gram = grams[Self.key(pattern, start: start, length: 3)] else { return [] }
            if seen.insert(gram).inserted { order.append(gram) }
        }
        order.sort { postingCounts[$0] < postingCounts[$1] }
        guard let first = order.first else { return [] }
        var candidates = try decode(first)
        for gram in order.dropFirst() where candidates.count > 16 {
            try Task.checkCancellation()
            if !dense[gram] && postingCounts[gram] > candidates.count * 8 { continue }
            let before = candidates.count
            if dense[gram] {
                candidates = candidates.filter {
                    postings[postingStarts[gram] + ($0 >> 3)] & UInt8(1 << ($0 & 7)) != 0
                }
            } else {
                candidates = try Self.intersect(candidates, decode(gram))
            }
            if candidates.count > before - (before >> 3) { break }
        }
        var matches: [Int] = []
        for (offset, item) in candidates.enumerated() {
            if offset & 255 == 0 { try Task.checkCancellation() }
            if contains(pattern, item: item) { matches.append(item) }
        }
        return matches
    }

    private static func key(_ text: [UInt16], start: Int, length: Int) -> UInt64 {
        var key: UInt64 = 0
        for offset in 0..<length { key = (key << 16) | UInt64(text[start + offset]) }
        return key
    }

    private func decode(_ gram: Int) throws -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(postingCounts[gram])
        if dense[gram] {
            try postings.withUnsafeBytes { bytes in
                for position in stride(from: postingStarts[gram], to: postingStarts[gram + 1], by: 8) {
                    if (position - postingStarts[gram]) & 2047 == 0 { try Task.checkCancellation() }
                    var bits = bytes.loadUnaligned(fromByteOffset: position, as: UInt64.self).littleEndian
                    let base = (position - postingStarts[gram]) * 8
                    while bits != 0 {
                        result.append(base + bits.trailingZeroBitCount)
                        bits &= bits - 1
                    }
                }
            }
        } else {
            var cursor = postingStarts[gram], item = -1
            for entry in 0..<postingCounts[gram] {
                if entry & 255 == 0 { try Task.checkCancellation() }
                var gap = 0, shift = 0
                while true {
                    let byte = postings[cursor]; cursor += 1
                    gap |= Int(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { break }
                    shift += 7
                }
                item += gap + 1
                result.append(item)
            }
        }
        return result
    }

    static func intersect(_ left: [Int], _ right: [Int]) throws -> [Int] {
        var result: [Int] = [], l = 0, r = 0
        result.reserveCapacity(min(left.count, right.count))
        while l < left.count && r < right.count {
            if (l + r) & 1023 == 0 { try Task.checkCancellation() }
            if left[l] == right[r] { result.append(left[l]); l += 1; r += 1 }
            else if left[l] < right[r] { l += 1 }
            else { r += 1 }
        }
        return result
    }

    private func contains(_ pattern: [UInt16], item: Int) -> Bool {
        let start = textStarts[item], end = textStarts[item + 1]
        guard end - start >= pattern.count else { return false }
        for position in start...(end - pattern.count) where text[position] == pattern[0] {
            var offset = 1
            while offset < pattern.count && text[position + offset] == pattern[offset] { offset += 1 }
            if offset == pattern.count { return true }
        }
        return false
    }
}
