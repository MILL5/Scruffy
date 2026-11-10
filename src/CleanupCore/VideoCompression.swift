import Foundation
import Darwin
@preconcurrency import AVFoundation
import CoreMedia

public struct VideoCompressionOutcome: Sendable {
    public let url: URL
    public let originalBytes: Int64
    public let compressedBytes: Int64
    public var savedBytes: Int64 { originalBytes - compressedBytes }
    public init(url: URL, originalBytes: Int64, compressedBytes: Int64) {
        self.url = url; self.originalBytes = originalBytes; self.compressedBytes = compressedBytes
    }
}

public enum VideoCompressionError: LocalizedError, Sendable {
    case unsupported(String), notSmaller, invalidOutput(String), transaction(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): "Video left unchanged: \(reason)"
        case .notSmaller: "The high-quality export was not smaller. The original video was left unchanged."
        case .invalidOutput(let reason): "Video verification failed; the original was left unchanged. \(reason)"
        case .transaction(let reason): reason
        }
    }
}

struct VideoCompressionMediaInfo: Sendable {
    struct Audio: Sendable {
        var start: Double
        var duration: Double
        var channels: UInt32
    }
    var duration: Double
    var videoStart: Double
    var videoDuration: Double
    var encodedWidth: Int32
    var encodedHeight: Int32
    var displayWidth: Double
    var displayHeight: Double
    var frameRate: Double
    var codec: FourCharCode
    var hasAlpha: Bool
    var hasHDR = false
    var color: [String: String] = [:]
    var audio: [Audio]
}

