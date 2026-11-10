import Foundation
import Darwin

public struct TrashRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let original: URL
    public var trashed: URL?
    public let fingerprint: Fingerprint
    public let date: Date
    /// The cleanup job that moved this file. Optional so earlier journals still load.
    public var job: UUID? = nil
}

/// Counts from undoing one cleanup job. Best effort: files already gone from Trash stay gone.
public struct UndoOutcome: Sendable, Codable, Equatable {
    public var total = 0
    public var restored = 0
    /// No longer in Trash, for example because Trash was emptied.
    public var missing = 0
    /// Still in Trash but not put back: the original place is taken or its folder is gone.
    public var failed = 0
    public var processed: Int { restored + missing + failed }
    public init() {}
}

public struct CleanupOutcome: Sendable {
    public var count = 0
    public var bytes: Int64 = 0
    public var errors: [String] = []
    public var movedIDs: [String] = []
    public var skippedIDs: [String] = []
    /// Where the time went. Measurement only.
    public var timings = PhaseTimings()
}

public struct CleanupProgress: Sendable {
    public enum Phase: String, Sendable { case checking, moving }
    public let phase: Phase
    public let total: Int
    public let checked: Int
    public let moved: Int
    public let skipped: Int
    public let bytes: Int64
    public let currentFile: String?
    public var processed: Int { moved + skipped }
    public init(phase: Phase, total: Int, checked: Int, moved: Int, skipped: Int, bytes: Int64, currentFile: String? = nil) {
        self.phase = phase; self.total = total; self.checked = checked
        self.moved = moved; self.skipped = skipped; self.bytes = bytes; self.currentFile = currentFile
    }
}

public struct TrashService: Sendable {
    public let scanner: CleanupScanner
    public let journal: URL
    private let history: TrashJournal
    public init(scanner: CleanupScanner = CleanupScanner(), journal: URL? = nil) {
        self.scanner = scanner
        self.journal = journal ?? scanner.home.appendingPathComponent("Library/Application Support/Scruffy/trash-history.json")
        history = TrashJournal(url: self.journal)
    }
    public func records() throws -> [TrashRecord] {
        try history.records()
    }
    /// Set around a cleanup so every file it moves is recorded against that job.
    @TaskLocal public static var cleanupJob: UUID?

