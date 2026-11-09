import SwiftUI
import AppKit
import Charts
import QuickLook
import CleanupCore

@main
struct ScruffyApp: App {
    @StateObject private var model: AppModel
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @State private var showAbout = false
    init() {
        SingleInstanceLock.enforce()
        _model = StateObject(wrappedValue: AppModel())
    }
    private var launchSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(width: min(1180, max(480, screen.width - 32)),
                      height: min(800, max(360, screen.height - 64)))
    }
    var body: some Scene {
        WindowGroup("Scruffy") {
            ContentView(model: model, showAbout: $showAbout)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .frame(minWidth: min(720, launchSize.width), minHeight: min(540, launchSize.height))
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
                       let iconURL = Bundle.main.url(forResource: iconName, withExtension: nil),
                       let icon = NSImage(contentsOf: iconURL) {
                        NSApplication.shared.applicationIconImage = icon
                    }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.title == "Scruffy" }),
                       let screen = window.screen?.visibleFrame {
                        var frame = window.frame
                        frame.size.width = min(frame.width, screen.width)
                        frame.size.height = min(frame.height, screen.height)
                        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
                        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
                        if frame != window.frame { window.setFrame(frame, display: true) }
                    }
                }
        }
        .defaultSize(width: launchSize.width, height: launchSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Scruffy") { showAbout = true }
            }
        }
    }
}

// MILL5 website palette: cyan #119BC5, slate #222B30 and charcoal #1B1B1B.
private let brandBlue = ScruffyTheme.cyan

private struct MILL5Logo: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "mill5-logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "mill5-logo", withExtension: "png"),
           let logo = NSImage(contentsOf: url) {
            Image(nsImage: logo).resizable().scaledToFit().accessibilityLabel("MILL5")
        }
    }
}

private struct ScruffyMark: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "scruffy-broom", withExtension: "png")
            ?? Bundle.module.url(forResource: "scruffy-broom", withExtension: "png"),
           let logo = NSImage(contentsOf: url) {
            Image(nsImage: logo).resizable().scaledToFit().accessibilityLabel("Scruffy broom")
        }
    }
}

