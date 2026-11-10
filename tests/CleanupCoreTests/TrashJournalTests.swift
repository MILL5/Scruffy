import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import CleanupCore

final class TrashJournalTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-journal-test-\(UUID())")
        var legacy: URL { root.appendingPathComponent("support/trash-history.json") }
        var events: URL { legacy.deletingPathExtension().appendingPathExtension("events.jsonl") }
        var journal: TrashJournal { TrashJournal(url: legacy) }
        func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func writeLegacy(_ records: [TrashRecord]) throws {
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: legacy)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func record(_ name: String, id: UUID = UUID(), trashed: Bool = false) -> TrashRecord {
        TrashRecord(id: id, original: URL(fileURLWithPath: "/fixture/\(name)"),
                    trashed: trashed ? URL(fileURLWithPath: "/fixture/.Trash/\(name)") : nil,
                    fingerprint: Fingerprint(size: 123, modified: Date(timeIntervalSince1970: 0), device: 1, inode: 1, links: 1),
                    date: Date(timeIntervalSince1970: 0))
    }

    private func appendRaw(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }

    func testMissingHistoryReadDoesNotCreateFilesAndFirstAppendUsesPrivateCompanion() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let journal = fixture.journal
        XCTAssertTrue(try journal.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacy.deletingLastPathComponent().path))
        let original = record("first")
        try journal.append(original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacy.path))
        XCTAssertEqual(try journal.records().map(\.id), [original.id])
        XCTAssertEqual(fixture.events.lastPathComponent, "trash-history.events.jsonl")
        var info = stat()
        XCTAssertEqual(lstat(fixture.events.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testLegacyUpsertsTombstonesAndFirstIntentOrderWithoutMigration() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let first = record("first"), second = record("second"), third = record("third")
        try fixture.writeLegacy([first, second])
        let legacy = try Data(contentsOf: fixture.legacy)
        let journal = fixture.journal
        XCTAssertEqual(try journal.records().map(\.id), [first.id, second.id])
        try journal.append(record("first", id: first.id, trashed: true))
        try journal.append(third)
        try journal.remove(second.id)
        XCTAssertEqual(try journal.records().map(\.id), [first.id, third.id])
        try journal.append(record("second", id: second.id, trashed: true))
        let replay = try journal.records()
        XCTAssertEqual(replay.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(replay[0].trashed?.path, "/fixture/.Trash/first")
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), legacy)
    }

    func testRestoreOfLegacyRecordIsATombstoneAndNeverRewritesLegacy() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let restored = record("restored", trashed: true), retained = record("retained", trashed: true)
        try fixture.writeLegacy([restored, retained])
        let legacy = try Data(contentsOf: fixture.legacy)
        try fixture.journal.remove(restored.id)
        XCTAssertEqual(try fixture.journal.records().map(\.id), [retained.id])
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), legacy)
        let events = try Data(contentsOf: fixture.events)
        XCTAssertEqual(events.filter { $0 == 0x0a }.count, 1)
    }

    func testUnterminatedTailIsIgnoredThenOnlyThatTailIsTruncated() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let journal = fixture.journal, first = record("first"), second = record("second")
        try journal.append(first)
        let committed = try Data(contentsOf: fixture.events)
        try appendRaw(Data("{\"operation\":\"upsert\",\"record\":{\"partial".utf8), to: fixture.events)
        XCTAssertEqual(try journal.records().map(\.id), [first.id])
        try journal.append(second)
        let repaired = try Data(contentsOf: fixture.events)
        XCTAssertEqual(Data(repaired.prefix(committed.count)), committed)
        XCTAssertEqual(repaired.last, 0x0a)
        XCTAssertEqual(repaired.filter { $0 == 0x0a }.count, 2)
        XCTAssertEqual(try journal.records().map(\.id), [first.id, second.id])
    }

    func testEntireUncommittedFragmentCanBeReplacedWithoutChangingLegacy() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let old = record("old"), new = record("new")
        try fixture.writeLegacy([old])
        let legacy = try Data(contentsOf: fixture.legacy)
        try Data("interrupted fragment without a newline".utf8).write(to: fixture.events)
        XCTAssertEqual(try fixture.journal.records().map(\.id), [old.id])
        try fixture.journal.append(new)
        XCTAssertEqual(try fixture.journal.records().map(\.id), [old.id, new.id])
        XCTAssertEqual(try Data(contentsOf: fixture.events).filter { $0 == 0x0a }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), legacy)
    }

    func testCompleteMalformedEventsNeverBecomeAnEmptyHistoryOrGetTruncated() throws {
        for malformed in ["not JSON\n", "{}\n", "\n", "{\"operation\":\"remove\"}\n", "{\"operation\":\"unknown\"}\n"] {
            let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
            let journal = fixture.journal
            try journal.append(record("valid"))
            try appendRaw(Data((malformed + "unterminated tail").utf8), to: fixture.events)
            let bytes = try Data(contentsOf: fixture.events)
            XCTAssertThrowsError(try journal.records())
            XCTAssertThrowsError(try journal.append(record("must not append")))
            XCTAssertEqual(try Data(contentsOf: fixture.events), bytes)
        }
    }

    func testUnrecognizableLegacyDataAlwaysFailsClosed() throws {
        for malformed in [Data(), Data("{}".utf8), Data("truncated [".utf8)] {
            let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
            try fixture.writeLegacy([])
            try malformed.write(to: fixture.legacy)
            let journal = fixture.journal
            XCTAssertThrowsError(try journal.records())
            XCTAssertThrowsError(try journal.append(record("must not append")))
            XCTAssertEqual(try Data(contentsOf: fixture.legacy), malformed)
        }
    }

    func testSymbolicAndHardLinksAreRejectedForBothJournalFiles() throws {
        for legacyLink in [false, true] {
            for symbolic in [false, true] {
                let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
                try FileManager.default.createDirectory(at: fixture.legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
                let target = fixture.root.appendingPathComponent("must-not-touch")
                let bytes = Data("unrelated data".utf8)
                try bytes.write(to: target)
                let link = legacyLink ? fixture.legacy : fixture.events
                if symbolic { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
                else { try FileManager.default.linkItem(at: target, to: link) }
                let journal = fixture.journal
                XCTAssertThrowsError(try journal.records())
                XCTAssertThrowsError(try journal.append(record("must not append")))
                XCTAssertEqual(try Data(contentsOf: target), bytes)
            }
        }
    }

    func testIndependentInstancesSerializeEventsWithoutLosingUpdates() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let records = (0..<80).map { record("concurrent-\($0)") }
        let errors = Errors()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            let journal = fixture.journal
            for index in stride(from: worker, to: records.count, by: 4) {
                do {
                    try journal.append(records[index])
                    var moved = records[index]; moved.trashed = URL(fileURLWithPath: "/fixture/.Trash/\(index)")
                    try journal.append(moved)
                } catch { errors.add(error.localizedDescription) }
            }
        }
        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: "\n"))
        let replay = try fixture.journal.records()
        XCTAssertEqual(Set(replay.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(replay.count, records.count)
        XCTAssertTrue(replay.allSatisfy { $0.trashed != nil })
        XCTAssertEqual(try Data(contentsOf: fixture.events).filter { $0 == 0x0a }.count, records.count * 2)
    }

    func testBulkAppendsHaveLinearStorageAndStableInodeAndLegacyHash() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        try fixture.writeLegacy([record("legacy")])
        let legacy = try Data(contentsOf: fixture.legacy), originalHash = Data(SHA256.hash(data: legacy))
        let journal = fixture.journal
        _ = try journal.records()
        func batch(_ range: Range<Int>) throws {
            for index in range {
                let intent = record(String(format: "file-%04d", index))
                try journal.append(intent)
                var moved = intent; moved.trashed = URL(fileURLWithPath: String(format: "/fixture/.Trash/file-%04d", index))
                try journal.append(moved)
            }
        }
        try batch(0..<300)
        let first = try Data(contentsOf: fixture.events)
        var before = stat(); XCTAssertEqual(lstat(fixture.events.path, &before), 0)
        try batch(300..<600)
        let all = try Data(contentsOf: fixture.events)
        var after = stat(); XCTAssertEqual(lstat(fixture.events.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(all.count, first.count * 2)
        XCTAssertEqual(Data(all.prefix(first.count)), first)
        XCTAssertEqual(all.filter { $0 == 0x0a }.count, 1_200)
        XCTAssertEqual(try journal.records().count, 601)
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: fixture.legacy))), originalHash)
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), legacy)
    }

    func testCompactionKeepsTheSameRecordsInFewerLinesAndNeverTouchesLegacy() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let kept = record("legacy-kept", trashed: true), restored = record("legacy-restored", trashed: true)
        try fixture.writeLegacy([kept, restored])
        let legacy = try Data(contentsOf: fixture.legacy)
        let journal = fixture.journal
        try journal.remove(restored.id)
        var live: [TrashRecord] = []
        for index in 0..<40 {
            let intent = record("file-\(index)")
            try journal.append(intent)
            var moved = intent; moved.trashed = URL(fileURLWithPath: "/fixture/.Trash/file-\(index)")
            try journal.append(moved)
            if index % 2 == 0 { try journal.remove(intent.id) } else { live.append(moved) }
        }
        let before = try journal.records()
        XCTAssertEqual(before.map(\.id), [kept.id] + live.map(\.id))
        let oldSize = try Data(contentsOf: fixture.events).count
        var oldInfo = stat(); XCTAssertEqual(lstat(fixture.events.path, &oldInfo), 0)

        XCTAssertEqual(try journal.compact(), 0)

        let after = try journal.records()
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.trashed), before.map(\.trashed))
        let compacted = try Data(contentsOf: fixture.events)
        // One removal for the restored legacy record, one line per live logged record.
        XCTAssertEqual(compacted.filter { $0 == 0x0a }.count, 1 + live.count)
        XCTAssertLessThan(compacted.count, oldSize / 2)
        var newInfo = stat(); XCTAssertEqual(lstat(fixture.events.path, &newInfo), 0)
        XCTAssertEqual(newInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(newInfo.st_nlink, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.events.appendingPathExtension("compacting").path))
        // A fresh instance reads the same history, and a second pass has nothing left to do.
        XCTAssertEqual(try fixture.journal.records().map(\.id), before.map(\.id))
        XCTAssertEqual(try journal.compact(), 0)
        XCTAssertEqual(try Data(contentsOf: fixture.events), compacted)
        // The journal keeps working after its file was replaced.
        let later = record("later", trashed: true)
        try journal.append(later)
        XCTAssertEqual(try journal.records().last?.id, later.id)
    }

    func testCompactionDropsNamedRecordsFromBothFilesAndIgnoresUnknownIDs() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let legacyGone = record("legacy-gone", trashed: true), legacyKept = record("legacy-kept", trashed: true)
        try fixture.writeLegacy([legacyGone, legacyKept])
        let legacy = try Data(contentsOf: fixture.legacy)
        let journal = fixture.journal
        let loggedGone = record("logged-gone", trashed: true), loggedKept = record("logged-kept", trashed: true)
        try journal.append(loggedGone); try journal.append(loggedKept)

        XCTAssertEqual(try journal.compact(dropping: [legacyGone.id, loggedGone.id, UUID()]), 2)

        XCTAssertEqual(try journal.records().map(\.id), [legacyKept.id, loggedKept.id])
        XCTAssertEqual(try fixture.journal.records().map(\.id), [legacyKept.id, loggedKept.id])
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), legacy)
        XCTAssertEqual(try Data(contentsOf: fixture.events).filter { $0 == 0x0a }.count, 2)
    }

    func testLegacyOnlyHistoryGetsALogOnlyWhenARecordIsDropped() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let first = record("first", trashed: true), second = record("second", trashed: true)
        try fixture.writeLegacy([first, second])
        let journal = fixture.journal
        XCTAssertEqual(try journal.compact(), 0)
        XCTAssertEqual(try journal.compact(dropping: [UUID()]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.events.path))
        XCTAssertEqual(try journal.compact(dropping: [first.id]), 1)
        XCTAssertEqual(try journal.records().map(\.id), [second.id])
    }

    func testInterruptedCompactionLeftoverIsReplacedAndMalformedLogIsNeverRewritten() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let journal = fixture.journal
        let first = record("first", trashed: true)
        try journal.append(first); try journal.append(first)
        try Data("partial earlier attempt".utf8).write(to: fixture.events.appendingPathExtension("compacting"))
        XCTAssertEqual(try journal.compact(), 0)
        XCTAssertEqual(try journal.records().map(\.id), [first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.events.appendingPathExtension("compacting").path))

        try appendRaw(Data("{not an event}\n".utf8), to: fixture.events)
        let damaged = try Data(contentsOf: fixture.events)
        XCTAssertThrowsError(try fixture.journal.compact(dropping: [first.id]))
        XCTAssertEqual(try Data(contentsOf: fixture.events), damaged)
    }

    func testAnotherInstanceKeepsAppendingAcrossRepeatedCompaction() throws {
        let fixture = Fixture(); try fixture.prepare(); defer { fixture.cleanup() }
        let records = (0..<200).map { record("busy-\($0)") }
        let errors = Errors()
        DispatchQueue.concurrentPerform(iterations: 3) { worker in
            let journal = fixture.journal
            if worker == 2 {
                for _ in 0..<60 { do { try journal.compact() } catch { errors.add("compact: \(error.localizedDescription)") } }
                return
            }
            for index in stride(from: worker, to: records.count, by: 2) {
                do {
                    try journal.append(records[index])
                    var moved = records[index]; moved.trashed = URL(fileURLWithPath: "/fixture/.Trash/\(index)")
                    try journal.append(moved)
                } catch { errors.add("append: \(error.localizedDescription)") }
            }
        }
        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: "\n"))
        let replay = try fixture.journal.records()
        XCTAssertEqual(Set(replay.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(replay.count, records.count)
        XCTAssertTrue(replay.allSatisfy { $0.trashed != nil })
    }

    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func add(_ message: String) { lock.withLock { messages.append(message) } }
        var values: [String] { lock.withLock { messages } }
    }
}
