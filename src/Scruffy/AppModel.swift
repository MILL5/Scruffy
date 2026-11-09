import SwiftUI
import AppKit
import CleanupCore

@MainActor
final class AppModel: ObservableObject {
    @Published var options = ScanOptions(folders: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")])
    @Published var result: ScanResult? { didSet { updateSearchIndex(); refreshVisible(); refreshChosen() } }
    @Published private(set) var visible: [Candidate] = [] { didSet { refreshVisibleSelection() } }
    @Published private(set) var isFiltering = false
    @Published private(set) var visibleSelectableCount = 0
    @Published private(set) var allVisibleSelected = false
    @Published var selection = Set<String>() {
        didSet {
            if selection != oldValue { refreshChosen(); refreshVisibleSelection() }
        }
    }
    @Published private(set) var chosen: [Candidate] = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published var isScanning = false
    @Published var isCleaning = false
    var busy: Bool { isScanning || isCleaning }
    @Published var status = "Your files. Your call."
    @Published var error: String?
    @Published var history: [TrashRecord] = []
    @Published private(set) var isLoadingHistory = false
    @Published var activeCategory: CleanupCategory? {
        didSet {
            if activeCategory != oldValue { query = sectionQueries[activeCategory?.rawValue ?? "Overview"] ?? "" }
        }
    }
    @Published var query = "" {
        didSet {
            sectionQueries[activeCategory?.rawValue ?? "Overview"] = query
            refreshVisible()
        }
    }
    @Published var hasScanned = false
    @Published private(set) var runningBrowserNames: [String] = []
    @Published private(set) var browserQuitMessage: String?
    private var task: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var filterGeneration = UUID()
    private let searchIndex = FileSearchIndex()
    private var indexTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var sectionQueries: [String: String] = [:]
    private var publishedSnapshotID: UUID?
    private var scanGeneration = UUID()
    private var removedPaths = Set<String>()
    private let loadsHistory: Bool
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    let scanner = CleanupScanner()
    let trash = TrashService()
    init(loadHistory: Bool = true) { loadsHistory = loadHistory; refreshHistory() }
    var files: [Candidate] { result?.files ?? [] }
    private func refreshChosen() {
        guard !selection.isEmpty else { chosen = []; selectedBytes = 0; return }
        var selected: [Candidate] = []
        var bytes: Int64 = 0
        for item in files where !item.keeper && selection.contains(item.id) {
            selected.append(item); bytes += item.bytes
        }
        chosen = selected; selectedBytes = bytes
    }
    private func refreshVisibleSelection() {
        var selectable = 0, selected = 0
        for item in visible where !item.keeper {
            selectable += 1
            if selection.contains(item.id) { selected += 1 }
        }
        visibleSelectableCount = selectable
        allVisibleSelected = selectable > 0 && selected == selectable
    }
    func setVisibleSelection(_ selected: Bool) {
        guard !isCleaning, !isFiltering else { return }
        let ids = Set(visible.lazy.filter { !$0.keeper }.map(\.id))
        if selected { selection.formUnion(ids) }
        else { selection.subtract(ids) }
    }
    func setSelection(_ item: Candidate, selected: Bool) {
        guard !isCleaning, !isFiltering,
              let current = result?.filesByID[item.id], !current.keeper,
              current.fingerprint == item.fingerprint else { return }
        if selected { selection.insert(item.id) }
        else { selection.remove(item.id) }
    }
    func toggleSelection(_ item: Candidate) {
        setSelection(item, selected: !selection.contains(item.id))
    }
    var candidateBytes: Int64 { result?.candidateBytes ?? 0 }
    var summaryBytes: Int64 { activeCategory.map { bytes($0) } ?? candidateBytes }
    var summaryCategories: [CleanupCategory] {
        CleanupCategory.allCases.filter { $0 != .videos && (activeCategory == nil || $0 == activeCategory) && bytes($0) > 0 }
    }
    var hasSelectionOutsideCategory: Bool {
        guard let activeCategory else { return false }
        return chosen.contains { $0.category != activeCategory }
    }
    func count(_ category: CleanupCategory) -> Int {
        category == .videos ? (result?.videos.count ?? 0) : (result?.categoryCounts[category] ?? 0)
    }
    func bytes(_ category: CleanupCategory) -> Int64 {
        category == .videos ? (result?.videoBytes ?? 0) : (result?.categoryBytes[category] ?? 0)
    }
    private func updateSearchIndex() {
        indexTask?.cancel()
        guard let result else { searchGeneration = UUID(); return }
        let index = searchIndex, generation = searchGeneration
        indexTask = Task.detached(priority: .utility) { try? await index.update(result, generation: generation) }
    }
    private func refreshVisible() {
        filterTask?.cancel()
        let generation = UUID()
        filterGeneration = generation
        guard let result else { visible = []; isFiltering = false; return }
        let category = activeCategory, query = query
        guard category != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            visible = result.filesBySize; isFiltering = false; return
        }
        let index = searchIndex, indexGeneration = searchGeneration
        isFiltering = true
        filterTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                let matches = try await index.search(query, category: category, result: result, generation: indexGeneration)
                try Task.checkCancellation()
                return matches.sorted(by: Candidate.largestFirst)
            }
            do {
                let filtered = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard generation == filterGeneration else { return }
                visible = filtered; isFiltering = false
            } catch is CancellationError { }
            catch {
                guard generation == filterGeneration else { return }
                visible = []; isFiltering = false
                self.error = "Search could not finish: \(error.localizedDescription)"
            }
        }
    }
    func refreshHistory() {
        guard loadsHistory else { return }
        historyTask?.cancel()
        let generation = UUID(), store = trash
        historyGeneration = generation; isLoadingHistory = true
        historyTask = Task {
            let work = Task.detached(priority: .utility) { Array(try store.records().reversed()) }
            do {
                let records = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard historyGeneration == generation else { return }
                history = records
            } catch is CancellationError { }
            catch {
                guard historyGeneration == generation else { return }
                self.error = "Cannot read recovery history: \(error.localizedDescription)"
            }
            if historyGeneration == generation { isLoadingHistory = false }
        }
    }
    func scan() {
        guard !busy else { return }
        let snapshot = options
        let generation = UUID()
        scanGeneration = generation; removedPaths = []; publishedSnapshotID = nil
        isScanning = true; selection = []; result = nil; status = "Scanning local files…"; error = nil
        task = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: (ScanResult, String).self, bufferingPolicy: .bufferingNewest(1))
            let work = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                return try CleanupScanner().scan(snapshot, progress: { partial, progress in
                    continuation.yield((partial, progress))
                })
            }
            do {
                let found = try await withTaskCancellationHandler(operation: {
                    for await (partial, progress) in updates {
                        guard scanGeneration == generation, !Task.isCancelled else { break }
                        publish(partial)
                        if !isCleaning { status = progress }
                    }
                    return try await work.value
                }, onCancel: { work.cancel(); continuation.finish() })
                guard scanGeneration == generation else { return }
                publish(found, final: true); hasScanned = true
                if !isCleaning { status = "\(result?.categoryCounts.values.reduce(0, +) ?? 0) files ready to review · \(result?.videos.count ?? 0) videos available." }
            } catch is CancellationError { if !isCleaning { status = "Scan stopped. Ready results are still available." } }
            catch { self.error = error.localizedDescription; status = "Scan could not finish." }
            if scanGeneration == generation { isScanning = false }
        }
    }
    func publish(_ found: ScanResult, final: Bool = false) {
        guard final || publishedSnapshotID != found.id else { return }
        publishedSnapshotID = found.id
        let ready = removedPaths.isEmpty ? found : ScanResult(files: found.files.filter { !removedPaths.contains($0.id) }, notes: found.notes,
                                                           videos: found.videos.filter { !removedPaths.contains($0.id) })
        if !ready.files.isEmpty || !ready.videos.isEmpty || final { result = ready }
        if !selection.isEmpty {
            selection = selection.filter { ready.filesByID[$0]?.keeper == false }
        }
    }
    func cancel() { task?.cancel() }
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Choose local personal folders. Cloud folders and protected locations are excluded."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard scanner.allowed(url), !scanner.isWithin(url, scanner.home.appendingPathComponent("Library")) else {
                error = "This location is protected or outside your home folder: \(url.path)"; continue
            }
            if !options.folders.contains(url) { options.folders.append(url) }
        }
        invalidate()
    }
    func invalidate() {
        task?.cancel(); scanGeneration = UUID(); isScanning = false
        result = nil; selection = []; hasScanned = false; removedPaths = []; publishedSnapshotID = nil
        status = "Scan settings changed. Ready for a fresh look."
    }
    static func isSupportedBrowser(_ bundleIdentifier: String) -> Bool {
        ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.apple.SafariTechnologyPreview"].contains {
            bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".")
        }
    }
    static func runningBrowsers() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            let id = $0.bundleIdentifier ?? ""
            return isRunningBrowser(bundleIdentifier: id, isRegularApplication: $0.activationPolicy == .regular,
                                    isTerminated: $0.isTerminated)
        }
    }
    static func isRunningBrowser(bundleIdentifier: String, isRegularApplication: Bool, isTerminated: Bool) -> Bool {
        isRegularApplication && !isTerminated && !bundleIdentifier.lowercased().contains(".helper")
            && isSupportedBrowser(bundleIdentifier)
    }
    static func browsersRunning() -> Bool { !runningBrowsers().isEmpty }
    var browserCleanupBlocked: Bool {
        !runningBrowserNames.isEmpty && chosen.contains { $0.category == .browsers }
    }
    func refreshRunningBrowsers() {
        let names = Set(Self.runningBrowsers().map { $0.localizedName ?? $0.bundleIdentifier ?? "Browser" }).sorted()
        if names != runningBrowserNames { runningBrowserNames = names }
        if names.isEmpty { browserQuitMessage = nil }
    }
    func requestBrowserQuit() {
        guard !isCleaning else { return }
        let browsers = Self.runningBrowsers()
        let requests = browsers.filter { $0.activationPolicy == .regular }.map { $0.terminate() }
        browserQuitMessage = requests.contains(false) || requests.isEmpty
            ? "Some browsers need to be quit manually. Cleanup will wait until they close."
            : "Quit requests sent. Finish any prompts in those browsers; cleanup will wait until they close."
        refreshRunningBrowsers()
    }
    func clean() {
        let selected = chosen, all = files, folders = options.folders
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true; error = nil; status = "Checking ready files and moving approved items to Trash…"
        Task {
            let work = Task.detached(priority: .userInitiated) {
                try await TrashService().clean(selected, all: all, folders: folders, browsersRunning: { await AppModel.browsersRunning() })
            }
            do {
                let outcome = try await work.value
                applyCleanupOutcome(outcome)
            } catch { self.error = error.localizedDescription; status = "Cleanup stopped. Review the message before scanning again." }
            isCleaning = false
        }
    }
    func applyCleanupOutcome(_ outcome: CleanupOutcome) {
        status = "\(outcome.count) files (\(formatBytes(outcome.bytes))) moved to Trash."
        if !outcome.skippedIDs.isEmpty {
            status += " \(outcome.skippedIDs.count) changed or missing files left untouched. Scan again to review them."
        }
        status += " Space is released only after you empty Trash."
        error = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "\n")
        let finished = Set(outcome.movedIDs + outcome.skippedIDs)
        removedPaths.formUnion(finished)
        if let current = result { publish(current, final: true) }
        selection.subtract(finished)
        refreshHistory()
    }
    func restore(_ record: TrashRecord) {
        do { try trash.restore(record); refreshHistory(); invalidate(); status = "Restored \(record.original.lastPathComponent)." }
        catch { self.error = error.localizedDescription }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: bytes)
}
