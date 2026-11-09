import SwiftUI
import AppKit
import QuickLook
import CleanupCore

@MainActor
final class VideoModel: ObservableObject {
    typealias Compressor = @Sendable (Candidate, [URL], (@Sendable (Double) -> Void)?) async throws -> VideoCompressionOutcome

    @Published private(set) var files: [Candidate] = []
    @Published private(set) var visible: [Candidate] = [] { didSet { refreshVisibleSelection() } }
    @Published var query = "" { didSet { search() } }
    @Published var selection = Set<String>() {
        didSet {
            if selection != oldValue { refreshSelection(); refreshVisibleSelection() }
        }
    }
    @Published private(set) var chosen: [Candidate] = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var visibleSelectableCount = 0
    @Published private(set) var allVisibleSelected = false
    @Published private(set) var isFiltering = false
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFile: String?
    @Published private(set) var savedBytes: Int64 = 0
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private var folders: [URL] = []
    private var result = ScanResult(files: [], notes: [])
    private var completed: [String: Fingerprint] = [:]
    private let compressor: Compressor
    private let index = FileSearchIndex()
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var compressionTask: Task<Void, Never>?
    private var indexGeneration = UUID()
    private var searchGeneration = UUID()
    private var compressionGeneration = UUID()

    init(compressor: Compressor? = nil) {
        self.compressor = compressor ?? { item, folders, progress in
            try await VideoCompressionService().compress(item, folders: folders, progress: progress)
        }
    }

    func update(_ candidates: [Candidate], folders: [URL]) {
        self.folders = folders
        if candidates.isEmpty && !busy { completed.removeAll() }
        let eligible = candidates.filter { completed[$0.id] != $0.fingerprint }
        guard !sameFiles(eligible, files) else { return }
        let current = eligible.sorted {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
        guard !sameFiles(current, files) else { return }
        let previous = result.filesByID
        files = current
        totalBytes = current.reduce(0) { $0 + $1.bytes }
        result = ScanResult(files: current, notes: [])
        let valid = result.filesByID
        selection = selection.filter {
            valid[$0]?.keeper == false && previous[$0]?.fingerprint == valid[$0]?.fingerprint
        }
        refreshSelection()
        indexTask?.cancel()
        if current.isEmpty { indexGeneration = UUID() }
        else {
            let index = index, snapshot = result, generation = indexGeneration
            indexTask = Task.detached(priority: .utility) {
                do { try await index.update(snapshot, generation: generation) } catch { }
            }
        }
        search()
    }

    private func sameFiles(_ lhs: [Candidate], _ rhs: [Candidate]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id && left.fingerprint == right.fingerprint && left.keeper == right.keeper && left.category == right.category
        }
    }

