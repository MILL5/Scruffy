import Foundation
import CryptoKit
import Darwin

public enum CleanupCategory: String, CaseIterable, Sendable, Identifiable {
    case duplicates = "Duplicates"
    case downloads = "Old downloads"
    case browsers = "Browser caches"
    case caches = "Developer caches"
    case temporary = "Temporary files"
    case large = "Large files"
    case videos = "Videos"
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .duplicates: "square.on.square"
        case .downloads: "arrow.down.circle"
        case .browsers: "globe"
        case .caches: "shippingbox"
        case .temporary: "clock.arrow.circlepath"
        case .large: "internaldrive"
        case .videos: "film"
        }
    }
    public var explanation: String {
        switch self {
        case .duplicates: "Identical contents, verified with SHA-256. One original is kept unless you choose every copy. Click a checkbox again to add the next copy; Control-click chooses them all."
        case .downloads: "Files untouched for at least 30 days. Age does not mean unwanted: review each file before selecting it."
        case .browsers: "Downloaded web resources such as JavaScript and images only. Saved passwords, cookies, bookmarks and browsing history stay untouched. Any running browsers must close before cleanup."
        case .caches: "pip, uv and npm download caches. Recreated as needed; future installs may require a download. Quit package managers first."
        case .temporary: "Regular files untouched for at least seven days in your user temporary folder. Quit active apps and review before selecting."
        case .large: "Files of 500 MB or more in your chosen folders. These may be valuable personal files; nothing is selected automatically."
        case .videos: "Compress videos at high quality while preserving their resolution and file format. Verified smaller replacements keep the originals in Trash."
        }
    }
}

public struct Fingerprint: Sendable, Equatable, Codable {
    public let size: Int64
    public let modified: Date
    public let device: UInt64
    public let inode: UInt64
    public let links: UInt64

    public static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { throw SafetyError.unsafe(url.path) }
        return .init(size: Int64(info.st_size),
                     modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                     device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino), links: UInt64(info.st_nlink))
    }
}

public struct Candidate: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public var category: CleanupCategory
    public let fingerprint: Fingerprint
    public var duplicateHash: String?
    public var keeper: Bool = false
    public var bytes: Int64 { fingerprint.size }
    public static func largestFirst(_ left: Candidate, _ right: Candidate) -> Bool {
        left.bytes == right.bytes ? left.id < right.id : left.bytes > right.bytes
    }
    public init(url: URL, category: CleanupCategory, fingerprint: Fingerprint,
                duplicateHash: String? = nil, keeper: Bool = false) {
        self.id = url.path; self.url = url; self.category = category
        self.fingerprint = fingerprint; self.duplicateHash = duplicateHash; self.keeper = keeper
    }
}

public struct ScanOptions: Sendable {
    public var folders: [URL]
    public var downloads = true
    public var duplicates = true
    public var browsers = true
    public var caches = true
    public var temporary = true
    public var large = true
    public var videos = true
    public init(folders: [URL]) { self.folders = folders }
}

public struct ScanResult: Sendable {
    public let id = UUID()
    public let files: [Candidate]
    public let filesBySize: [Candidate]
    public let notes: [String]
    public let videos: [Candidate]
    public let videoBytes: Int64
    public let filesByID: [String: Candidate]
    public let categoryCounts: [CleanupCategory: Int]
    public let categoryBytes: [CleanupCategory: Int64]
    public let candidateBytes: Int64
    public let duplicateCounts: [String: Int]
    public let keepersByHash: [String: Candidate]
    /// Every file of a category, largest first, including protected originals.
    public let filesByCategory: [CleanupCategory: [Candidate]]
    /// Set only on the result a completed scan returns.
    public internal(set) var timings: PhaseTimings?
    /// Locations macOS refused to list. Full Disk Access is what allows the protected ones.
    public var permissionDeniedCount: Int { notes.count { $0.hasPrefix(CleanupScanner.permissionNotePrefix) } }
    public init(files: [Candidate], notes: [String], videos: [Candidate] = []) {
        self.files = files; self.notes = notes
        var alreadySorted = true
        for index in files.indices.dropFirst() {
            if Candidate.largestFirst(files[index], files[index - 1]) { alreadySorted = false; break }
        }
        filesBySize = alreadySorted ? files : files.sorted(by: Candidate.largestFirst)
        self.videos = videos.sorted(by: Candidate.largestFirst)
        videoBytes = videos.reduce(0) { $0 + $1.bytes }
        var index: [String: Candidate] = [:], keepers: [String: Candidate] = [:]
        var counts: [CleanupCategory: Int] = [:], sizes: [CleanupCategory: Int64] = [:]
        var duplicates: [String: Int] = [:]
        var total: Int64 = 0
        var sections: [CleanupCategory: [Candidate]] = [:]
        for item in filesBySize {
            index[item.id] = item
            sections[item.category, default: []].append(item)
            if !item.keeper {
                counts[item.category, default: 0] += 1
                sizes[item.category, default: 0] += item.bytes
                total += item.bytes
            }
            if let hash = item.duplicateHash {
                duplicates[hash, default: 0] += 1
                if item.keeper { keepers[hash] = item }
            }
        }
        filesByID = index; categoryCounts = counts; categoryBytes = sizes
        candidateBytes = total; duplicateCounts = duplicates; keepersByHash = keepers
        filesByCategory = sections
    }
}

