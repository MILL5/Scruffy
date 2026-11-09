import Foundation

public struct TrashRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let original: URL
    public var trashed: URL?
    public let fingerprint: Fingerprint
    public let date: Date
}

public struct CleanupOutcome: Sendable {
    public var count = 0
    public var bytes: Int64 = 0
    public var errors: [String] = []
    public var movedIDs: [String] = []
}

public struct TrashService: Sendable {
    public let scanner: CleanupScanner
    public let journal: URL
    public init(scanner: CleanupScanner = CleanupScanner(), journal: URL? = nil) {
        self.scanner = scanner
        self.journal = journal ?? scanner.home.appendingPathComponent("Library/Application Support/Scruffy/trash-history.json")
    }
    public func records() throws -> [TrashRecord] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        return try JSONDecoder().decode([TrashRecord].self, from: Data(contentsOf: journal))
    }
    private func save(_ records: [TrashRecord]) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: journal, options: .atomic)
    }
    public func clean(_ selected: [Candidate], all: [Candidate], folders: [URL],
                      browsersRunning: @Sendable () async -> Bool,
                      moveToTrash: @Sendable (URL) throws -> URL = { url in
                          var result: NSURL?
                          try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                          guard let result else { throw SafetyError.unsafe("Trash location unavailable") }
                          return result as URL
                      }) async throws -> CleanupOutcome {
        try scanner.validateSelection(selected, all: all, folders: folders)
        var history = try records()
        var outcome = CleanupOutcome()
        for item in selected {
            do {
                try Task.checkCancellation()
                if item.category == .browsers {
                    if await browsersRunning() { throw SafetyError.browserRunning }
                }
                try scanner.validateSelection([item], all: all, folders: folders)
                // Persist intent first; if interrupted, the original path remains in the recovery history.
                let id = UUID()
                history.append(TrashRecord(id: id, original: item.url, trashed: nil, fingerprint: item.fingerprint, date: Date()))
                try save(history)
                let trashURL = try moveToTrash(item.url)
                history[history.count - 1].trashed = trashURL
                outcome.count += 1
                outcome.bytes += item.bytes
                outcome.movedIDs.append(item.id)
                do { try save(history) }
                catch {
                    outcome.errors.append("Moved to Trash, but recovery history could not be updated: \(item.url.path). Recover it using Finder’s Trash.")
                    break
                }
            } catch {
                outcome.errors.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                // Fail closed: do not continue a batch after a safety check or write failure.
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
        var history = try records()
        history.removeAll { $0.id == record.id }
        try save(history)
    }
}