public struct VideoCompressionService: Sendable {
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]
    typealias Inspector = @Sendable (URL, Bool) async throws -> VideoCompressionMediaInfo
    typealias Exporter = @Sendable (URL, URL, (@Sendable (Double) -> Void)?) async throws -> Void
    typealias Mover = @Sendable (URL) throws -> URL
    typealias Installer = @Sendable (URL, URL) throws -> Void

    private let scanner: CleanupScanner
    private let trash: TrashService
    private let inspect: Inspector
    private let export: Exporter
    private let moveToTrash: Mover
    private let install: Installer
    private static let replacementGate = VideoReplacementGate()

    public init(scanner: CleanupScanner = CleanupScanner(), journal: URL? = nil) {
        self.init(scanner: scanner, journal: journal, moveToTrash: Self.trashItem)
    }

    init(scanner: CleanupScanner, journal: URL?, moveToTrash: @escaping Mover) {
        self.init(scanner: scanner, journal: journal, inspect: NativeVideo.inspect,
                  export: { source, output, progress in
                      try await NativeVideoExporter().export(source: source, output: output, progress: progress)
                  }, moveToTrash: moveToTrash, install: Self.installExclusively)
    }

    init(scanner: CleanupScanner, journal: URL?, inspect: @escaping Inspector,
         export: @escaping Exporter, moveToTrash: @escaping Mover = Self.trashItem,
         install: @escaping Installer = Self.installExclusively) {
        self.scanner = scanner; trash = TrashService(scanner: scanner, journal: journal)
        self.inspect = inspect; self.export = export; self.moveToTrash = moveToTrash; self.install = install
    }

    public func compress(_ candidate: Candidate, folders: [URL],
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> VideoCompressionOutcome {
        try Task.checkCancellation()
        guard candidate.category == .videos, !candidate.keeper, candidate.duplicateHash == nil,
              Self.supportedExtensions.contains(candidate.url.pathExtension.lowercased()) else {
            throw VideoCompressionError.unsupported("Only explicitly reviewed MP4, MOV and M4V videos are supported.")
        }
        try validateOriginal(candidate, folders: folders)
        let original = try await inspect(candidate.url, false)
        guard !original.hasHDR else {
            throw VideoCompressionError.unsupported("HDR video is not yet supported without risking its color or dynamic-range metadata.")
        }
        let parent = try VideoDirectoryIdentity(candidate.url.deletingLastPathComponent())
        let staging = try VideoStaging(beside: candidate.url)
        var retainStaging = false
        defer { if !retainStaging { staging.removeIfOwned() } }
        progress?(0)
        try await export(candidate.url, staging.file, { value in progress?(min(0.9, max(0, value * 0.9))) })
        try Task.checkCancellation()
        guard scanner.allowed(staging.file) else { throw VideoCompressionError.invalidOutput("The staged output is no longer in its safe location.") }
        let outputFingerprint = try Fingerprint.read(staging.file)
        guard outputFingerprint.links == 1, outputFingerprint.size > 0 else {
            throw VideoCompressionError.invalidOutput("The staged output is empty or has unsupported links.")
        }
        try Self.noResourceFork(staging.file)
        let compressed = try await inspect(staging.file, true)
        try Self.verify(original: original, compressed: compressed)
        guard outputFingerprint.size < candidate.bytes else { throw VideoCompressionError.notSmaller }
        guard try Fingerprint.read(staging.file) == outputFingerprint else { throw VideoCompressionError.invalidOutput("The staged output changed during verification.") }
        try validateOriginal(candidate, folders: folders)
        guard try VideoDirectoryIdentity(candidate.url.deletingLastPathComponent()) == parent else {
            throw SafetyError.changed(candidate.url.deletingLastPathComponent().path)
        }
        try Task.checkCancellation()
        progress?(0.95)

        // Cancellation ends at this boundary. The detached transaction must finish
        // installation or rollback after moving the original out of its path.
        let transaction = Task.detached(priority: .userInitiated) {
            await Self.replacementGate.acquire()
            do {
                let result = try await replace(candidate, folders: folders, staging: staging,
                                               output: outputFingerprint, parent: parent)
                await Self.replacementGate.release()
                return result
            } catch {
                await Self.replacementGate.release()
                throw error
            }
        }
        do {
            let result = try await transaction.value
            progress?(1)
            return result
        } catch let failure as VideoReplacementFailure {
            retainStaging = failure.retainStaging
            throw VideoCompressionError.transaction(failure.message)
        }
    }

    private func validateOriginal(_ candidate: Candidate, folders: [URL]) throws {
        try scanner.validateLocation(candidate, folders: folders)
        try Self.noResourceFork(candidate.url)
    }

    private static func noResourceFork(_ url: URL) throws {
        let length = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        guard length == 0 || (length == -1 && errno == ENOATTR) else {
            throw VideoCompressionError.unsupported("Files with resource-fork data cannot be replaced safely.")
        }
    }

    private static func verify(original: VideoCompressionMediaInfo, compressed: VideoCompressionMediaInfo) throws {
        func close(_ left: Double, _ right: Double, tolerance: Double = 0.1) -> Bool {
            left.isFinite && right.isFinite && abs(left - right) <= tolerance
        }
        let originalDimensions = [original.encodedWidth, original.encodedHeight].sorted()
        let compressedDimensions = [compressed.encodedWidth, compressed.encodedHeight].sorted()
        guard compressed.codec == kCMVideoCodecType_HEVC, originalDimensions == compressedDimensions,
              close(original.displayWidth, compressed.displayWidth, tolerance: 0.5),
              close(original.displayHeight, compressed.displayHeight, tolerance: 0.5),
              original.hasAlpha == compressed.hasAlpha, original.hasHDR == compressed.hasHDR else {
            throw VideoCompressionError.invalidOutput("Video resolution, orientation, alpha or HEVC encoding was not preserved.")
        }
        for (key, value) in original.color where compressed.color[key] != value {
            throw VideoCompressionError.invalidOutput("Video color primaries, transfer function or matrix changed.")
        }
        let frameTolerance = max(0.1, original.frameRate * 0.005)
        guard close(original.duration, compressed.duration),
              close(original.videoStart, compressed.videoStart), close(original.videoDuration, compressed.videoDuration),
              close(original.frameRate, compressed.frameRate, tolerance: frameTolerance) else {
            throw VideoCompressionError.invalidOutput("Video timing or frame rate changed.")
        }
        guard original.audio.count == compressed.audio.count else {
            throw VideoCompressionError.invalidOutput("An audio track was lost or added.")
        }
        for (source, output) in zip(original.audio, compressed.audio) {
            guard source.channels == output.channels, close(source.start, output.start), close(source.duration, output.duration) else {
                throw VideoCompressionError.invalidOutput("Audio channel coverage or timing changed.")
            }
        }
    }

    private func replace(_ candidate: Candidate, folders: [URL], staging: VideoStaging,
                         output: Fingerprint, parent: VideoDirectoryIdentity) async throws -> VideoCompressionOutcome {
        try validateOriginal(candidate, folders: folders)
        guard try VideoDirectoryIdentity(candidate.url.deletingLastPathComponent()) == parent,
              scanner.allowed(staging.file), try Fingerprint.read(staging.file) == output else {
            throw SafetyError.changed(candidate.url.path)
        }
        let moved = VideoMovedURL()
        let outcome = try await trash.clean([candidate], all: [candidate], folders: folders, browsersRunning: { false }, moveToTrash: { url in
            let destination = try moveToTrash(url)
            moved.set(destination)
            return destination
        })
        guard outcome.count == 1, let trashURL = moved.get() else {
            let missingOriginal = !FileManager.default.fileExists(atPath: candidate.url.path)
            throw VideoReplacementFailure(message: "Could not move the original video to Trash. \(outcome.errors.joined(separator: " "))"
                                          + (missingOriginal ? " Check Finder’s Trash. Verified replacement retained at \(staging.file.path)." : " The original was left in place."),
                                          retainStaging: missingOriginal)
        }
        var record = TrashRecord(id: UUID(), original: candidate.url, trashed: trashURL, fingerprint: candidate.fingerprint, date: Date())
        do {
            if let journalRecord = try trash.records().last(where: { $0.original == candidate.url && $0.fingerprint == candidate.fingerprint }) {
                record = TrashRecord(id: journalRecord.id, original: candidate.url, trashed: trashURL,
                                     fingerprint: candidate.fingerprint, date: journalRecord.date)
            }
            guard outcome.errors.isEmpty else { throw VideoCompressionError.transaction(outcome.errors.joined(separator: " ")) }
            guard try VideoDirectoryIdentity(candidate.url.deletingLastPathComponent()) == parent,
                  scanner.allowed(staging.file), try Fingerprint.read(staging.file) == output else {
                throw SafetyError.changed(staging.file.path)
            }
            try install(staging.file, candidate.url)
        } catch {
            let installationError = error.localizedDescription
            do {
                try trash.restore(record)
                throw VideoReplacementFailure(message: "Replacement failed and the original video was restored: \(installationError)", retainStaging: false)
            } catch let failure as VideoReplacementFailure { throw failure }
            catch {
                let originalRestored = (try? Fingerprint.read(candidate.url)) == candidate.fingerprint
                    && !FileManager.default.fileExists(atPath: trashURL.path)
                if originalRestored {
                    throw VideoReplacementFailure(message: "Replacement failed and the original video was restored, but its recovery-history update failed. \(installationError)", retainStaging: false)
                }
                throw VideoReplacementFailure(message: "Replacement failed: \(installationError). The original is retained in Trash at \(trashURL.path). Verified replacement retained at \(staging.file.path). Restore without overwriting the current destination using Finder.", retainStaging: true)
            }
        }
        return VideoCompressionOutcome(url: candidate.url, originalBytes: candidate.bytes, compressedBytes: output.size)
    }

    static func trashItem(_ url: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let destination else { throw VideoCompressionError.transaction("Finder did not report the original’s Trash location. Check Finder’s Trash.") }
        return destination as URL
    }

    static func installExclusively(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private actor VideoReplacementGate {
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !active { active = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active = false }
        else { waiters.removeFirst().resume() }
    }
}

private final class VideoMovedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ url: URL) { lock.withLock { self.url = url } }
    func get() -> URL? { lock.withLock { url } }
}