    /// Puts back every file the job moved that is still in Trash. Never replaces an existing file.
    public func undo(job: UUID, progress: (@Sendable (UndoOutcome) -> Void)? = nil) throws -> UndoOutcome {
        let moved = try history.records().filter { $0.job == job }
        var outcome = UndoOutcome()
        outcome.total = moved.count
        var lastReport = ContinuousClock.now
        for record in moved {
            try Task.checkCancellation()
            if let trashed = record.trashed, FileManager.default.fileExists(atPath: trashed.path) {
                do { try autoreleasepool { try restore(record) }; outcome.restored += 1 }
                catch { outcome.failed += 1 }
            } else { outcome.missing += 1 }
            if let progress, lastReport.duration(to: .now) >= .milliseconds(200) {
                lastReport = .now; progress(outcome)
            }
        }
        progress?(outcome)
        return outcome
    }
    private func staleFile(_ item: Candidate, all: [Candidate], error: Error) -> Bool {
        guard let safety = error as? SafetyError else { return false }
        let path: String
        let changed: Bool
        switch safety {
        case .changed(let value): path = value; changed = true
        case .unsafe(let value): path = value; changed = false
        case .keeper: return !item.keeper && item.duplicateHash != nil
        default: return false
        }
        // A changed/missing original also makes its dependent duplicate copy ineligible.
        let affected: Candidate?
        if path == item.id { affected = item }
        else { affected = all.first { $0.id == path && $0.keeper && $0.duplicateHash == item.duplicateHash } }
        guard let affected else { return false }
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT }
        // Existing symlinks, hard links or replaced volumes are safety failures, not stale-file skips.
        return changed && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
            && UInt64(info.st_dev) == affected.fingerprint.device
    }
    public func clean(_ selected: [Candidate], all: [Candidate], folders: [URL],
                      browsersRunning: @Sendable () async -> Bool,
                      progress: (@Sendable (CleanupProgress) -> Void)? = nil,
                      moveToTrash: @Sendable (URL) throws -> URL = { url in
                          var result: NSURL?
                          try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                          guard let result else { throw SafetyError.unsafe("Trash location unavailable") }
                          return result as URL
                      }) async throws -> CleanupOutcome {
        // An original may go only when every file of its duplicate group is in this batch.
        // Originals move last, so each copy is still verified against its original first.
        let batch = Set(selected.map(\.id))
        var incomplete = Set<String>()
        for item in all { if let hash = item.duplicateHash, !batch.contains(item.id) { incomplete.insert(hash) } }
        // A lone original is never a whole group: at least one of its copies must be in the batch.
        let copyHashes = Set(selected.lazy.filter { !$0.keeper }.compactMap(\.duplicateHash))
        var wholeGroups = Set<String>()
        for item in selected where item.keeper {
            guard let hash = item.duplicateHash, !incomplete.contains(hash), copyHashes.contains(hash) else { throw SafetyError.keeper }
            wholeGroups.insert(hash)
        }
        let selected = selected.filter { !$0.keeper } + selected.filter(\.keeper)
        var outcome = CleanupOutcome()
        let job = Self.cleanupJob
        let clock = ContinuousClock()
        let cleanStart = clock.now
        // Logged only: the returned outcome is copied before this runs.
        defer {
            var logged = outcome.timings
            logged.add("Whole cleanup", since: cleanStart, items: selected.count)
            PhaseTimings.log.notice("Cleanup timings\n\(logged.summary, privacy: .public)")
        }
        var checked = 0
        var phase = CleanupProgress.Phase.checking
        var currentFile = selected.first?.url.lastPathComponent
        var lastReport = ContinuousClock.now
        func report(force: Bool = false) {
            guard let progress else { return }
            let now = ContinuousClock.now
            guard force || lastReport.duration(to: now) >= .milliseconds(200) else { return }
            lastReport = now
            progress(CleanupProgress(phase: phase, total: selected.count, checked: checked,
                                     moved: outcome.count, skipped: outcome.skippedIDs.count,
                                     bytes: outcome.bytes, currentFile: currentFile))
        }
        report(force: true)
        defer { report(force: true) }
        if selected.contains(where: { $0.category == .browsers }) {
            let started = clock.now
            let running = await browsersRunning()
            outcome.timings.add("Browser-running check", since: started)
            if running {
                outcome.errors.append(SafetyError.browserRunning.localizedDescription)
                return outcome
            }
        }
        // Preflight the entire batch. Stale files stay untouched; unsafe paths still abort before any move.
        var approved: [Candidate] = []
        approved.reserveCapacity(selected.count)
        for item in selected {
            try Task.checkCancellation()
            currentFile = item.url.lastPathComponent
            report()
            let started = clock.now
            defer { outcome.timings.add("Checking: safety check before any move", since: started) }
            do { try autoreleasepool { try scanner.validateSelection([item], all: all, folders: folders, wholeGroups: wholeGroups) } }
            catch {
                guard staleFile(item, all: all, error: error) else { throw error }
                outcome.skippedIDs.append(item.id)
                checked += 1
                continue
            }
            approved.append(item)
            checked += 1
        }
        guard !approved.isEmpty else { return outcome }
        currentFile = nil
        report(force: true)
        let historyStart = clock.now
        try autoreleasepool { _ = try history.records() } // Validate once; subsequent appends stay constant-size.
        outcome.timings.add("Load recovery history", since: historyStart)
        phase = .moving
        currentFile = approved.first?.url.lastPathComponent
        report(force: true)
        for item in approved {
            currentFile = item.url.lastPathComponent
            report()
            var intentID: UUID?
            var attemptedMove = false
            do {
                try Task.checkCancellation()
                if item.category == .browsers {
                    let started = clock.now
                    let running = await browsersRunning()
                    outcome.timings.add("Browser-running check", since: started)
                    if running { throw SafetyError.browserRunning }
                }
                // Bound Foundation temporaries per file, even for queues containing hundreds of thousands of files.
                let journalUpdated = try autoreleasepool {
                    var started = clock.now
                    do { try scanner.validateSelection([item], all: all, folders: folders, wholeGroups: wholeGroups) }
                    catch { outcome.timings.add("Moving: safety recheck", since: started); throw error }
                    outcome.timings.add("Moving: safety recheck", since: started)
                    // Persist intent first; an interrupted move remains in recovery history.
                    let id = UUID(), date = Date()
                    started = clock.now
                    try history.append(TrashRecord(id: id, original: item.url, trashed: nil, fingerprint: item.fingerprint, date: date, job: job))
                    outcome.timings.add("Moving: write recovery record", since: started)
                    intentID = id
                    attemptedMove = true
                    started = clock.now
                    let trashURL = try moveToTrash(item.url)
                    outcome.timings.add("Moving: move to Trash", since: started, bytes: item.bytes)
                    outcome.count += 1
                    outcome.bytes += item.bytes
                    outcome.movedIDs.append(item.id)
                    started = clock.now
                    defer { outcome.timings.add("Moving: write recovery record", since: started) }
                    do { try history.append(TrashRecord(id: id, original: item.url, trashed: trashURL, fingerprint: item.fingerprint, date: date, job: job)) }
                    catch {
                        outcome.errors.append("Moved to Trash, but recovery history could not be updated: \(item.url.path). Recover it using Finder’s Trash.")
                        return false
                    }
                    return true
                }
                if !journalUpdated { break }
            } catch {
                if !attemptedMove && staleFile(item, all: all, error: error) {
                    outcome.skippedIDs.append(item.id)
                    continue
                }
                // A failed move that provably left the original in place is not a recovery item.
                if let intentID, (try? Fingerprint.read(item.url)) == item.fingerprint {
                    do { try history.remove(intentID) }
                    catch { outcome.errors.append("Recovery history could not record the failed move: \(error.localizedDescription)") }
                }
                outcome.errors.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                // Browser reopening, unsafe paths and I/O/journal failures still stop the batch.
                break
            }
        }
        return outcome
    }
    public func restore(_ record: TrashRecord) throws {
        guard let trashed = record.trashed else { throw SafetyError.unsafe("Use Finder’s Trash to locate this item.") }
        let parent = record.original.deletingLastPathComponent()
        guard scanner.allowed(parent),
              !FileManager.default.fileExists(atPath: record.original.path),
              FileManager.default.fileExists(atPath: parent.path),
              try Fingerprint.read(trashed) == record.fingerprint else {
            throw SafetyError.unsafe("Original path is occupied, unavailable, or the trashed file changed. Use Finder’s Trash to recover it.")
        }
        // Never replace existing files and never create missing folder trees.
        try FileManager.default.moveItem(at: trashed, to: record.original)
        try history.remove(record.id)
    }
}
