import Foundation
import Darwin

/// The legacy JSON stays untouched; durable upserts/tombstones live in a companion log.
struct TrashJournal: Sendable {
    let url: URL
    var eventsURL: URL { url.deletingPathExtension().appendingPathExtension("events.jsonl") }
    private let state = TrashJournalState()

    init(url: URL) { self.url = url }

    func records() throws -> [TrashRecord] {
        try state.lock.withLock {
            var order: [UUID] = [], seen = Set<UUID>(), records: [UUID: TrashRecord] = [:]
            func apply(_ event: Event) {
                switch event.operation {
                case .upsert:
                    if let record = event.record {
                        if seen.insert(record.id).inserted { order.append(record.id) }
                        records[record.id] = record
                    }
                case .remove:
                    if let id = event.id { records.removeValue(forKey: id) }
                }
            }
            let legacy = try readLegacy()
            for record in legacy.records { apply(.upsert(record)) }
            state.legacyChecked = true; state.legacyStamp = legacy.stamp
            guard let fd = try openEvents(create: false) else {
                state.eventsStamp = nil; state.committedEnd = 0
                return order.compactMap { records[$0] }
            }
            defer { close(fd) }
            try lock(fd, operation: LOCK_SH)
            let before = try checkedStamp(fd, path: eventsURL)
            let data = try readAll(fd)
            let end = try replay(data, apply: apply)
            let after = try checkedStamp(fd, path: eventsURL)
            guard before == after else { throw Failure.changed(eventsURL.path) }
            state.eventsStamp = after; state.committedEnd = end
            return order.compactMap { records[$0] }
        }
    }

    func append(_ record: TrashRecord) throws { try appendEvent(.upsert(record)) }
    func remove(_ id: UUID) throws { try appendEvent(.remove(id)) }

    private func appendEvent(_ event: Event) throws {
        var line = try JSONEncoder().encode(event)
        line.append(0x0a)
        try state.lock.withLock {
            guard let fd = try openEvents(create: true) else { throw Failure.changed(eventsURL.path) }
            defer { close(fd) }
            try lock(fd, operation: LOCK_EX)
            var stamp = try checkedStamp(fd, path: eventsURL)
            // Retain one helper for a batch: known own appends need only stat checks.
            // Unexpected external changes are fully revalidated under the file lock.
            let legacyStamp = try stampAt(url)
            if !state.legacyChecked || legacyStamp != state.legacyStamp {
                let legacy = try readLegacy()
                state.legacyChecked = true; state.legacyStamp = legacy.stamp
            }
            let committedEnd: Int64
            if stamp == state.eventsStamp { committedEnd = state.committedEnd }
            else { committedEnd = try replay(readAll(fd)) }
            if stamp.size != committedEnd {
                guard ftruncate(fd, off_t(committedEnd)) == 0 else { throw posixError() }
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw posixError() }
            if info.st_mode & 0o777 != 0o600 {
                guard fchmod(fd, 0o600) == 0 else { throw posixError() }
            }
            try writeAll(line, fd: fd)
            while fsync(fd) != 0 { if errno != EINTR { throw posixError() } }
            stamp = try checkedStamp(fd, path: eventsURL)
            guard stamp.size == committedEnd + Int64(line.count) else { throw Failure.changed(eventsURL.path) }
            state.eventsStamp = stamp; state.committedEnd = stamp.size
        }
    }

    private func openEvents(create: Bool) throws -> Int32? {
        if create {
            try FileManager.default.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let flags = (create ? O_RDWR | O_APPEND | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let fd = open(eventsURL.path, flags, 0o600)
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw posixError()
        }
        return fd
    }

    private func readLegacy() throws -> (records: [TrashRecord], stamp: TrashJournalStamp?) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return ([], nil) }
            throw posixError()
        }
        defer { close(fd) }
        try lock(fd, operation: LOCK_SH)
        let before = try checkedStamp(fd, path: url)
        let records = try JSONDecoder().decode([TrashRecord].self, from: readAll(fd))
        let after = try checkedStamp(fd, path: url)
        guard before == after else { throw Failure.changed(url.path) }
        return (records, after)
    }

    private func replay(_ data: Data, apply: ((Event) -> Void)? = nil) throws -> Int64 {
        // A newline is the commit boundary. Only the final unterminated fragment
        // may be ignored/truncated; complete malformed events always fail closed.
        let end = data.lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
        let decoder = JSONDecoder()
        var start = 0
        while start < end {
            guard let newline = data[start..<end].firstIndex(of: 0x0a) else { throw Failure.corrupt(eventsURL.path) }
            let event: Event
            do {
                event = try autoreleasepool {
                    let decoded = try decoder.decode(Event.self, from: Data(data[start..<newline]))
                    try decoded.validate()
                    return decoded
                }
            } catch { throw Failure.corrupt(eventsURL.path) }
            apply?(event)
            start = newline + 1
        }
        return Int64(end)
    }

    private func stampAt(_ path: URL) throws -> TrashJournalStamp? {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        try validate(info, path: path)
        return TrashJournalStamp(info)
    }

    private func checkedStamp(_ fd: Int32, path: URL) throws -> TrashJournalStamp {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        try validate(info, path: path)
        let stamp = TrashJournalStamp(info)
        guard let current = try stampAt(path), current == stamp else {
            throw Failure.changed(path.path)
        }
        return stamp
    }

    private func validate(_ info: stat, path: URL) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(), info.st_size >= 0 else {
            throw Failure.unsafe(path.path)
        }
    }

    private func lock(_ fd: Int32, operation: Int32) throws {
        while flock(fd, operation) != 0 { if errno != EINTR { throw posixError() } }
    }

    private func readAll(_ fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw posixError() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw posixError() }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw posixError() }
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private struct Event: Codable {
        enum Operation: String, Codable { case upsert, remove }
        let operation: Operation
        let record: TrashRecord?
        let id: UUID?
        static func upsert(_ record: TrashRecord) -> Self { Self(operation: .upsert, record: record, id: nil) }
        static func remove(_ id: UUID) -> Self { Self(operation: .remove, record: nil, id: id) }
        func validate() throws {
            switch operation {
            case .upsert: guard record != nil, id == nil else { throw Failure.corrupt("upsert") }
            case .remove: guard id != nil, record == nil else { throw Failure.corrupt("remove") }
            }
        }
    }

    private enum Failure: LocalizedError {
        case unsafe(String), corrupt(String), changed(String)
        var errorDescription: String? {
            switch self {
            case .unsafe(let path): "Recovery history is not a private regular file with one link: \(path)"
            case .corrupt(let path): "Recovery history contains an invalid committed event: \(path)"
            case .changed(let path): "Recovery history changed unexpectedly: \(path)"
            }
        }
    }
}

private final class TrashJournalState: @unchecked Sendable {
    let lock = NSLock()
    var legacyChecked = false
    var legacyStamp: TrashJournalStamp?
    var eventsStamp: TrashJournalStamp?
    var committedEnd: Int64 = 0
}

private struct TrashJournalStamp: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ info: stat) {
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}
