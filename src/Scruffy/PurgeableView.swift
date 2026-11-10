import SwiftUI
import AppKit
import CleanupCore

@MainActor
final class PurgeableModel: ObservableObject {
    @Published var report: StorageReport?
    // Busy is reserved for an actual cleanup, not read-only checks.
    @Published private(set) var busy = false
    @Published private(set) var checkingSnapshots = false
    @Published private(set) var checkingSystem = false
    @Published var message: String?
    @Published var error: String?
    @Published var snapshotError: String?
    @Published var systemCleanableBytes: Int64?
    @Published var systemError: String?
    private var generation = 0
    private var lastRefresh: Date?
    var refreshing: Bool { checkingSnapshots || checkingSystem }
    var canCleanSystem: Bool { !busy && !checkingSystem && systemError == nil && (systemCleanableBytes ?? 0) > 0 }
    var canReclaimSnapshots: Bool { !busy && !checkingSnapshots && !(report?.snapshots.isEmpty ?? true) }
    private var systemClient: SystemPurgeClient {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ScruffyStorageHelper")
        let helper = FileManager.default.fileExists(atPath: bundled.path) ? bundled
            : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ScruffyStorageHelper")
        return SystemPurgeClient(helper: helper)
    }
    func refreshIfNeeded() {
        if lastRefresh.map({ Date().timeIntervalSince($0) < 20 }) != true { refresh() }
    }
    func refresh() {
        guard !busy else { return }
        // Independent probes publish immediately; neither waits for the other.
        refreshSnapshots()
        refreshSystem()
    }
    private func refreshSnapshots() {
        guard !busy && !checkingSnapshots else { return }
        checkingSnapshots = true
        snapshotError = nil
        let revision = generation
        Task {
            let result = await Task.detached(priority: .utility) { try PurgeableStorage().report() }.result
            checkingSnapshots = false
            guard revision == generation && !busy else {
                // A cleanup made this in-flight reading stale. Check again once it is done.
                if !busy { refreshSnapshots() }
                return
            }
            switch result {
            case .success(let value): report = value; lastRefresh = Date()
            case .failure(let failure): snapshotError = failure.localizedDescription
            }
        }
    }
    private func refreshSystem() {
        guard !busy && !checkingSystem else { return }
        checkingSystem = true
        systemError = nil
        let client = systemClient, revision = generation
        Task {
            let result = await Task.detached(priority: .utility) { try client.probe() }.result
            checkingSystem = false
            guard revision == generation && !busy else {
                if !busy { refreshSystem() }
                return
            }
            switch result {
            case .success(let value): systemCleanableBytes = value.cleanableBytes; lastRefresh = Date()
            case .failure(let failure): systemError = failure.localizedDescription
            }
        }
    }
    func cleanSystemData() {
        guard canCleanSystem else { return }
        let client = systemClient
        generation += 1
        busy = true; error = nil; message = "Asking macOS to clean eligible purgeable data…"
        Task {
            let measurement = await Task.detached(priority: .userInitiated) {
                await PurgeableStorage().measureReclaim { try client.clean() }
            }.value
            message = freeSpaceMessage(measurement.freeSpaceChange)
            if case .failure(let failure) = measurement.result {
                error = failure.localizedDescription
            }
            busy = false
            refresh()
        }
    }
    func reclaim() {
        guard canReclaimSnapshots else { return }
        generation += 1
        busy = true; message = "Waiting for administrator approval, then asking macOS to reclaim snapshot space…"; error = nil
        Task {
            let measurement = await Task.detached(priority: .userInitiated) {
                let storage = PurgeableStorage()
                return await storage.measureReclaim { try storage.reclaim() }
            }.value
            message = freeSpaceMessage(measurement.freeSpaceChange)
            if case .failure(let failure) = measurement.result {
                error = failure.localizedDescription
            }
            busy = false
            refresh()
        }
    }
    private func freeSpaceMessage(_ change: Int64?) -> String {
        guard let change else { return "Could not verify the change in free space." }
        if change > 0 { return "Free space increased by \(formatBytes(change)) during the request." }
        if change < 0 { return "Free space decreased by \(formatBytes(-change)) during the request." }
        return "Free space did not increase."
    }
}

