import SwiftUI
import AppKit
import CleanupCore

@MainActor
final class AppModel: ObservableObject {
    typealias CleanupRunner = @Sendable ([Candidate], [Candidate], [URL], @escaping @Sendable (CleanupProgress) -> Void) async throws -> CleanupOutcome
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
    @Published private(set) var selectedCategoryCounts: [CleanupCategory: Int] = [:]
    @Published private(set) var selectedCategoryBytes: [CleanupCategory: Int64] = [:]
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published private(set) var cleanupJobs: [CleanupJob] = []
    @Published private(set) var activeCleanupPaths = Set<String>()
    @Published private(set) var activeCleanupCategories = Set<CleanupCategory>()
    @Published private(set) var cleanupHistoryError: String?
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
    private var publicationGeneration = UUID()
    private(set) var latestScanSnapshot: ScanResult?
    private var scanGeneration = UUID()
    private var removedPaths = Set<String>()
    private let loadsHistory: Bool
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    private let cleanupRunner: CleanupRunner
    private let jobStore: CleanupJobStore?
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var jobsLoaded = false
    private var pendingJobSave = false
    private var jobHistoryWritable = true
    private var jobRevision = 0
    let scanner = CleanupScanner()
    let trash: TrashService
    init(loadHistory: Bool = true, cleanupRunner: CleanupRunner? = nil, jobHistoryURL: URL? = nil) {
        let service = TrashService()
        trash = service; loadsHistory = loadHistory
        self.cleanupRunner = cleanupRunner ?? { selected, all, folders, progress in
            try await service.clean(selected, all: all, folders: folders,
                                    browsersRunning: { await AppModel.browsersRunning() }, progress: progress)
        }
        let url = jobHistoryURL ?? (loadHistory ? service.scanner.home.appendingPathComponent("Library/Application Support/Scruffy/cleanup-jobs.json") : nil)
        jobStore = url.map(CleanupJobStore.init)
        refreshHistory(); loadCleanupJobs()
    }
    func isQueued(_ item: Candidate) -> Bool {
        activeCleanupPaths.contains(item.id) || activeCleanupCategories.contains(item.category)
    }
    var files: [Candidate] { result?.files ?? [] }
    private func refreshChosen() {
        guard !selection.isEmpty else {
            chosen = []; selectedBytes = 0; selectedCategoryCounts = [:]; selectedCategoryBytes = [:]
            return
        }
        var selected: [Candidate] = []
        var bytes: Int64 = 0
        var counts: [CleanupCategory: Int] = [:], sizes: [CleanupCategory: Int64] = [:]
        for item in files where !item.keeper && selection.contains(item.id) && !isQueued(item) {
            selected.append(item); bytes += item.bytes
            counts[item.category, default: 0] += 1
            sizes[item.category, default: 0] += item.bytes
        }
        chosen = selected; selectedBytes = bytes
        selectedCategoryCounts = counts; selectedCategoryBytes = sizes
    }
    private func refreshVisibleSelection() {
        var selectable = 0, selected = 0
        for item in visible where !item.keeper && !isQueued(item) {
            selectable += 1
            if selection.contains(item.id) { selected += 1 }
        }
        visibleSelectableCount = selectable
        allVisibleSelected = selectable > 0 && selected == selectable
    }
    func setVisibleSelection(_ selected: Bool) {
        guard !isFiltering else { return }
        let ids = Set(visible.lazy.filter { !$0.keeper && !self.isQueued($0) }.map(\.id))
        if selected { selection.formUnion(ids) }
        else { selection.subtract(ids) }
    }
    func setSelection(_ item: Candidate, selected: Bool) {
        guard !isFiltering,
              let current = result?.filesByID[item.id], !current.keeper, !isQueued(current),
              current.fingerprint == item.fingerprint else { return }
        if selected { selection.insert(item.id) }
        else { selection.remove(item.id) }
    }
    func toggleSelection(_ item: Candidate) {
        setSelection(item, selected: !selection.contains(item.id))
    }
    var candidateBytes: Int64 { result?.candidateBytes ?? 0 }
    var summaryBytes: Int64 { activeCategory.map { bytes($0) } ?? candidateBytes }
    var summarySelectedCount: Int { activeCategory.map { selectedCategoryCounts[$0] ?? 0 } ?? chosen.count }
    var summarySelectedBytes: Int64 { activeCategory.map { selectedCategoryBytes[$0] ?? 0 } ?? selectedBytes }
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
        scanGeneration = generation; removedPaths = []; publishedSnapshotID = nil; latestScanSnapshot = nil
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
                        await publish(partial)
                        if !isCleaning { status = progress }
                    }
                    return try await work.value
                }, onCancel: { work.cancel(); continuation.finish() })
                guard scanGeneration == generation else { return }
                await publish(found, final: true); hasScanned = true
                if !isCleaning { status = "\(result?.categoryCounts.values.reduce(0, +) ?? 0) files ready to review · \(result?.videos.count ?? 0) videos available." }
            } catch is CancellationError { if !isCleaning { status = "Scan stopped. Ready results are still available." } }
            catch { self.error = error.localizedDescription; status = "Scan could not finish." }
            if scanGeneration == generation { isScanning = false }
        }
    }
    func publish(_ found: ScanResult, final: Bool = false, recordsSource: Bool = true) async {
        guard final || publishedSnapshotID != found.id else { return }
        if recordsSource { latestScanSnapshot = found }
        let publication = UUID(), scan = scanGeneration
        publicationGeneration = publication
        let ready: ScanResult
        if removedPaths.isEmpty { ready = found }
        else {
            let removed = removedPaths
            let work = Task.detached(priority: .userInitiated) {
                var files: [Candidate] = []
                files.reserveCapacity(found.files.count)
                for start in stride(from: 0, to: found.files.count, by: 512) {
                    try Task.checkCancellation()
                    autoreleasepool {
                        for item in found.files[start..<min(start + 512, found.files.count)] where !removed.contains(item.id) {
                            files.append(item)
                        }
                    }
                }
                try Task.checkCancellation()
                return ScanResult(files: files, notes: found.notes, videos: found.videos.filter { !removed.contains($0.id) })
            }
            do {
                ready = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            } catch { return }
        }
        guard publicationGeneration == publication, scanGeneration == scan, !Task.isCancelled else { return }
        publishedSnapshotID = found.id
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
        result = nil; selection = []; hasScanned = false; removedPaths = []; publishedSnapshotID = nil; latestScanSnapshot = nil
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
        let browsers = Self.runningBrowsers()
        let requests = browsers.filter { $0.activationPolicy == .regular }.map { $0.terminate() }
        browserQuitMessage = requests.contains(false) || requests.isEmpty
            ? "Some browsers need to be quit manually. Cleanup will wait until they close."
            : "Quit requests sent. Finish any prompts in those browsers; cleanup will wait until they close."
        refreshRunningBrowsers()
    }
    func clean() {
        let selected = chosen.filter { !isQueued($0) }, all = files, folders = options.folders
        guard !selected.isEmpty else { return }
        let groups = Dictionary(grouping: selected, by: \.category)
        error = nil
        for category in CleanupCategory.allCases {
            guard !activeCleanupCategories.contains(category), let queue = groups[category], !queue.isEmpty else { continue }
            let job = CleanupJob(category: category, total: queue.count)
            cleanupJobs.insert(job, at: 0)
            activeCleanupPaths.formUnion(queue.map(\.id)); activeCleanupCategories.insert(category)
            selection.subtract(queue.map(\.id))
            startCleanupJob(job.id, queue: queue, all: all, folders: folders)
        }
        isCleaning = cleanupJobs.contains { $0.state.isRunning }
        refreshChosen(); refreshVisibleSelection(); persistCleanupJobs()
        status = "Background cleanup started. Follow each job below."
    }
    private func startCleanupJob(_ id: UUID, queue: [Candidate], all: [Candidate], folders: [URL]) {
        let runner = cleanupRunner
        let (updates, continuation) = AsyncStream.makeStream(of: CleanupProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try await runner(queue, all, folders) { continuation.yield($0) }
        }
        cleanupTasks[id] = Task {
            for await progress in updates {
                if let index = cleanupJobs.firstIndex(where: { $0.id == id }) { cleanupJobs[index].update(progress) }
            }
            do {
                let outcome = try await work.value
                if let index = cleanupJobs.firstIndex(where: { $0.id == id }) { cleanupJobs[index].state = .finishing }
                await applyCleanupOutcome(outcome, showErrors: false)
                if let index = cleanupJobs.firstIndex(where: { $0.id == id }) { cleanupJobs[index].finish(outcome) }
                releaseCleanupQueue(id, queue: queue)
            } catch {
                if let index = cleanupJobs.firstIndex(where: { $0.id == id }) { cleanupJobs[index].finish(error: error.localizedDescription) }
                releaseCleanupQueue(id, queue: queue)
            }
            if let job = cleanupJobs.first(where: { $0.id == id }) { status = "\(job.name): \(job.status)." }
            cleanupTasks.removeValue(forKey: id)
            persistCleanupJobs()
        }
    }
    private func releaseCleanupQueue(_ id: UUID, queue: [Candidate]) {
        activeCleanupPaths.subtract(queue.map(\.id))
        for category in Set(queue.map(\.category)) { activeCleanupCategories.remove(category) }
        isCleaning = cleanupJobs.contains { $0.state.isRunning }
        refreshChosen(); refreshVisibleSelection()
    }
    private func loadCleanupJobs() {
        guard let jobStore else { jobsLoaded = true; return }
        Task {
            do {
                let saved = try await jobStore.load()
                let known = Set(cleanupJobs.map(\.id))
                cleanupJobs.append(contentsOf: saved.filter { !known.contains($0.id) })
            } catch {
                cleanupHistoryError = "Cannot read background job history: \(error.localizedDescription)"
                jobHistoryWritable = false
            }
            jobsLoaded = true
            if pendingJobSave { persistCleanupJobs() }
        }
    }
    private func persistCleanupJobs() {
        guard let jobStore, jobHistoryWritable else { return }
        guard jobsLoaded else { pendingJobSave = true; return }
        pendingJobSave = false; jobRevision += 1
        let jobs = cleanupJobs, revision = jobRevision
        Task {
            do { try await jobStore.save(jobs, revision: revision) }
            catch { cleanupHistoryError = "Cannot save background job history: \(error.localizedDescription)" }
        }
    }
    func applyCleanupOutcome(_ outcome: CleanupOutcome, showErrors: Bool = true) async {
        status = "\(outcome.count) files (\(formatBytes(outcome.bytes))) moved to Trash."
        if !outcome.skippedIDs.isEmpty {
            status += " \(outcome.skippedIDs.count) changed or missing files left untouched. Scan again to review them."
        }
        status += " Space is released only after you empty Trash."
        if showErrors { error = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "\n") }
        let finished = Set(outcome.movedIDs + outcome.skippedIDs)
        removedPaths.formUnion(finished)
        selection.subtract(finished)
        if !finished.isEmpty, let current = latestScanSnapshot ?? result {
            await publish(current, final: true, recordsSource: false)
        }
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