private struct CandidateFileIcon: View {
    let path: String
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "doc").resizable().scaledToFit() }
        }.frame(width: 27, height: 27)
            .task(id: path) {
                let path = path
                let data = await Task.detached(priority: .utility) {
                    autoreleasepool { () -> Data? in
                        let icon = NSWorkspace.shared.icon(forFile: path)
                        var rect = CGRect(x: 0, y: 0, width: 54, height: 54)
                        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                              let context = CGContext(data: nil, width: 54, height: 54, bitsPerComponent: 8,
                                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                        context.draw(image, in: CGRect(x: 0, y: 0, width: 54, height: 54))
                        guard let thumbnail = context.makeImage() else { return nil }
                        return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
                    }
                }.value
                guard !Task.isCancelled else { return }
                icon = data.flatMap { NSImage(data: $0) }
            }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Binding var showAbout: Bool
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ScruffyTheme { ScruffyTheme(scheme: colorScheme) }
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showConfirmation = false
    @State private var preview: URL?
    @State private var showPurgeable = false
    @State private var showVideos = false
    @State private var resultPage = 0
    @State private var windowSize = CGSize(width: 1180, height: 800)
    private var compact: Bool { windowSize.width - sidebarWidth < 840 || windowSize.height < 680 }
    private var inset: CGFloat { compact ? 18 : 28 }
    private var sidebarWidth: CGFloat { windowSize.width < 760 ? 190 : (windowSize.width < 1020 ? 220 : 285) }
    private let pageSize = 200
    private var pageCount: Int { max(1, (model.visible.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(resultPage, pageCount - 1) }
    private var pageFiles: ArraySlice<Candidate> { model.visible.dropFirst(currentPage * pageSize).prefix(pageSize) }
    @StateObject private var purgeable = PurgeableModel()
    @StateObject private var videos = VideoModel()
    private let palette: [Color] = [brandBlue,
        Color(red: 125 / 255, green: 179 / 255, blue: 196 / 255),
        Color(red: 145 / 255, green: 183 / 255, blue: 196 / 255),
        Color(red: 40 / 255, green: 112 / 255, blue: 142 / 255),
        Color(red: 190 / 255, green: 217 / 255, blue: 226 / 255),
        Color(red: 72 / 255, green: 137 / 255, blue: 158 / 255)]
    var body: some View {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                if showVideos {
                    VideoView(model: videos, scan: {
                        if model.isScanning { model.cancel() } else { model.scan() }
                    }, didCompress: { model.invalidate(); model.scan() }, isScanning: model.isScanning)
                        .disabled(model.isCleaning || purgeable.busy)
                } else if showPurgeable {
                    PurgeableView(model: purgeable).disabled(model.isCleaning)
                } else {
                    header.padding(inset)
                    if model.result != nil {
                        overview.padding(.horizontal, inset).padding(.bottom, compact ? 12 : 22)
                        results
                    } else {
                        ScrollView { welcome.frame(maxWidth: .infinity) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    footer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.canvas)
          }
          .onAppear { windowSize = geometry.size }
          .onChange(of: geometry.size) { _, size in windowSize = size }
        }
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .sheet(isPresented: $showSettings) { settings }
        .sheet(isPresented: $showHistory) { history }
        .sheet(isPresented: $showConfirmation) { confirmation }
        .sheet(isPresented: $showAbout) { about }
        .quickLookPreview($preview)
        .onChange(of: model.activeCategory) { _, _ in resultPage = 0 }
        .onChange(of: model.query) { _, _ in resultPage = 0 }
        .onChange(of: model.result?.id, initial: true) { _, _ in
            videos.update(model.result?.videos ?? [], folders: model.options.folders)
        }
        .alert("Scruffy needs your attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 10) {
                    ScruffyMark().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scruffy").font(.system(size: 25, weight: .bold, design: .rounded))
                        Text("A little less clutter.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 14)
            ScrollView {
              VStack(alignment: .leading, spacing: 3) {
                navRow("Overview", icon: "square.grid.2x2", selected: !showPurgeable && !showVideos && model.activeCategory == nil) {
                    showPurgeable = false; showVideos = false; model.activeCategory = nil
                }
                Text("REVIEW FILES").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary).padding(.top, 22).padding(.bottom, 6)
                ForEach(CleanupCategory.allCases) { category in
                    navRow(category.rawValue, icon: category.symbol, selected: !showPurgeable && (category == .videos ? showVideos : (!showVideos && model.activeCategory == category)),
                           count: model.count(category), bytes: model.result == nil ? nil : model.bytes(category),
                           selectedCount: category == .videos ? videos.chosen.count : (model.selectedCategoryCounts[category] ?? 0),
                           selectedBytes: category == .videos ? videos.selectedBytes : (model.selectedCategoryBytes[category] ?? 0)) {
                        showPurgeable = false; showVideos = category == .videos
                        if category != .videos { model.activeCategory = category }
                    }
                }
                navRow("Purgeable space", icon: "arrow.triangle.2.circlepath", selected: showPurgeable) { showVideos = false; showPurgeable = true }
              }
            }
            VStack(alignment: .leading, spacing: 9) {
                Label("You stay in control", systemImage: "checkmark.shield").font(.subheadline.bold()).foregroundStyle(theme.accent)
                if !compact {
                    Text("Review first. Move to Trash.\nRestore if you change your mind.").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border))
            VStack(alignment: .leading, spacing: 14) {
                Button { showHistory = true } label: { Label("Recovery history", systemImage: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(videos.busy)
                Button { showSettings = true } label: { Label("Scan settings", systemImage: "slider.horizontal.3") }.buttonStyle(.plain).disabled(model.busy || videos.busy)
                Button { showAbout = true } label: { Label("About Scruffy", systemImage: "info.circle") }.buttonStyle(.plain)
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
            }.pickerStyle(.menu).font(.caption)
            Text("LOCAL ONLY  ·  NO UPLOADS").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.tertiary)
        }.padding(compact ? 14 : 22).frame(width: sidebarWidth).background(theme.sidebar)
            .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
    }
    private func navRow(_ title: String, icon: String, selected: Bool, count: Int = 0, bytes: Int64? = nil,
                        selectedCount: Int = 0, selectedBytes: Int64 = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                if compact {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                        if let bytes {
                            Text("\(formatBytes(bytes)) · \(count.formatted()) files")
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                  Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1).layoutPriority(1)
                  Spacer()
                  if let bytes {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatBytes(bytes)).font(.caption.weight(.medium))
                        Text("\(count.formatted()) files").font(.caption2)
                    }.monospacedDigit().foregroundStyle(.secondary).fixedSize()
                  } else if count > 0 {
                    Text(count, format: .number).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                  }
                }
            }
            if bytes != nil {
                selectedCategoryLabel(count: selectedCount, bytes: selectedBytes).padding(.leading, 28)
            }
            }.padding(.horizontal, compact ? 8 : 12).padding(.vertical, bytes == nil ? 9 : 6)
                .foregroundStyle(selected ? theme.accent : theme.text.opacity(0.85))
                .background(selected ? brandBlue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(purgeable.busy || videos.busy)
    }
    private func selectedCategoryLabel(count: Int, bytes: Int64) -> some View {
        Label("\(count.formatted()) selected · \(formatBytes(bytes))", systemImage: count > 0 ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 9)).monospacedDigit().lineLimit(1)
            .foregroundStyle(count > 0 ? theme.accent : theme.text.opacity(0.5))
    }
    private var header: some View {
        Group {
          if compact {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(model.activeCategory?.rawValue ?? "Make room for what matters.")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                    Spacer(minLength: 12)
                    scanButton
                }
                Text(model.activeCategory?.explanation ?? "Find the clutter. Keep the good stuff.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          } else {
            HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.activeCategory?.rawValue ?? "Make room for what matters.").font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(model.activeCategory?.explanation ?? "Find the clutter. Keep the good stuff.").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
                scanButton
            }
          }
        }
    }
    private var scanButton: some View {
        Button(model.isScanning ? "Cancel scan" : (model.hasScanned ? "Scan again" : "Scan my Mac")) {
                if model.isScanning { model.cancel() } else { model.scan() }
            }.buttonStyle(BrandButtonStyle()).controlSize(.large)
                .disabled(model.isCleaning || videos.busy)
    }
    private var welcome: some View {
        VStack(spacing: compact ? 14 : 22) {
            ZStack {
                Circle().stroke(brandBlue.opacity(0.07), lineWidth: compact ? 24 : 36).frame(width: compact ? 130 : 205, height: compact ? 130 : 205)
                Circle().trim(from: 0, to: 0.74).stroke(brandBlue.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: compact ? 130 : 205, height: compact ? 130 : 205).rotationEffect(.degrees(-90))
                ScruffyMark().frame(width: compact ? 90 : 138, height: compact ? 90 : 138)
            }
            Text(model.busy ? "Giving your Mac a once-over…" : "A clean Mac starts with a clear picture.").font(.system(size: compact ? 18 : 22, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
            Text("Scruffy finds old downloads, exact duplicates and browser caches.\nYou decide what goes. Your first scan won’t change a thing.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if model.busy { ProgressView().controlSize(.small).tint(theme.accent) }
            else {
                HStack(spacing: 25) {
                    Label("Nothing auto-selected", systemImage: "checkmark.circle")
                    Label("Originals protected", systemImage: "lock.shield")
                }.font(.caption).foregroundStyle(theme.accent)
                Button("Choose folders & scan options") { showSettings = true }.buttonStyle(.link).tint(theme.accent)
            }
        }.padding(compact ? 18 : 30)
    }
    private var overview: some View {
        HStack(spacing: compact ? 14 : 26) {
            spaceChart
            VStack(alignment: .leading, spacing: 5) {
                Text("SPACE TO REVIEW").font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                Text(formatBytes(model.summaryBytes)).font(.system(size: compact ? 27 : 38, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Label("\(model.summarySelectedCount.formatted()) files · \(formatBytes(model.summarySelectedBytes)) selected", systemImage: model.summarySelectedCount > 0 ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(model.summarySelectedCount > 0 ? theme.accent : theme.text.opacity(0.5))
                Text(compact ? "Logical sizes; actual disk savings can differ." : "Logical file sizes, not guaranteed disk savings.\nAPFS clones and compression can affect actual space.")
                    .font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if compact {
                Menu {
                    ForEach(model.summaryCategories) { category in
                        Button("\(category.rawValue) · \(formatBytes(model.bytes(category)))") { model.activeCategory = category }
                    }
                } label: { Image(systemName: "chart.pie").font(.title3).accessibilityLabel("Category sizes") }
                .menuStyle(.borderlessButton).fixedSize()
            } else { overviewLegend }
        }.padding(compact ? 14 : 24).background(theme.card, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(theme.border))
    }
    private var spaceChart: some View {
        Chart {
            ForEach(Array(CleanupCategory.allCases.filter { $0 != .videos }.enumerated()), id: \.element.id) { index, category in
                if model.summaryCategories.contains(category) {
                    SectorMark(angle: .value("Bytes", model.bytes(category)), innerRadius: .ratio(0.77), angularInset: 3)
                        .cornerRadius(3).foregroundStyle(palette[index])
                }
            }
        }.frame(width: compact ? 64 : 135, height: compact ? 64 : 135).chartLegend(.hidden)
            .overlay { Image(systemName: "internaldrive").font(.system(size: compact ? 20 : 28, weight: .light)).foregroundStyle(theme.accent) }
            .accessibilityLabel("Candidate files by category")
    }
    private var overviewLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(CleanupCategory.allCases.filter { $0 != .videos }.enumerated()), id: \.element.id) { index, category in
                if model.summaryCategories.contains(category) {
                    Button { model.activeCategory = category } label: {
                        HStack {
                            Circle().fill(palette[index]).frame(width: 6, height: 6)
                            Text(category.rawValue)
                            Spacer()
                            Text(formatBytes(model.bytes(category))).monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
        }.frame(width: 200)
    }
    private var results: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    selectionControls
                    Spacer(minLength: 4)
                    if compact {
                        Button("Clear selection") { model.selection = [] }.disabled(model.selection.isEmpty || model.isCleaning)
                    } else { searchControls }
                }
                if compact { searchControls }
            }.padding(.horizontal, inset).padding(.bottom, 12)
            Divider()
            if model.visible.isEmpty {
                ContentUnavailableView(model.isFiltering ? "Searching…" : (model.isScanning ? "Looking for more files" : "Nothing to review here"),
                                       systemImage: model.isFiltering ? "magnifyingglass" : "checkmark.seal",
                                       description: Text(model.isFiltering ? "Matching names and paths in this section." : (model.isScanning ? "More verified results will appear as scanning continues." : "Try another category or adjust your scan settings.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pageFiles) { item in
                    HStack(spacing: compact ? 8 : 12) {
                        Toggle("Select \(item.url.lastPathComponent)", isOn: Binding(get: { model.selection.contains(item.id) }, set: { selected in
                            model.setSelection(item, selected: selected)
                        })).labelsHidden().toggleStyle(.checkbox).disabled(item.keeper || model.isCleaning || model.isFiltering)
                        Button { model.toggleSelection(item) } label: {
                            HStack(spacing: compact ? 8 : 12) {
                                CandidateFileIcon(path: item.id)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        if item.keeper { Text("KEEP ORIGINAL").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.accent).padding(4).background(brandBlue.opacity(0.1), in: Capsule()) }
                                        else if model.activeCategory == nil && !compact { Text(item.category.rawValue).font(.caption2).foregroundStyle(.tertiary) }
                                    }
                                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    if let hash = item.duplicateHash {
                                        Text("Match \(hash.prefix(8)) · \(model.result?.duplicateCounts[hash] ?? 0) identical copies")
                                            .font(.system(size: 9)).foregroundStyle(theme.accent)
                                    }
                                }.frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 4)
                                Text(formatBytes(item.bytes)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(item.keeper || model.isCleaning || model.isFiltering)
                        Button { preview = item.url } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Quick Look")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Reveal in Finder")
                    }.listRowBackground(model.selection.contains(item.id) ? theme.accent.opacity(0.12) : theme.card).contextMenu {
                        Button("Preview") { preview = item.url }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        if let hash = item.duplicateHash, let keeper = model.result?.keepersByHash[hash] {
                            Button("Reveal protected original") { NSWorkspace.shared.activateFileViewerSelecting([keeper.url]) }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                if pageCount > 1 {
                    PaginationControls(count: model.visible.count, page: $resultPage, pageSize: pageSize, noun: "files")
                        .padding(.horizontal, inset).padding(.vertical, 8)
                }
            }
            if let notes = model.result?.notes, !notes.isEmpty {
                DisclosureGroup("\(notes.count) locations or files could not be scanned") {
                    ScrollView { Text(notes.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 85)
                }.font(.caption).padding(.horizontal, inset).padding(.vertical, 8)
            }
        }
    }
    private var selectionControls: some View {
        HStack(spacing: 10) {
            Toggle("Select all", isOn: Binding(get: { model.allVisibleSelected }, set: { model.setVisibleSelection($0) }))
                .toggleStyle(.checkbox).fixedSize()
                .disabled(model.isCleaning || model.isFiltering || model.visibleSelectableCount == 0)
                .help("Select all matching files across every page. Protected originals remain unselected.")
            Text("\(model.visible.count.formatted()) files").font(.subheadline.bold()).lineLimit(1)
            if model.isFiltering || model.isScanning {
                ProgressView().controlSize(.small)
                if !compact { Text(model.isFiltering ? "Searching…" : "Scanning continues").font(.caption).foregroundStyle(theme.accent) }
            }
        }
    }
    private var searchControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(model.activeCategory?.rawValue.lowercased() ?? "all files")", text: $model.query)
                .textFieldStyle(.plain).frame(minWidth: 130, maxWidth: compact ? .infinity : 220)
                .help("Search names and paths. Each word is matched independently; all words must match, in any order.")
            if !compact { Button("Clear selection") { model.selection = [] }.disabled(model.selection.isEmpty || model.isCleaning) }
        }.padding(.vertical, compact ? 6 : 0)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selection.isEmpty ? "Nothing selected" : "\(model.selection.count.formatted()) files · \(formatBytes(model.selectedBytes)) selected")
                        .font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.85)
                    if model.hasSelectionOutsideCategory {
                        Text("Includes files selected in other categories.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 2 : 3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { model.refreshRunningBrowsers(); showConfirmation = true } label: { Label("Review cleanup", systemImage: "trash") }
                    .buttonStyle(BrandButtonStyle()).controlSize(.large).fixedSize()
                    .disabled(model.selection.isEmpty || model.isCleaning)
            }.padding(.horizontal, inset).padding(.vertical, compact ? 12 : 20)
        }
    }
    private var settings: some View {
      ResponsiveSheet(width: 570, idealHeight: 700, windowSize: windowSize) {
        VStack(alignment: .leading, spacing: 20) {
            Text("Give Scruffy a place to look.").font(.title2.bold())
            Text("Only local files inside your home folder. Protected and known cloud-sync locations are skipped.").font(.subheadline).foregroundStyle(.secondary)
            GroupBox("Personal folders") {
                VStack(alignment: .leading) {
                    ForEach(model.options.folders, id: \.path) { folder in
                        HStack {
                            Label(folder.path.replacingOccurrences(of: model.scanner.home.path, with: "~"), systemImage: "folder").lineLimit(1)
                            Spacer()
                            Button { model.options.folders.removeAll { $0 == folder }; model.invalidate() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }.padding(4)
                    }
                    Button("Add folder…") { model.addFolder() }.padding(.top, 6)
                }.padding(8)
            }
            Toggle("Find exact duplicates", isOn: $model.options.duplicates)
            Toggle("Review Downloads untouched for 30 days", isOn: $model.options.downloads)
            Toggle("Review large files (500 MB or larger)", isOn: $model.options.large)
            Toggle("Find videos for high-quality compression", isOn: $model.options.videos)
            Toggle("Browser caches (older than one day)", isOn: $model.options.browsers)
            Toggle("Developer caches (pip, uv, npm; older than seven days)", isOn: $model.options.caches)
            Toggle("User temporary files (older than seven days)", isOn: $model.options.temporary)
            Text("Close browsers before cleaning their caches. Close package managers and other active apps before cleaning developer caches or temporary files. Downloads and large files may be important—review every selection.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { model.invalidate(); showSettings = false }.buttonStyle(BrandButtonStyle()) }
        }
      }
    }
    private var confirmation: some View {
      ResponsiveSheet(width: 600, idealHeight: 640, windowSize: windowSize) {
        VStack(alignment: .leading, spacing: 18) {
            Label("One last look.", systemImage: "trash").font(.title2.bold())
            Text("Move \(model.chosen.count) files (\(formatBytes(model.selectedBytes))) to Trash?")
            Text("Nothing will be permanently deleted. Files in Downloads and large-file results may contain personal data. Confirm that you no longer need each selected item.").font(.subheadline).foregroundStyle(.secondary)
            if model.chosen.contains(where: { $0.category == .browsers }) {
                GroupBox("Browser caches") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Only cached web resources such as JavaScript and images are removed. Saved passwords, cookies, bookmarks and browsing history stay untouched.")
                        if !model.runningBrowserNames.isEmpty {
                            Text("Quit these browsers before cleanup: \(model.runningBrowserNames.joined(separator: ", ")).").fontWeight(.medium)
                            Button("Quit browsers") { model.requestBrowserQuit() }
                            Text("You can also quit them yourself. Cleanup stays paused until they close.").foregroundStyle(.secondary)
                        } else {
                            Label("No browsers are running. Ready for cleanup.", systemImage: "checkmark.circle")
                                .foregroundStyle(theme.accent)
                        }
                        if let message = model.browserQuitMessage { Text(message).foregroundStyle(.secondary) }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chosen) { item in Text(item.url.path).font(.caption).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(180, max(90, windowSize.height * 0.23)))
            Text("Disk space is not released until you empty Trash yourself. Scruffy never empties it.").font(.caption).foregroundStyle(theme.accent)
            HStack { Button("Go back", role: .cancel) { showConfirmation = false }; Spacer(); Button("Move to Trash") { showConfirmation = false; model.clean() }.buttonStyle(BrandButtonStyle()).disabled(model.browserCleanupBlocked) }
        }
      }
            .task {
                model.refreshRunningBrowsers()
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        model.refreshRunningBrowsers()
                    }
                } catch { }
            }
    }
    private var about: some View {
      ResponsiveSheet(width: 410, idealHeight: 520, windowSize: windowSize) {
        VStack(spacing: 18) {
            ScruffyMark().frame(width: 100, height: 100)
            Text("Scruffy").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("A little less clutter.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .font(.caption).foregroundStyle(.secondary)
            Divider().overlay(theme.border)
            Text("Built by").font(.caption).foregroundStyle(.secondary)
            MILL5Logo().frame(width: 166, height: 38).padding(20)
                .background(Color(red: 34 / 255, green: 43 / 255, blue: 48 / 255), in: RoundedRectangle(cornerRadius: 12))
            Text("Local scanning. Reviewed cleanup. Your files stay yours.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { showAbout = false }.buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
        }.frame(maxWidth: .infinity)
      }
    }
    private var history: some View {
      ResponsiveSheet(width: 690, idealHeight: 560, windowSize: windowSize) {
        VStack(alignment: .leading, spacing: 16) {
            Text("A way back.").font(.title2.bold())
            Text("Restore files that Scruffy moved to Trash. Existing files are never replaced. If you emptied Trash, those files cannot be recovered here.").font(.subheadline).foregroundStyle(.secondary)
            if model.isLoadingHistory && model.history.isEmpty {
                ProgressView("Loading recovery history…").frame(maxWidth: .infinity).frame(height: 180)
            } else if model.history.isEmpty {
                ContentUnavailableView("No cleanup history yet", systemImage: "arrow.uturn.backward").frame(height: 180)
            } else {
                List(model.history) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.original.lastPathComponent).font(.subheadline.bold())
                            Text(record.original.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(record.date.formatted()).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Restore") { model.restore(record) }.disabled(model.busy || videos.busy || record.trashed == nil || !FileManager.default.fileExists(atPath: record.trashed!.path))
                    }.padding(.vertical, 5)
                }.frame(height: min(320, max(150, windowSize.height * 0.38)))
            }
            HStack {
                Button("Open Trash in Finder") { NSWorkspace.shared.open(model.scanner.home.appendingPathComponent(".Trash")) }
                Spacer(); Button("Done") { showHistory = false }.keyboardShortcut(.defaultAction)
            }
        }
      }
    }
}