struct PurgeableView: View {
    @ObservedObject var model: PurgeableModel
    @Environment(\.colorScheme) private var colorScheme
    private enum Confirmation: String, Identifiable {
        case system, snapshots
        var id: String { rawValue }
    }
    @State private var confirmation: Confirmation?
    @State private var acknowledge = false
    @State private var paneSize = CGSize(width: 895, height: 800)
    private var theme: ScruffyTheme { ScruffyTheme(scheme: colorScheme) }
    private var compact: Bool { paneSize.width < 720 || paneSize.height < 680 }
    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: paneSize.width < 500 ? 1 : (paneSize.width < 720 ? 2 : 3))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purgeable space").font(.system(size: compact ? 23 : 27, weight: .semibold, design: .rounded))
                        Text("Clean macOS-marked discardable data and caches, with local backups managed separately.")
                            .font(compact ? .caption : .body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(model.refreshing ? "Refreshing…" : "Refresh") { model.refresh() }.buttonStyle(BrandButtonStyle()).fixedSize().disabled(model.busy || model.refreshing)
                }
                if let report = model.report {
                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                        metric("Free now", value: formatBytes(report.capacity.free), icon: "internaldrive")
                        metric("Reclaimable estimate", value: report.capacity.reclaimableEstimate.map(formatBytes) ?? "Unavailable", icon: "arrow.triangle.2.circlepath")
                        metric("Time Machine snapshots", value: String(report.snapshots.count), icon: "clock.arrow.circlepath")
                    }
                    Text("The estimate is macOS’s available-for-important-use capacity minus free space. It is not a measured snapshot size or a promise that Scruffy can reclaim all of it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                systemSection
                if model.busy { HStack { ProgressView().controlSize(.small); Text(model.message ?? "Cleaning…").font(.subheadline) } }
                else if model.refreshing { HStack { ProgressView().controlSize(.small); Text("Checking storage in the background. Ready items can be cleaned now.").font(.caption).foregroundStyle(.secondary) } }
                if let message = model.message, !model.busy { Text(message).font(.subheadline).foregroundStyle(theme.accent) }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).textSelection(.enabled) }
                if let report = model.report {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Reclaim local snapshot space", systemImage: "clock.arrow.circlepath").font(.title3.bold()).foregroundStyle(theme.accent)
                        Text("macOS normally reclaims purgeable storage automatically. This action asks Time Machine to thin eligible local snapshots. It keeps current files and backups on your backup disk, but removes some local restore points permanently.")
                        if report.snapshots.isEmpty {
                            Text("No eligible Time Machine snapshots found. You can still clean purgeable data above.").font(.subheadline.bold())
                        } else {
                            Text("Requests all eligible snapshot space, with no app-imposed size limit. macOS decides which snapshots it can remove.").font(.caption).foregroundStyle(.secondary)
                        }
                        if report.protectedSnapshotCount > 0 {
                            Text("\(counted(report.protectedSnapshotCount, "system-update snapshot")) \(report.protectedSnapshotCount == 1 ? "is" : "are") protected and excluded.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Review snapshot reclaim…") { acknowledge = false; confirmation = .snapshots }
                            .buttonStyle(BrandButtonStyle()).disabled(!model.canReclaimSnapshots)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border))
                    if !report.snapshots.isEmpty {
                        DisclosureGroup("Local restore points (\(report.snapshots.count))") {
                            ForEach(report.snapshots, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                }
                if let error = model.snapshotError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Other purgeable storage").font(.headline)
                    Text("Cloud downloads, active swap, update data and other protected storage remain managed by macOS. Scruffy does not fill your disk to force a purge or delete protected files directly. Browser and developer caches also have separate review categories.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Open macOS Storage settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link)
                }
            }.padding(compact ? 18 : 28)
        }
        .background(theme.canvas).foregroundStyle(theme.text)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { paneSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in paneSize = size }
            }
        }
        .task {
            model.refreshIfNeeded()
            // Look ahead only while this pane is visible; no background timer after navigation.
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                    model.refreshIfNeeded()
                }
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshIfNeeded()
        }
        .sheet(item: $confirmation) { action in
          ResponsiveSheet(width: 560, idealHeight: 600, windowSize: paneSize) {
            VStack(alignment: .leading, spacing: 20) {
                Label(action == .system ? "Clean purgeable data?" : "Remove local restore points?", systemImage: "exclamationmark.triangle").font(.title2.bold())
                if action == .system {
                    Text("Ask macOS to remove all eligible discardable data and app caches, with no app-imposed size limit. The actual amount depends on what macOS agrees to release.")
                    Text("Cleanup bypasses Trash. Cached data may need to be rebuilt or downloaded again. This restricted request does not include cloud documents, Time Machine snapshots or system-update snapshots.")
                    Toggle("I understand this permanently removes eligible cache data.", isOn: $acknowledge)
                } else {
                    Text("Ask macOS to reclaim as much space as possible from eligible local Time Machine snapshots on your startup disk, with no app-imposed size limit.")
                    Text("This bypasses Trash. Removed local snapshots cannot be restored by Scruffy. Current files and external backup-disk backups are not targeted. You may lose the ability to recover older or deleted files from these local restore points.")
                    Toggle("I understand that local restore points may be permanently removed.", isOn: $acknowledge)
                    Text("macOS will ask for administrator approval. Cancelling that prompt stops the request.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { confirmation = nil }
                    Spacer()
                    Button(action == .system ? "Clean purgeable data" : "Reclaim snapshot space") {
                        confirmation = nil
                        if action == .system { model.cleanSystemData() } else { model.reclaim() }
                    }.buttonStyle(BrandButtonStyle()).disabled(!acknowledge)
                }
            }
          }
        }
    }
    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Clean purgeable data", systemImage: "sparkles").font(.title3.bold()).foregroundStyle(theme.accent)
            if model.checkingSystem || (model.systemCleanableBytes == nil && model.systemError == nil) {
                Text("Checking macOS’s purgeable-data service…").foregroundStyle(.secondary)
            } else if let error = model.systemError {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
            } else if model.systemCleanableBytes == 0 {
                Text("macOS reports no cache data available to clean right now.").foregroundStyle(.secondary)
            }
            Text("Ask macOS to remove data apps marked discardable and eligible app-container caches. This action does not target cloud documents, Time Machine snapshots or system-update snapshots. Apps may rebuild or download cache data afterward.").font(.subheadline)
            Text("macOS decides how much it can release. Scruffy measures the net change in free space, which includes other disk activity.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clean purgeable data…") { acknowledge = false; confirmation = .system }
                .buttonStyle(BrandButtonStyle()).disabled(!model.canCleanSystem)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border))
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(theme.accent)
            Text(value).font(.system(size: compact ? 21 : 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }.padding(compact ? 14 : 18).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border))
    }
}
