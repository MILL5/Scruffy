import Foundation
import os

/// Wall-clock time accumulated per named phase of a scan or cleanup.
/// Measurement only: nothing reads these values to make a decision.
public struct PhaseTimings: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public let name: String
        public var seconds: Double
        public var items: Int
        public var bytes: Int64
    }
    public private(set) var entries: [Entry] = []
    public static let log = Logger(subsystem: "com.richcrane.scruffy", category: "timing")
    public init() {}

    public subscript(_ name: String) -> Entry? { entries.first { $0.name == name } }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func add(_ name: String, since start: ContinuousClock.Instant, items: Int = 1, bytes: Int64 = 0) {
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries[index].seconds += seconds; entries[index].items += items; entries[index].bytes += bytes
        } else {
            entries.append(Entry(name: name, seconds: seconds, items: items, bytes: bytes))
        }
    }

    /// One line per phase, in the order each phase first ran.
    public var summary: String {
        entries.map { entry in
            var line = "\(entry.name): \(Self.format(entry.seconds))"
            if entry.items > 1 {
                line += " · \(entry.items.formatted()) items · \(Self.format(entry.seconds / Double(entry.items))) each"
            }
            if entry.bytes > 0 {
                line += " · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))"
            }
            return line
        }.joined(separator: "\n")
    }

    public static func format(_ seconds: Double) -> String {
        if seconds >= 60 { return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60) }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        if seconds >= 0.001 { return String(format: "%.1f ms", seconds * 1_000) }
        return String(format: "%.0f µs", seconds * 1_000_000)
    }
}