/// What a running scan is waiting on, readable from another thread. The scan cannot report this
/// itself: its progress callback runs on the thread that is waiting. macOS holds a folder listing
/// open-ended while it asks the user for permission to read that folder.
public final class ScanActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var folder: String?
    private var since = ContinuousClock.now
    public init() {}
    func willList(_ path: String) { lock.withLock { folder = path; since = .now } }
    func didList() { lock.withLock { folder = nil } }
    /// The folder macOS has been asked to list for at least `duration` without answering, if any.
    public func waiting(atLeast duration: Duration) -> String? {
        lock.withLock { folder.flatMap { since.duration(to: .now) >= duration ? $0 : nil } }
    }
}

public enum SafetyError: LocalizedError {
    case unsafe(String), changed(String), keeper, browserRunning, cancelled
    public var errorDescription: String? {
        switch self {
        case .unsafe(let path): "Protected or unsupported file: \(path)"
        case .changed(let path): "File changed since the scan. Scan again: \(path)"
        case .keeper: "At least one unchanged original must remain in every duplicate group."
        case .browserRunning: "Quit Safari, Chrome, Firefox, Edge, Brave and Arc before cleaning browser caches."
        case .cancelled: "Scan cancelled."
        }
    }
}

public struct CleanupScanner: Sendable {
    public let home: URL
    public let temp: URL
    /// Smallest size listed under Large files. Decimal, like the sizes the app displays.
    public static let largeFileBytes: Int64 = 500_000_000
    /// Starts the scan note for a location macOS refused to list.
    public static let permissionNotePrefix = "No permission to read: "
    // Path strings prepared once: the safety check runs for every file a scan meets.
    private let homePath: String
    private let tempPath: String
    private let homePrefix: String
    private let tempPrefix: String
    private let homeDepth: Int
    private let tempDepth: Int
    private let libraryKey: String
    private let downloadsPrefix: String
    private let forbiddenPaths: [(path: String, prefix: String)]
    private let cacheRoots: [URL]
    private let browserRoots: [URL]
    private let profileRoots: [URL]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                temp: URL = FileManager.default.temporaryDirectory) {
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = home
        self.temp = temp.resolvingSymlinksInPath().standardizedFileURL
        let homePath = home.path
        self.homePath = homePath
        tempPath = self.temp.path
        homePrefix = homePath + "/"
        tempPrefix = tempPath + "/"
        homeDepth = Self.depth(homePath)
        tempDepth = Self.depth(tempPath)
        libraryKey = Self.locationKey(homePath + "/Library/")
        downloadsPrefix = homePath + "/Downloads/"
        forbiddenPaths = [".Trash", "Library/CloudStorage", "Library/Mobile Documents", "Library/Mail",
                          "Library/Messages", "Library/Keychains", "Library/Photos", "Library/Containers",
                          "Library/Group Containers", "Library/Developer", ".ssh", ".gnupg"].map {
            (path: Self.locationKey(homePath + "/" + $0), prefix: Self.locationKey(homePath + "/" + $0 + "/"))
        }
        cacheRoots = ["Library/Caches/pip", "Library/Caches/uv", ".npm/_cacache"].map { home.appendingPathComponent($0) }
        browserRoots = ["Library/Caches/com.apple.Safari", "Library/Caches/Google/Chrome",
                        "Library/Caches/Microsoft Edge", "Library/Caches/BraveSoftware", "Library/Caches/company.thebrowser.Browser"].map { home.appendingPathComponent($0) }
        profileRoots = ["Library/Application Support/Google/Chrome", "Library/Application Support/Microsoft Edge",
                        "Library/Application Support/BraveSoftware/Brave-Browser", "Library/Application Support/Arc/User Data"].map { home.appendingPathComponent($0) }
    }
    public func isWithin(_ url: URL, _ parent: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = parent.standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }
    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }
    private struct SafetyCache {
        /// Folders already inspected, with the identity each had at that time.
        var ancestors: [String: DirectoryIdentity] = [:]
        /// Device of the home or temporary folder, once its volume is known to be local.
        var rootDevices: [String: UInt64] = [:]
    }
    /// Files whose contents are not on this Mac: reading one would start a download.
    static func isCloudPlaceholder(flags: UInt32) -> Bool { flags & UInt32(SF_DATALESS) != 0 }
    private static let forbiddenNames: Set<String> = [".git", "node_modules", ".build", ".venv", "venv"]
    static func isForbiddenName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return forbiddenNames.contains(lower)
            || lower.contains("dropbox") || lower.contains("onedrive")
            || lower.contains("google drive") || lower.contains("googledrive")
            || lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".photolibrary")
            || lower.hasSuffix(".app") || lower.hasSuffix(".bundle") || lower.hasSuffix(".backupdb")
    }
    /// Files a browser is still writing, or left behind by an interrupted download.
    /// Chromium uses .crdownload, Firefox .part, Safari a .download package, Edge legacy .partial.
    public static func isPendingDownload(_ url: URL) -> Bool {
        url.pathComponents.contains {
            let lower = $0.lowercased()
            return lower.hasSuffix(".crdownload") || lower.hasSuffix(".part")
                || lower.hasSuffix(".download") || lower.hasSuffix(".partial")
        }
    }
    // Exclusions compare bytes, not characters. Swift's `hasPrefix` and `lastIndex(of:)` work on whole
    // characters, and a slash next to a combining mark is one character: the folder boundary there
    // would go unseen and the folder would escape its checks.
    /// One Unicode form for comparing locations. APFS treats both forms of a name as the same file.
    private static func locationKey(_ path: String) -> String {
        path.utf8.allSatisfy { $0 < 0x80 } ? path : path.decomposedStringWithCanonicalMapping
    }
    /// Number of folder levels: the home or temporary folder and everything in it sit at or below its depth.
    private static func depth(_ path: String) -> Int { path.utf8.count { $0 == UInt8(ascii: "/") } }
    private func inLibrary(_ path: String) -> Bool { Self.locationKey(path).utf8.starts(with: libraryKey.utf8) }
    /// True for anything inside the home folder's Library.
    public func isInLibrary(_ url: URL) -> Bool { inLibrary(url.standardizedFileURL.path) }
    public func allowed(_ url: URL) -> Bool {
        var cache = SafetyCache()
        return allowed(url, cache: &cache)
    }
    // Only scanning shares this cache. Cleanup and content reads always start with
    // an empty cache so an ancestor replaced since inventory is rejected.
    private func allowed(_ url: URL, cache: inout SafetyCache) -> Bool {
        let item = url.standardizedFileURL
        let path = item.path
        let root: String, rootDepth: Int
        if path.hasPrefix(homePrefix) { root = homePath; rootDepth = homeDepth }
        else if path.hasPrefix(tempPrefix) { root = tempPath; rootDepth = tempDepth }
        else { return false }
        // Only the volume holding the home or temporary folder is eligible. A disk image,
        // external disk or network share mounted inside it is a different device.
        let rootDevice: UInt64
        if let known = cache.rootDevices[root] { rootDevice = known }
        else {
            var info = stat()
            guard lstat(root, &info) == 0,
                  let volume = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeIsLocalKey]),
                  volume.volumeIsLocal == true else { return false }
            rootDevice = UInt64(truncatingIfNeeded: info.st_dev)
            cache.rootDevices[root] = rootDevice
        }
        let key = Self.locationKey(path)
        for forbidden in forbiddenPaths where key == forbidden.path || key.utf8.starts(with: forbidden.prefix.utf8) { return false }
        // Inspect every ancestor as well as the file; never follow a symlink into another tree.
        var cursor = path
        var depth = Self.depth(path)
        var checked: [(String, DirectoryIdentity)] = []
        while cursor != "/" {
            var info = stat()
            let exists = lstat(cursor, &info) == 0
            let kind = info.st_mode & S_IFMT
            let identity = DirectoryIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
            if cursor != path, exists, kind == S_IFDIR, cache.ancestors[cursor] == identity { break }
            // Foundation canonicalizes /private/var back to macOS's root-owned /var alias.
            // Permit only that exact OS alias, never a user-created symlink.
            if cursor == "/var",
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var"),
               target == "private/var" || target == "/private/var" { break }
            let bytes = cursor.utf8
            let slash = bytes.lastIndex(of: UInt8(ascii: "/")) ?? bytes.startIndex
            let name = String(decoding: bytes[bytes.index(after: slash)...], as: UTF8.self)
            guard exists, kind != S_IFLNK, !Self.isForbiddenName(name) else { return false }
            if depth >= rootDepth {
                guard identity.device == rootDevice, !Self.isCloudPlaceholder(flags: info.st_flags) else { return false }
            }
            let location = cursor == path ? item : URL(fileURLWithPath: cursor)
            guard let values = try? location.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isUbiquitousItemKey]),
                  values.isSymbolicLink != true, values.isAliasFile != true,
                  values.isUbiquitousItem != true else { return false }
            if cursor != path, kind == S_IFDIR { checked.append((cursor, identity)) }
            cursor = slash == bytes.startIndex ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
            depth -= 1
        }
        for (ancestor, identity) in checked { cache.ancestors[ancestor] = identity }
        return true
    }
    /// macOS privacy protection and ordinary file permissions both report a read as not permitted.
    static func isPermissionDenial(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        return posix?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(posix?.code ?? 0)
    }
    private func browserAllowed(_ url: URL) -> Bool {
        if browserRoots.contains(where: { isWithin(url, $0) }) { return true }
        for root in profileRoots where isWithin(url, root) {
            let parts = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/")
            if parts.count >= 3, (parts[0] == "Default" || parts[0].hasPrefix("Profile ")),
               ["Cache", "Code Cache", "GPUCache"].contains(String(parts[1])) { return true }
        }
        let firefox = home.appendingPathComponent("Library/Caches/Firefox/Profiles")
        if isWithin(url, firefox) {
            let parts = String(url.path.dropFirst(firefox.path.count + 1)).split(separator: "/")
            return parts.count >= 3 && parts[1] == "cache2"
        }
        return false
    }
    public func validateLocation(_ item: Candidate, folders: [URL]) throws {
        guard allowed(item.url), item.fingerprint.links == 1 else { throw SafetyError.unsafe(item.url.path) }
        let valid: Bool
        switch item.category {
        case .browsers: valid = browserAllowed(item.url)
        case .caches: valid = cacheRoots.contains { isWithin(item.url, $0) }
        case .temporary: valid = isWithin(item.url, temp)
        case .downloads, .duplicates, .large, .videos:
            valid = folders.contains { isWithin(item.url, $0) } && !isInLibrary(item.url)
        }
        guard valid else { throw SafetyError.unsafe(item.url.path) }
        guard try Fingerprint.read(item.url) == item.fingerprint else { throw SafetyError.changed(item.url.path) }
    }
    public func digest(_ url: URL) throws -> String {
        try hashContents(url, sample: false)
    }
    private func hashContents(_ url: URL, sample: Bool) throws -> String {
        guard allowed(url) else { throw SafetyError.unsafe(url.path) }
        // Resource forks can contain additional document data. Exclude these files from
        // duplicate detection instead of treating a matching data fork as a full copy.
        let resourceLength = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        guard resourceLength == 0 || (resourceLength == -1 && errno == ENOATTR) else {
            throw SafetyError.unsafe(url.path)
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SafetyError.unsafe(url.path) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256()
        if sample {
            // At most 128 KiB per candidate eliminates most same-size files before
            // any full read, without relying on sample matches as proof of equality.
            hash.update(data: try file.read(upToCount: 65_536) ?? Data())
            let size = try file.seekToEnd()
            if size > 65_536 {
                try file.seek(toOffset: max(65_536, size - 65_536))
                hash.update(data: try file.read(upToCount: 65_536) ?? Data())
            }
            try Task.checkCancellation()
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Progressive updates follow sidebar order and contain only ready-to-review files.
    /// Personal folders are enumerated once; later categories wait for their turn.
    /// The callback runs serially on the caller.
    public func scan(_ options: ScanOptions, activity: ScanActivity? = nil,
                     progress: (@Sendable (ScanResult, String) -> Void)? = nil) throws -> ScanResult {
        var items: [String: Candidate] = [:]
        var personalReady: [String: Candidate] = [:]
        var pendingVideos: [String: Candidate] = [:]
        var ready: [String: Candidate] = [:]
        var videoReady: [String: Candidate] = [:]
        var notes = Set<String>()
        var safetyCache = SafetyCache()
        var visited = Set<String>()
        var enumerated = 0
        var personalScanned = false
        var personalPhase = "Finding personal files"
        var personalCategory: CleanupCategory?
        var lastPublish = Date.distantPast
        var cachedSnapshot: ScanResult?
        var snapshotFileCount = -1, snapshotNoteCount = -1
        var snapshotVideoCount = -1
        let fm = FileManager.default
        let now = Date()
        let clock = ContinuousClock()
        let scanStart = clock.now
        var timings = PhaseTimings()
        var pendingDownloads = 0
        defer {
            if timings["Whole scan"] == nil { timings.add("Scan stopped early after", since: scanStart) }
            PhaseTimings.log.notice("Scan timings\n\(timings.summary, privacy: .public)")
        }
        func snapshot() -> ScanResult {
            // Ready candidates never change after publication. Status-only updates
            // can share the same sorted files and indexes instead of rebuilding them.
            if ready.count == snapshotFileCount, notes.count == snapshotNoteCount, videoReady.count == snapshotVideoCount,
               let cachedSnapshot { return cachedSnapshot }
            let started = clock.now
            defer { timings.add("Sort and index results for display", since: started) }
            let result = ScanResult(files: ready.values.sorted {
                $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
            }, notes: notes.sorted(), videos: Array(videoReady.values))
            cachedSnapshot = result
            snapshotFileCount = ready.count; snapshotNoteCount = notes.count
            snapshotVideoCount = videoReady.count
            return result
        }
        func publish(_ phase: String, force: Bool = false) {
            guard let progress else { return }
            let instant = Date()
            guard force || instant.timeIntervalSince(lastPublish) >= 1 else { return }
            lastPublish = instant
            progress(snapshot(), "\(phase) · \(enumerated) files checked · \(ready.count) ready to review")
        }
        func walk(_ root: URL, category: CleanupCategory?, age: TimeInterval = 0) throws {
            guard fm.fileExists(atPath: root.path) else { return }
            guard allowed(root, cache: &safetyCache) || root == home || (category == .temporary && root == temp) else {
                notes.insert("Skipped protected location: \(root.path)"); return
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentAccessDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                notes.insert((Self.isPermissionDenial(error) ? Self.permissionNotePrefix : "Could not read: ") + url.path); return true
            }) else { notes.insert("Could not open: \(root.path)"); return }
            // The enumerator opens the folder it returned last. That call does not return while macOS
            // waits for the user to answer a permission prompt for it.
            var listing = root.path
            while true {
                activity?.willList(listing)
                let next = enumerator.nextObject()
                activity?.didList()
                guard let discovered = next as? URL else { break }
                let url = discovered.standardizedFileURL
                try Task.checkCancellation()
                let safetyStart = clock.now
                let permitted = allowed(url, cache: &safetyCache)
                timings.add("Walk: safety check", since: safetyStart)
                guard permitted else { enumerator.skipDescendants(); continue }
                if category == nil && inLibrary(url.path) {
                    enumerator.skipDescendants(); continue
                }
                guard visited.insert(url.path).inserted else { enumerator.skipDescendants(); continue }
                let metadataStart = clock.now
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .contentAccessDateKey])
                let fingerprint = values?.isRegularFile == true && values?.isPackage != true ? try? Fingerprint.read(url) : nil
                timings.add("Walk: file metadata", since: metadataStart)
                if values?.isRegularFile == false { listing = url.path }
                guard let values, let fingerprint, fingerprint.links == 1, fingerprint.size > 0 else { continue }
                // An unfinished download is never offered for cleanup, whatever its size or age.
                if category == nil && Self.isPendingDownload(url) { pendingDownloads += 1; continue }
                enumerated += 1
                publish(category.map { "Scanning \($0.rawValue.lowercased())" } ?? personalPhase)
                let lastUse = max(fingerprint.modified, values.contentAccessDate ?? fingerprint.modified)
                if category == nil && options.videos && VideoCompressionService.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    let video = Candidate(url: url, category: .videos, fingerprint: fingerprint)
                    if personalCategory == .videos { videoReady[video.id] = video }
                    else { pendingVideos[video.id] = video }
                }
                if age > 0 && now.timeIntervalSince(lastUse) < age { continue }
                let selectedCategory: CleanupCategory
                if let category { selectedCategory = category }
                else if options.downloads && url.path.hasPrefix(downloadsPrefix) && now.timeIntervalSince(lastUse) >= 30 * 86400 {
                    selectedCategory = .downloads
                } else if options.large && fingerprint.size >= Self.largeFileBytes { selectedCategory = .large }
                else if options.duplicates { selectedCategory = .duplicates }
                else { continue }
                let item = Candidate(url: url, category: selectedCategory, fingerprint: fingerprint)
                if category == nil && options.duplicates { items[item.id] = item }
                else if category == nil && personalCategory != selectedCategory { personalReady[item.id] = item }
                else { ready[item.id] = item }
            }
            publish(category.map { "Scanning \($0.rawValue.lowercased())" } ?? personalPhase, force: true)
        }
        func preparePersonal(_ phase: String, category: CleanupCategory) throws {
            guard !personalScanned else { return }
            personalScanned = true
            personalPhase = phase
            personalCategory = category
            let started = clock.now, before = enumerated
            defer { timings.add("Walk personal folders", since: started, items: enumerated - before) }
            for root in options.folders { try walk(root, category: nil) }
            if pendingDownloads > 0 {
                notes.insert("Left out \(pendingDownloads) unfinished download\(pendingDownloads == 1 ? "" : "s") (.crdownload, .part, .download, .partial)")
            }
        }
        func publishPersonal(_ category: CleanupCategory) throws {
            let phase = "Scanning \(category.rawValue.lowercased())"
            try preparePersonal(phase, category: category)
            for item in personalReady.values.filter({ $0.category == category }).sorted(by: Candidate.largestFirst) {
                try Task.checkCancellation()
                ready[item.id] = item
                publish(phase)
            }
            publish(phase, force: true)
        }
        // Keep this sequence aligned with CleanupCategory.allCases (the sidebar).
        if options.duplicates {
            try preparePersonal("Finding duplicate candidates", category: .duplicates)
            let personal = items.values.filter { [.duplicates, .downloads, .large].contains($0.category) }
            let sizes = Dictionary(grouping: personal, by: { $0.bytes })
            // Largest potential savings first. A completed group can be cleaned while
            // later groups continue, with its original already protected.
            for size in sizes.keys.sorted(by: >) {
                try Task.checkCancellation()
                let group = sizes[size]!
                var verified = [String: Candidate]()
                if group.count > 1 {
                    var samples: [String: [Candidate]] = [:]
                    for item in group {
                        try Task.checkCancellation()
                        do {
                            let started = clock.now
                            defer { timings.add("Duplicates: compare file starts and ends", since: started) }
                            let sample = try hashContents(item.url, sample: true)
                            guard try Fingerprint.read(item.url) == item.fingerprint else {
                                notes.insert("Changed during scan: \(item.url.path)"); continue
                            }
                            samples[sample, default: []].append(item)
                            verified[item.id] = item
                        } catch is CancellationError { throw CancellationError() }
                        catch { notes.insert("Could not verify: \(item.url.path)") }
                        publish("Verifying duplicate candidates")
                    }
                    for candidates in samples.values where candidates.count > 1 {
                        var hashes: [String: [Candidate]] = [:]
                        for item in candidates {
                            try Task.checkCancellation()
                            do {
                                let started = clock.now
                                defer { timings.add("Duplicates: read whole files", since: started, bytes: item.bytes) }
                                let hash = try digest(item.url)
                                guard try Fingerprint.read(item.url) == item.fingerprint else {
                                    verified.removeValue(forKey: item.id)
                                    notes.insert("Changed during scan: \(item.url.path)"); continue
                                }
                                hashes[hash, default: []].append(item)
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                verified.removeValue(forKey: item.id)
                                notes.insert("Could not verify: \(item.url.path)")
                            }
                            publish("Verifying duplicate contents")
                        }
                        for (hash, matches) in hashes where matches.count > 1 {
                            // The protected original is a copy outside Downloads when there is one
                            // (the filed copy, not the one that just arrived), then the oldest.
                            let sorted = matches.sorted {
                                let left = $0.id.hasPrefix(downloadsPrefix), right = $1.id.hasPrefix(downloadsPrefix)
                                if left != right { return right }
                                if $0.fingerprint.modified == $1.fingerprint.modified { return $0.id < $1.id }
                                return $0.fingerprint.modified < $1.fingerprint.modified
                            }
                            for (index, var item) in sorted.enumerated() {
                                item.category = .duplicates; item.duplicateHash = hash; item.keeper = index == 0
                                verified[item.id] = item
                            }
                        }
                    }
                } else {
                    verified = Dictionary(uniqueKeysWithValues: group.map { ($0.id, $0) })
                }
                for item in verified.values {
                    if item.category == .duplicates {
                        if item.duplicateHash != nil { ready[item.id] = item }
                    } else { personalReady[item.id] = item }
                }
                publish("Duplicate group ready")
            }
            publish("Scanning duplicates", force: true)
        }
        if options.downloads { try publishPersonal(.downloads) }
        if options.browsers {
            let started = clock.now, before = enumerated
            defer { timings.add("Walk browser caches", since: started, items: enumerated - before) }
            for root in browserRoots { try walk(root, category: .browsers, age: 86400) }
            for root in profileRoots {
                for profile in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                    where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
                    for name in ["Cache", "Code Cache", "GPUCache"] { try walk(profile.appendingPathComponent(name), category: .browsers, age: 86400) }
                }
            }
            let firefox = home.appendingPathComponent("Library/Caches/Firefox/Profiles")
            for profile in (try? fm.contentsOfDirectory(at: firefox, includingPropertiesForKeys: nil)) ?? [] {
                try walk(profile.appendingPathComponent("cache2"), category: .browsers, age: 86400)
            }
            publish("Scanning browser caches", force: true)
        }
        if options.caches {
            let started = clock.now, before = enumerated
            defer { timings.add("Walk developer caches", since: started, items: enumerated - before) }
            for root in cacheRoots { try walk(root, category: .caches, age: 7 * 86400) }
            publish("Scanning developer caches", force: true)
        }
        if options.temporary {
            let started = clock.now, before = enumerated
            defer { timings.add("Walk temporary files", since: started, items: enumerated - before) }
            try walk(temp, category: .temporary, age: 7 * 86400)
            publish("Scanning temporary files", force: true)
        }
        if options.large { try publishPersonal(.large) }
        if options.videos {
            try preparePersonal("Finding videos", category: .videos)
            for item in pendingVideos.values.sorted(by: Candidate.largestFirst) {
                try Task.checkCancellation()
                videoReady[item.id] = item
                publish("Scanning videos")
            }
            publish("Scanning videos", force: true)
        }
        publish("Scan complete", force: true)
        var finished = snapshot()
        timings.add("Whole scan", since: scanStart, items: enumerated)
        finished.timings = timings
        return finished
    }

    /// `wholeGroups` holds the hashes of duplicate groups the user chose in full, original included.
    /// Only those originals may be removed; every other original stays protected.
    public func validateSelection(_ selected: [Candidate], all: [Candidate], folders: [URL],
                                  wholeGroups: Set<String> = []) throws {
        let ids = Set(selected.map(\.id))
        for item in selected {
            try validate(item, folders: folders, wholeGroups: wholeGroups, readContents: true) { hash in
                all.first { $0.duplicateHash == hash && $0.keeper && !ids.contains($0.id) }
            }
        }
    }
    /// One selected file. `original` returns the protected original of a duplicate group.
    /// `readContents: false` leaves out the two full reads. Only the whole-batch pass before any
    /// move does that: each file and its original are read in full again just before that file moves.
    func validate(_ item: Candidate, folders: [URL], wholeGroups: Set<String>, readContents: Bool,
                  original: (String) -> Candidate?) throws {
        try validateLocation(item, folders: folders)
        if item.keeper {
            guard let hash = item.duplicateHash, wholeGroups.contains(hash) else { throw SafetyError.keeper }
            return
        }
        guard let hash = item.duplicateHash else { return }
        guard let keeper = original(hash) else { throw SafetyError.keeper }
        try validateLocation(keeper, folders: folders)
        guard readContents else { return }
        guard try digest(keeper.url) == hash, try digest(item.url) == hash else { throw SafetyError.changed(item.url.path) }
    }
}
