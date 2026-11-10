import SwiftUI

struct CleanupJobsView: View {
    let jobs: [CleanupJob]
    let historyError: String?
    let availableSize: CGSize
    @Binding var isExpanded: Bool
    var onUndo: (UUID) -> Void = { _ in }
    var removable: Set<UUID> = []
    var onRemove: (UUID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ScruffyTheme { ScruffyTheme(scheme: colorScheme) }
    init(jobs: [CleanupJob], historyError: String?, availableSize: CGSize, isExpanded: Binding<Bool> = .constant(true),
         onUndo: @escaping (UUID) -> Void = { _ in }, removable: Set<UUID> = [], onRemove: @escaping (UUID) -> Void = { _ in }) {
        self.jobs = jobs; self.historyError = historyError; self.availableSize = availableSize
        _isExpanded = isExpanded; self.onUndo = onUndo; self.removable = removable; self.onRemove = onRemove
    }
    private var columns: Int { availableSize.width >= 680 ? 2 : 1 }
    private var running: Int { jobs.filter { $0.state.isRunning }.count }
    private var orderedJobs: [CleanupJob] {
        jobs.sorted {
            let left = $0.state.isRunning ? 0 : ($0.state == .failed ? 1 : 2)
            let right = $1.state.isRunning ? 0 : ($1.state == .failed ? 1 : 2)
            return left == right ? $0.startedAt > $1.startedAt : left < right
        }
    }
    private var panelHeight: CGFloat {
        guard isExpanded else { return 38 }
        let rows = (jobs.count + columns - 1) / columns
        let desired = CGFloat(rows) * 64 + (historyError == nil ? 36 : 62)
        return min(max(100, min(280, availableSize.height * 0.45)), desired)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack {
                Label("Background cleanup", systemImage: "list.bullet.rectangle").font(.subheadline.bold())
                Spacer()
                Text("\(running) running · \(jobs.filter { $0.state == .failed }.count) failed")
                    .font(.caption).foregroundStyle(.secondary)
                Button(isExpanded ? "Collapse" : "Show jobs") { isExpanded.toggle() }.font(.caption).buttonStyle(.borderless)
            }.padding(.horizontal, 16)
            if isExpanded {
              if let historyError { Text(historyError).font(.caption).foregroundStyle(.red).padding(.horizontal, 16) }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: columns), spacing: 8) {
                    ForEach(orderedJobs) { job in CleanupJobRow(job: job, theme: theme, canRemove: removable.contains(job.id), undo: { onUndo(job.id) }, remove: { onRemove(job.id) }) }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            }
        }.frame(height: panelHeight).background(theme.canvas).foregroundStyle(theme.text)
            .onAppear { isExpanded = jobs.contains { $0.state.isRunning || $0.state == .failed } || historyError != nil }
            .onChange(of: running) { old, new in if new > old { isExpanded = true } }
    }
}

private struct CleanupJobRow: View {
    let job: CleanupJob
    let theme: ScruffyTheme
    var canRemove = false
    var undo: () -> Void = {}
    var remove: () -> Void = {}
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Label(job.name, systemImage: job.state == .failed ? "exclamationmark.circle" : (job.state == .completed ? "checkmark.circle" : "tray.and.arrow.down"))
                    .font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 2)
                if job.state.isRunning && job.state != .undoing { Text(job.startedAt, style: .timer).font(.caption2.monospacedDigit()) }
                if canRemove {
                    Button("Remove", action: remove).font(.caption).buttonStyle(.borderless)
                        .help("Nothing from this job is left in Trash. Take it off this list.")
                } else if job.canUndo {
                    Button("Undo", action: undo).font(.caption).buttonStyle(.borderless)
                        .help("Put back the files this job moved that are still in Trash")
                }
                Button { details = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Details for \(job.name)")
            }
            Text(job.status).font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(job.state == .failed ? Color.red : theme.text)
            HStack(spacing: 8) {
                ProgressView(value: job.progress).progressViewStyle(.linear).tint(job.state == .failed ? .red : theme.accent)
                    .accessibilityLabel("\(job.name): \(job.status)")
                Text(job.state == .failed ? "Will not resume" : "\(job.moved.formatted()) moved · \(job.skipped.formatted()) skipped")
                    .font(.caption2).foregroundStyle(job.state == .failed ? Color.red : .secondary).fixedSize()
            }
        }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border))
            .help(job.failure ?? job.currentFile ?? job.status)
            .popover(isPresented: $details) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.name).font(.headline)
                    Text(job.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(job.status).monospacedDigit()
                    Text("\(job.moved.formatted()) moved · \(job.skipped.formatted()) skipped · \(formatBytes(job.bytes))")
                    if let current = job.currentFile { Text(current).font(.caption).textSelection(.enabled) }
                    if let timings = job.timings {
                        Text("Where the time went").fontWeight(.semibold)
                        Text(timings.summary).font(.caption).monospacedDigit().textSelection(.enabled)
                    }
                    if let failure = job.failure {
                        Text("This worker will not resume automatically.").fontWeight(.semibold)
                        Text(failure).font(.caption).textSelection(.enabled)
                    }
                }.padding(18).frame(width: 340, alignment: .leading)
            }
    }
}
