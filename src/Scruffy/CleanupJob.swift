import Foundation
import CleanupCore

struct CleanupJob: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, checking, moving, finishing, completed, failed
        var isRunning: Bool { self == .queued || self == .checking || self == .moving || self == .finishing }
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
    var processed: Int { moved + skipped }
    var progress: Double {
        if state == .completed { return 1 }
        return min(1, Double(state == .checking ? checked : processed) / Double(max(1, total)))
    }
    var status: String {
        switch state {
        case .queued: "Queued · 0 of \(total.formatted()) files"
        case .checking:
            checked == total ? "Preparing recovery history · \(checked.formatted()) files checked"
                : "Checking file \(min(checked + 1, total).formatted()) of \(total.formatted())"
        case .moving:
            "Moving file \(min(processed + 1, total).formatted()) of \(total.formatted())"
        case .finishing:
            "Updating results · \(processed.formatted()) of \(total.formatted()) files processed"
        case .completed:
            "Completed · \(processed.formatted()) of \(total.formatted()) files processed"
        case .failed:
            "Failed · \(processed.formatted()) of \(total.formatted()) files processed"
        }
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