    private func search() {
        searchTask?.cancel()
        let revision = UUID()
        searchGeneration = revision
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            visible = files; isFiltering = false; return
        }
        let snapshot = result, query = query, index = index, generation = indexGeneration
        isFiltering = true
        searchTask = Task {
            do {
                let matches = try await index.search(query, category: .videos, result: snapshot, generation: generation)
                guard revision == searchGeneration else { return }
                visible = matches; isFiltering = false
            } catch is CancellationError { }
            catch {
                guard revision == searchGeneration else { return }
                visible = []; isFiltering = false; self.error = error.localizedDescription
            }
        }
    }

    private func refreshSelection() {
        chosen = files.filter { !$0.keeper && selection.contains($0.id) }
        selectedBytes = chosen.reduce(0) { $0 + $1.bytes }
    }

    private func refreshVisibleSelection() {
        var count = 0, selected = 0
        for item in visible where !item.keeper {
            count += 1
            if selection.contains(item.id) { selected += 1 }
        }
        visibleSelectableCount = count
        allVisibleSelected = count > 0 && count == selected
    }

    func setSelection(_ item: Candidate, selected: Bool) {
        guard !busy, !isFiltering, let current = result.filesByID[item.id],
              !current.keeper, current.fingerprint == item.fingerprint else { return }
        if selected { selection.insert(item.id) } else { selection.remove(item.id) }
    }

    func toggleSelection(_ item: Candidate) {
        setSelection(item, selected: !selection.contains(item.id))
    }

    func setVisibleSelection(_ selected: Bool) {
        guard !busy, !isFiltering else { return }
        let ids = Set(visible.lazy.filter { !$0.keeper }.map(\.id))
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    func clearSelection() { if !busy { selection = [] } }
    func cancel() { compressionTask?.cancel() }

    func compressSelection(didCompress: @escaping @MainActor () -> Void) {
        guard !busy, !isFiltering, !chosen.isEmpty else { return }
        let queue = chosen, folders = folders, compressor = compressor
        let operation = UUID()
        compressionGeneration = operation
        busy = true; progress = 0; savedBytes = 0; error = nil; message = nil
        compressionTask = Task {
            var count = 0, skipped = 0, cancelled = false
            var skipMessages: [String] = []
            for (position, item) in queue.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                currentFile = item.url.lastPathComponent
                progress = Double(position) / Double(queue.count)
                let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
                let progressTask = Task {
                    for await fraction in updates {
                        guard compressionGeneration == operation else { return }
                        progress = (Double(position) + max(0, min(1, fraction))) / Double(queue.count)
                    }
                }
                do {
                    let outcome = try await compressor(item, folders, { continuation.yield($0) })
                    continuation.finish(); await progressTask.value
                    count += 1; savedBytes += outcome.savedBytes
                    completed[item.id] = item.fingerprint
                    update(files, folders: folders)
                } catch is CancellationError {
                    continuation.finish(); await progressTask.value
                    cancelled = true; break
                } catch let failure as VideoCompressionError {
                    continuation.finish(); await progressTask.value
                    switch failure {
                    case .unsupported, .notSmaller:
                        skipped += 1
                        if skipMessages.count < 20 {
                            skipMessages.append("\(item.url.lastPathComponent): \(failure.localizedDescription)")
                        }
                    default:
                        error = "\(item.url.lastPathComponent): \(failure.localizedDescription)"
                    }
                    if error != nil { break }
                } catch {
                    continuation.finish(); await progressTask.value
                    self.error = "\(item.url.lastPathComponent): \(error.localizedDescription)"
                    break
                }
                progress = Double(position + 1) / Double(queue.count)
            }
            currentFile = nil; busy = false
            let summary = count > 0
                ? "\(count) \(count == 1 ? "video" : "videos") compressed · \(formatBytes(savedBytes)) smaller. Originals remain in Trash; empty Trash yourself to release space."
                : "No videos were replaced."
            if cancelled { message = "Compression cancelled. \(summary)" }
            else if skipped > 0 {
                let remaining = skipped - skipMessages.count
                let extra = remaining > 0 ? "\n\(remaining) more skipped." : ""
                message = "\(summary) \(skipped) skipped; originals kept.\n\(skipMessages.joined(separator: "\n"))\(extra)"
            }
            else { message = summary }
            if count > 0 { didCompress() }
        }
    }
}

