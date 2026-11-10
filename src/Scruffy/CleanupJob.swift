import Foundation
import CleanupCore

struct CleanupJob: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, checking, moving, finishing, completed, failed, undoing, undone
        var isRunning: Bool { self == .queued || self == .checking || self == .moving || self == .finishing || self == .undoing }
    }
    let id: UUID
    let name: String
    let category: String
    let total: Int
    let startedAt: Date
    var finishedAt: Date?
    var state = State.queued
    var checked = 0
    var moved = 0
    var skipped = 0
    var bytes: Int64 = 0
    var currentFile: String?
    var failure: String?
    /// Optional so job history saved by earlier builds still loads.
    var timings: PhaseTimings?
    /// Counts from undoing this job. Optional so earlier job history still loads.
    var undo: UndoOutcome?
    var canUndo: Bool { (state == .completed || state == .failed) && moved > 0 }
    /// True once the job has stopped and none of its files are still in Trash.
    func canRemove(restorable: Set<UUID>) -> Bool { !state.isRunning && !restorable.contains(id) }
    var processed: Int { moved + skipped }
    var progress: Double {
        if state == .completed || state == .undone { return 1 }
        if state == .undoing { return min(1, Double(undo?.processed ?? 0) / Double(max(1, undo?.total ?? 0))) }
        return min(1, Double(state == .checking ? checked : processed) / Double(max(1, total)))
    }
    var status: String {
        switch state {
        case .queued: "Queued · 0 of \(fileCount(total))"
        case .checking:
            checked == total ? "Preparing recovery history · \(fileCount(checked)) checked"
                : "Checking file \(min(checked + 1, total).formatted()) of \(total.formatted())"
        case .moving:
            "Moving file \(min(processed + 1, total).formatted()) of \(total.formatted())"
        case .finishing:
            "Updating results · \(processed.formatted()) of \(fileCount(total)) processed"
        case .completed:
            "Completed · \(processed.formatted()) of \(fileCount(total)) processed"
        case .failed:
            "Failed · \(processed.formatted()) of \(fileCount(total)) processed"
        case .undoing:
            "Restoring \((undo?.processed ?? 0).formatted()) of \((undo?.total ?? 0).formatted())"
        case .undone:
            Self.undoSummary(undo ?? UndoOutcome())
        }
    }
    /// Numbers only: what came back, what was already gone, what could not be put back.
    static func undoSummary(_ undo: UndoOutcome) -> String {
        guard undo.total > 0 else { return "Undone · nothing left to restore" }
        var parts = ["\(undo.restored.formatted()) restored"]
        if undo.missing > 0 { parts.append("\(undo.missing.formatted()) already deleted") }
        if undo.failed > 0 { parts.append("\(undo.failed.formatted()) not restored") }
        return "Undone · " + parts.joined(separator: " · ")
    }
    init(category: CleanupCategory, total: Int) {
        id = UUID(); self.category = category.rawValue; self.total = total; startedAt = Date()
        name = switch category {
        case .duplicates: "Duplicate cleanup"
        case .downloads: "Old downloads cleanup"
        case .browsers: "Browser cache cleanup"
        case .caches: "Developer cache cleanup"
        case .temporary: "Temporary file cleanup"
        case .large: "Large file cleanup"
        case .videos: "Video file cleanup"
        }
    }
    mutating func update(_ progress: CleanupProgress) {
        guard state.isRunning else { return }
        state = progress.phase == .checking ? .checking : .moving
        checked = progress.checked; moved = progress.moved; skipped = progress.skipped
        bytes = progress.bytes; currentFile = progress.currentFile
    }
    mutating func finish(_ outcome: CleanupOutcome) {
        moved = outcome.count; skipped = outcome.skippedIDs.count; bytes = outcome.bytes
        timings = outcome.timings.isEmpty ? nil : outcome.timings
        let error = outcome.errors.isEmpty ? (processed == total ? nil : "Worker ended before processing all files. It will not resume.")
            : outcome.errors.joined(separator: "\n")
        finish(error: error)
    }
    mutating func finish(error: String?) {
        state = error == nil ? .completed : .failed
        failure = error; currentFile = nil; finishedAt = Date()
    }
}

/// Saves status only. File queues are never loaded or automatically resumed.
actor CleanupJobStore {
    let url: URL
    private var savedRevision = 0
    init(url: URL) { self.url = url }
    func load() throws -> [CleanupJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var jobs = try JSONDecoder().decode([CleanupJob].self, from: Data(contentsOf: url))
        for index in jobs.indices where jobs[index].state.isRunning {
            jobs[index].finish(error: "Interrupted when Scruffy closed. Last saved progress is shown; this worker will not resume.")
        }
        return jobs
    }
    func save(_ jobs: [CleanupJob], revision: Int) throws {
        guard revision > savedRevision else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        savedRevision = revision
    }
}