private struct VideoReplacementFailure: Error {
    let message: String
    let retainStaging: Bool
}

private struct VideoDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw SafetyError.unsafe(url.path) }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
    }
}

private struct VideoStaging: Sendable {
    let directory: URL
    let file: URL
    let identity: VideoDirectoryIdentity
    init(beside original: URL) throws {
        directory = original.deletingLastPathComponent().appendingPathComponent(".scruffy-video-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        identity = try VideoDirectoryIdentity(directory)
        file = directory.appendingPathComponent(original.lastPathComponent)
    }
    func removeIfOwned() {
        if (try? VideoDirectoryIdentity(directory)) == identity { try? FileManager.default.removeItem(at: directory) }
    }
}

private enum NativeVideo {
    static func inspect(_ url: URL, verifySamples: Bool) async throws -> VideoCompressionMediaInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.isReadable), try await !asset.load(.hasProtectedContent) else {
            throw VideoCompressionError.unsupported("The video is unreadable or protected.")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let video = tracks.first else {
            throw VideoCompressionError.unsupported("Exactly one video track is required to preserve the complete video.")
        }
        let allTracks = try await asset.load(.tracks)
        guard allTracks.allSatisfy({ $0.mediaType == .video || $0.mediaType == .audio }) else {
            throw VideoCompressionError.unsupported("Additional subtitle, timecode or timed-metadata tracks cannot be preserved by this export.")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await video.load(.formatDescriptions)
        guard let format = descriptions.first else { throw VideoCompressionError.unsupported("The video format could not be read.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let duration = try await asset.load(.duration).seconds
        let videoRange = try await video.load(.timeRange)
        let frameRate = Double(try await video.load(.nominalFrameRate))
        let characteristics = try await video.load(.mediaCharacteristics)
        let extensions = CMFormatDescriptionGetExtensions(format).map { $0 as NSDictionary } ?? NSDictionary()
        var color: [String: String] = [:]
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            if let value = extensions[key] as? String { color[key as String] = value }
        }
        let transfer = color[kCMFormatDescriptionExtension_TransferFunction as String]
        let hdr = characteristics.contains(.containsHDRVideo)
            || transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        guard duration.isFinite, duration > 0, dimensions.width > 0, dimensions.height > 0,
              display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0,
              frameRate.isFinite, frameRate > 0 else { throw VideoCompressionError.unsupported("The video dimensions or timing are unsupported.") }
        var audioInfo: [VideoCompressionMediaInfo.Audio] = []
        for track in audio {
            try Task.checkCancellation()
            let range = try await track.load(.timeRange)
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  stream.pointee.mChannelsPerFrame > 0, range.duration.seconds.isFinite, range.duration.seconds > 0 else {
                throw VideoCompressionError.unsupported("An audio track could not be verified.")
            }
            audioInfo.append(.init(start: range.start.seconds, duration: range.duration.seconds, channels: stream.pointee.mChannelsPerFrame))
        }
        if verifySamples { try await readAllSamples(asset, tracks: tracks + audio) }
        return VideoCompressionMediaInfo(duration: duration, videoStart: videoRange.start.seconds, videoDuration: videoRange.duration.seconds,
                                         encodedWidth: dimensions.width, encodedHeight: dimensions.height,
                                         displayWidth: display.width, displayHeight: display.height, frameRate: frameRate,
                                         codec: CMFormatDescriptionGetMediaSubType(format), hasAlpha: characteristics.contains(.containsAlphaChannel),
                                         hasHDR: hdr, color: color, audio: audioInfo)
    }

    private static func readAllSamples(_ asset: AVAsset, tracks: [AVAssetTrack]) async throws {
        let reader = try AVAssetReader(asset: asset)
        let outputs = tracks.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        let providers = outputs.map { reader.outputProvider(for: $0) }
        try reader.start()
        for provider in providers {
            var count = 0
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                // Valid marker buffers describe edits/boundaries, not media.
                if sample.contentType == .markerOnly { continue }
                guard sample.sampleCount > 0 else { throw VideoCompressionError.invalidOutput("An empty media sample was returned.") }
                count += 1
            }
            guard count > 0 else { throw VideoCompressionError.invalidOutput("An output track contains no readable samples.") }
        }
        guard reader.status == .completed else { throw VideoCompressionError.invalidOutput(reader.error?.localizedDescription ?? "The output could not be read to completion.") }
    }
}

private actor NativeVideoExporter {
    func export(source: URL, output: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let type: AVFileType
        switch source.pathExtension.lowercased() {
        case "mp4": type = .mp4
        case "mov": type = .mov
        case "m4v": type = .m4v
        default: throw VideoCompressionError.unsupported("This video container is unsupported.")
        }
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var alpha = false
        for track in tracks {
            if try await track.load(.mediaCharacteristics).contains(.containsAlphaChannel) { alpha = true }
        }
        let preset = alpha ? AVAssetExportPresetHEVCHighestQualityWithAlpha : AVAssetExportPresetHEVCHighestQuality
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type),
              let session = AVAssetExportSession(asset: asset, presetName: preset), session.supportedFileTypes.contains(type) else {
            throw VideoCompressionError.unsupported("High-quality HEVC cannot preserve this video’s existing file container on this Mac.")
        }
        session.canPerformMultiplePassesOverSourceMediaData = true
        session.metadata = try await asset.load(.metadata)
        let states = session.states(updateInterval: 0.25)
        let updates = Task {
            for await state in states {
                if case .exporting(let status) = state { progress?(status.fractionCompleted) }
            }
        }
        defer { updates.cancel() }
        try await session.export(to: output, as: type)
    }
}