struct VideoView: View {
    @ObservedObject var model: VideoModel
    var scan: () -> Void
    var didCompress: @MainActor @Sendable () -> Void
    var isScanning = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var page = 0
    @State private var preview: URL?
    @State private var review = false
    @State private var acknowledge = false
    @State private var paneSize = CGSize(width: 895, height: 800)
    private let pageSize = 200
    private var theme: ScruffyTheme { ScruffyTheme(scheme: colorScheme) }
    private var compact: Bool { paneSize.width < 720 || paneSize.height < 680 }
    private var inset: CGFloat { compact ? 18 : 28 }
    private var pageCount: Int { max(1, (model.visible.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var pageFiles: ArraySlice<Candidate> { model.visible.dropFirst(currentPage * pageSize).prefix(pageSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(inset)
            summary.padding(.horizontal, inset).padding(.bottom, compact ? 12 : 24)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    selectionControls
                    Spacer(minLength: 4)
                    if compact {
                        Button("Clear selection") { model.clearSelection() }.disabled(model.busy || model.selection.isEmpty)
                    } else { searchControls }
                }
                if compact { searchControls }
            }.padding(.horizontal, inset).padding(.bottom, 12)
            Divider()
            if model.visible.isEmpty {
                ContentUnavailableView(model.isFiltering ? "Searching…" : "No videos to review", systemImage: "film",
                                       description: Text(isScanning ? "Videos appear as your chosen folders are scanned." : "Scan your chosen folders or change your search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pageFiles) { item in videoRow(item) }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                if pageCount > 1 { paging.padding(.horizontal, inset).padding(.vertical, 8) }
            }
            if let message = model.message {
                ScrollView { Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: compact ? 45 : 75).padding(.horizontal, inset).padding(.vertical, 10)
            }
            if let error = model.error {
                ScrollView { Label(error, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: compact ? 55 : 90).padding(.horizontal, inset).padding(.bottom, 10)
            }
            footer
        }
        .background(theme.canvas).foregroundStyle(theme.text)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { paneSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in paneSize = size }
            }
        }
        .quickLookPreview($preview)
        .onChange(of: model.query) { _, _ in page = 0 }
        .sheet(isPresented: $review) { confirmation }
    }

    private var selectionControls: some View {
        HStack(spacing: 10) {
            Toggle("Select all", isOn: Binding(get: { model.allVisibleSelected }, set: model.setVisibleSelection))
                .toggleStyle(.checkbox).fixedSize().disabled(model.busy || model.isFiltering || model.visibleSelectableCount == 0)
                .help("Select every matching video across all pages.")
            Text("\(model.visible.count.formatted()) videos").font(.subheadline.bold()).lineLimit(1)
            if model.isFiltering { ProgressView().controlSize(.small) }
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search videos", text: $model.query).textFieldStyle(.plain)
                .frame(minWidth: 130, maxWidth: compact ? .infinity : 220)
                .help("Each word is matched independently against names and paths. All words must match, in any order.")
            if !compact { Button("Clear selection") { model.clearSelection() }.disabled(model.busy || model.selection.isEmpty) }
        }.padding(.vertical, compact ? 6 : 0)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Videos").font(.system(size: compact ? 23 : 27, weight: .semibold, design: .rounded))
                Text("High-quality compression. Keep each video’s resolution and file format.")
                    .font(compact ? .caption : .subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(isScanning ? "Cancel scan" : "Scan again", action: scan)
                .buttonStyle(BrandButtonStyle()).fixedSize().disabled(model.busy)
        }
    }

    private var summary: some View {
        HStack(spacing: compact ? 14 : 20) {
            Image(systemName: "film.stack").font(.system(size: compact ? 26 : 34, weight: .light)).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.files.count.formatted()) videos · \(formatBytes(model.totalBytes))")
                    .font(.system(size: compact ? 20 : 24, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                Text(compact ? "Verified smaller replacements; originals remain in Trash." : "Only a verified, smaller file replaces the original. Originals stay in Trash and use disk space until you empty it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(compact ? 14 : 22).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border))
    }

    private func videoRow(_ item: Candidate) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Toggle("Select \(item.url.lastPathComponent)", isOn: Binding(get: { model.selection.contains(item.id) }, set: { model.setSelection(item, selected: $0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(model.busy || model.isFiltering || item.keeper)
            Button { model.toggleSelection(item) } label: {
                HStack(spacing: compact ? 8 : 12) {
                    Image(systemName: "film").font(.title2).foregroundStyle(theme.accent).frame(width: 27)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(item.url.deletingLastPathComponent().path)
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 4)
                    Text(formatBytes(item.bytes)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy || model.isFiltering || item.keeper)
            Button { preview = item.url } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Quick Look")
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Reveal in Finder")
        }.listRowBackground(model.selection.contains(item.id) ? theme.accent.opacity(0.12) : theme.card)
    }

    private var paging: some View {
        PaginationControls(count: model.visible.count, page: $page, pageSize: pageSize, noun: "videos")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if model.busy {
                ProgressView(value: model.progress).tint(theme.accent)
                Text(model.currentFile.map { "Compressing \($0)…" } ?? "Finishing compression…").font(.caption).lineLimit(1)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selection.isEmpty ? "Nothing selected" : "\(model.chosen.count.formatted()) videos · \(formatBytes(model.selectedBytes)) selected")
                        .font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.85)
                    Text("High-quality HEVC encoding. Resolution and file type stay the same.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.busy { Button("Cancel compression", role: .cancel) { model.cancel() } }
                else {
                    Button("Review compression…") { acknowledge = false; review = true }
                        .buttonStyle(BrandButtonStyle()).fixedSize().disabled(model.chosen.isEmpty || model.isFiltering)
                }
            }.padding(.bottom, 14)
        }.padding(.horizontal, inset).padding(.top, 10)
    }

    private var confirmation: some View {
      ResponsiveSheet(width: 600, idealHeight: 620, windowSize: paneSize) {
        VStack(alignment: .leading, spacing: 18) {
            Label("Compress selected videos?", systemImage: "film").font(.title2.bold())
            Text("Compress \(model.chosen.count.formatted()) videos (\(formatBytes(model.selectedBytes))) using high-quality HEVC encoding.")
            Text("Each video keeps its current resolution and file format. Scruffy verifies the compressed version and replaces the original only when it is smaller. The original moves to Trash and remains available for recovery. Space is released only when you empty Trash yourself.")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chosen) { Text($0.id).font(.caption).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(150, max(90, paneSize.height * 0.23)))
            Toggle("I understand the original videos will move to Trash and be replaced.", isOn: $acknowledge)
            HStack {
                Button("Go back", role: .cancel) { review = false }
                Spacer()
                Button("Compress videos") { review = false; model.compressSelection(didCompress: didCompress) }
                    .buttonStyle(BrandButtonStyle()).disabled(!acknowledge || model.chosen.isEmpty || model.isFiltering)
            }
        }
      }
    }
}
