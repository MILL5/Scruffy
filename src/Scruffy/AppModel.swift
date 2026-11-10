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
    /// Hashes of duplicate groups whose every file, original included, is selected.
    @Published private(set) var fullySelectedGroups = Set<String>()
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
    @Published var history: [TrashRecord] = [] { didSet { historySearch = nil; refreshVisibleHistory(); refreshRestorableJobs() } }
    /// Jobs with at least one moved file still in Trash. Nil until recovery history has been checked.
    @Published private(set) var restorableJobs: Set<UUID>?
    private var restorableGeneration = UUID()
    /// Recovery history narrowed by `historyQuery`, using the same word search as the file lists.
    @Published private(set) var visibleHistory: [TrashRecord] = []
    @Published var historyQuery = "" { didSet { if historyQuery != oldValue { refreshVisibleHistory() } } }
    private var historySearch: PathSearch?
    private var historySearchGeneration = UUID()
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
    /// Phase durations of the last completed scan. Shown as a tooltip on the status line.
    @Published private(set) var scanTimings: PhaseTimings?
    @Published private(set) var runningBrowserNames: [String] = []
    @Published private(set) var browserQuitMessage: String?
    private var task: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var filterGeneration = UUID()
    /// The category whose rows are currently in `visible`.
    private var visibleCategory: CleanupCategory?
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
            if !fullySelectedGroups.isEmpty { fullySelectedGroups = [] }
            return
        }
        let whole = wholeGroups(in: result, selection: selection)
        if whole != fullySelectedGroups { fullySelectedGroups = whole }
        var selected: [Candidate] = []
        var bytes: Int64 = 0
        var counts: [CleanupCategory: Int] = [:], sizes: [CleanupCategory: Int64] = [:]
        // An original counts only when its whole duplicate group was chosen.
        for item in files where selection.contains(item.id) && !isQueued(item)
            && (!item.keeper || item.duplicateHash.map(whole.contains) == true) {
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
    /// Select all never includes originals. Clearing also releases any chosen original.
    func setVisibleSelection(_ selected: Bool) {
        guard !isFiltering else { return }
        if selected { selection.formUnion(visible.lazy.filter { !$0.keeper && !self.isQueued($0) }.map(\.id)) }
        else { selection.subtract(visible.lazy.filter { !self.isQueued($0) }.map(\.id)) }
    }
    private func wholeGroups(in result: ScanResult?, selection: Set<String>) -> Set<String> {
        guard let result, !result.duplicateCounts.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for id in selection { if let hash = result.filesByID[id]?.duplicateHash { counts[hash, default: 0] += 1 } }
        return Set(counts.filter { $0.value > 1 && $0.value == result.duplicateCounts[$0.key] }.keys)
    }
    /// One click on a row's checkbox. Ordinary files toggle. In a duplicate group each click
    /// adds one more file: the clicked copy, then the other copies, the original last.
    /// A click with everything chosen clears the group. `all` chooses the whole group at once.
    func advanceSelection(_ item: Candidate, all: Bool = false) {
        guard !isFiltering, let result, let current = result.filesByID[item.id], !isQueued(current),
              current.fingerprint == item.fingerprint else { return }
        guard let hash = current.duplicateHash else {
            guard !current.keeper else { return }
            if selection.contains(current.id) { selection.remove(current.id) } else { selection.insert(current.id) }
            return
        }
        let group = (result.filesByCategory[.duplicates] ?? []).filter { $0.duplicateHash == hash }
        // While part of the group is already being moved, its original stays protected.
        let locked = group.contains { isQueued($0) }
        let available = group.filter { !isQueued($0) && !(locked && $0.keeper) }
        let unselected = available.filter { !selection.contains($0.id) }
        // An original with no copy left to choose is never selectable on its own.
        guard available.contains(where: { !$0.keeper }) else { return }
        if all { selection.formUnion(available.map(\.id)); return }
        guard !unselected.isEmpty else { selection.subtract(available.map(\.id)); return }
        let next = unselected.first { $0.id == current.id && !$0.keeper } ?? unselected.first { !$0.keeper } ?? unselected[0]
        selection.insert(next.id)
    }
    func setSelection(_ item: Candidate, selected: Bool) {
        guard !isFiltering,
              let current = result?.filesByID[item.id], !current.keeper, !isQueued(current),
              current.fingerprint == item.fingerprint else { return }
        if selected { selection.insert(item.id) }
        else { selection.remove(item.id) }
    }
    func toggleSelection(_ item: Candidate) { advanceSelection(item) }
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
        // Without search words the prepared lists are the answer: publish the title's
        // category and its rows in the same update, with no wait on the search index.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            visibleCategory = category
            visible = category.map { result.filesByCategory[$0] ?? [] } ?? result.filesBySize
            isFiltering = false; return
        }
        // A search is pending for a different category: never leave the previous category's rows up.
        if visibleCategory != category { visibleCategory = category; visible = [] }
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
    private func refreshVisibleHistory() {
        let generation = UUID()
        historySearchGeneration = generation
        let query = historyQuery, records = history, cached = historySearch
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { visibleHistory = records; return }
        Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> (PathSearch, [TrashRecord]) in
                let search = try cached ?? PathSearch(records.map(\.original.path))
                return (search, try search.matches(query).map { records[$0] })
            }
            guard let (search, found) = try? await work.value, historySearchGeneration == generation else { return }
            historySearch = search; visibleHistory = found
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
        scanTimings = nil
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
                scanTimings = found.timings
                let took = found.timings?["Whole scan"].map { " · scan took \(PhaseTimings.format($0.seconds))" } ?? ""
                if !isCleaning { status = "\(result?.categoryCounts.values.reduce(0, +) ?? 0) files ready to review · \(result?.videos.count ?? 0) videos available\(took)." }
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
            let whole = wholeGroups(in: ready, selection: selection)
            selection = selection.filter {
                guard let file = ready.filesByID[$0] else { return false }
                return !file.keeper || file.duplicateHash.map(whole.contains) == true
            }
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
            return try await TrashService.$cleanupJob.withValue(id) {
                try await runner(queue, all, folders) { continuation.yield($0) }
            }
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
    /// Best effort: puts back whatever this job moved that is still in Trash.
    /// Checks Trash for each job's files. Also run when the app comes forward, since Trash can be emptied elsewhere.
    func refreshRestorableJobs() {
        guard loadsHistory else { return }
        let tagged = history.compactMap { record in record.job.flatMap { job in record.trashed.map { (job, $0) } } }
        let generation = UUID(); restorableGeneration = generation
        Task {
            let found = await Task.detached(priority: .utility) {
                var found = Set<UUID>()
                for (job, trashed) in tagged where !found.contains(job) && FileManager.default.fileExists(atPath: trashed.path) {
                    found.insert(job)
                }
                return found
            }.value
            if restorableGeneration == generation { restorableJobs = found }
        }
    }
    /// Finished jobs with nothing left in Trash can be taken off the list. Recovery history is not touched.
    var removableJobs: Set<UUID> {
        guard let restorableJobs else { return [] }
        return Set(cleanupJobs.filter { $0.canRemove(restorable: restorableJobs) }.map(\.id))
    }
    func removeCleanupJob(_ id: UUID) {
        guard removableJobs.contains(id) else { return }
        cleanupJobs.removeAll { $0.id == id }
        persistCleanupJobs()
    }
    func undoCleanup(_ id: UUID) {
        guard let index = cleanupJobs.firstIndex(where: { $0.id == id }), cleanupJobs[index].canUndo else { return }
        cleanupJobs[index].state = .undoing; cleanupJobs[index].undo = UndoOutcome(); cleanupJobs[index].failure = nil
        isCleaning = true
        let service = trash
        let (updates, continuation) = AsyncStream.makeStream(of: UndoOutcome.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try service.undo(job: id) { continuation.yield($0) }
        }
        Task {
            for await progress in updates {
                if let index = cleanupJobs.firstIndex(where: { $0.id == id }) { cleanupJobs[index].undo = progress }
            }
            let result = await work.result
            if let index = cleanupJobs.firstIndex(where: { $0.id == id }) {
                switch result {
                case .success(let outcome): cleanupJobs[index].undo = outcome; cleanupJobs[index].state = .undone
                case .failure(let error): cleanupJobs[index].finish(error: "Undo stopped: \(error.localizedDescription)")
                }
                status = "\(cleanupJobs[index].name): \(cleanupJobs[index].status). Scan again to see restored files."
            }
            isCleaning = cleanupJobs.contains { $0.state.isRunning }
            refreshHistory(); persistCleanupJobs()
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
