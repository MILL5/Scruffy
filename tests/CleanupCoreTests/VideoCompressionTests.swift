import XCTest
import Foundation
import Darwin
@preconcurrency import AVFoundation
import CoreVideo
@testable import CleanupCore

final class VideoCompressionTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let home: URL
        let folder: URL
        let source: URL
        let fakeTrash: URL
        let journal: URL
        let scanner: CleanupScanner
        init(extension suffix: String = "mp4") throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scruffy-video-test-\(UUID())")
            home = root.appendingPathComponent("home")
            folder = home.appendingPathComponent("Downloads")
            source = folder.appendingPathComponent("original.\(suffix)")
            fakeTrash = root.appendingPathComponent("fake-trash.\(suffix)")
            journal = root.appendingPathComponent("history.json")
            scanner = CleanupScanner(home: home, temp: root.appendingPathComponent("temp"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 1_000).write(to: source)
        }
        func candidate() throws -> Candidate { Candidate(url: source, category: .videos, fingerprint: try Fingerprint.read(source)) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func move(_ source: URL) throws -> URL {
            try FileManager.default.moveItem(at: source, to: fakeTrash)
            return fakeTrash
        }
        func stagingDirectories() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".scruffy-video-") }
        }
    }

    private static var media: VideoCompressionMediaInfo {
        VideoCompressionMediaInfo(duration: 2, videoStart: 0, videoDuration: 2, encodedWidth: 320, encodedHeight: 240,
                                  displayWidth: 320, displayHeight: 240, frameRate: 30, codec: kCMVideoCodecType_HEVC,
                                  hasAlpha: false, color: ["primaries": "bt709", "transfer": "bt709", "matrix": "bt709"],
                                  audio: [.init(start: 0, duration: 2, channels: 2)])
    }

    private func service(_ fixture: Fixture, size: Int = 100,
                         changedOutput: (@Sendable (VideoCompressionMediaInfo) -> VideoCompressionMediaInfo)? = nil,
                         installer: VideoCompressionService.Installer? = nil) -> VideoCompressionService {
        VideoCompressionService(scanner: fixture.scanner, journal: fixture.journal,
                                inspect: { _, output in output ? (changedOutput?(Self.media) ?? Self.media) : Self.media },
                                export: { _, output, progress in try Data(repeating: 9, count: size).write(to: output); progress?(0.5) },
                                moveToTrash: { try fixture.move($0) }, install: installer ?? VideoCompressionService.installExclusively)
    }

    func testSuccessfulReplacementKeepsOriginalAndRecoveryJournal() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        let result = try await service(fixture).compress(candidate, folders: [fixture.folder])
        XCTAssertEqual(result.url, fixture.source)
        XCTAssertEqual(result.originalBytes, 1_000)
        XCTAssertEqual(result.compressedBytes, 100)
        XCTAssertEqual(result.savedBytes, 900)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 9, count: 100))
        XCTAssertEqual(try Data(contentsOf: fixture.fakeTrash), Data(repeating: 7, count: 1_000))
        let records = try TrashService(scanner: fixture.scanner, journal: fixture.journal).records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.original, fixture.source)
        XCTAssertEqual(records.first?.trashed, fixture.fakeTrash)
        XCTAssertEqual(records.first?.fingerprint, candidate.fingerprint)
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }

    func testEqualOrLargerOutputLeavesOriginalAndRemovesStaging() async throws {
        for size in [1_000, 1_001] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            do { _ = try await service(fixture, size: size).compress(fixture.candidate(), folders: [fixture.folder]); XCTFail("Expected no-benefit skip") }
            catch VideoCompressionError.notSmaller { }
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 7, count: 1_000))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fakeTrash.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
            XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
        }
    }

    func testResolutionTimingFrameRateAudioAndAlphaChangesNeverReachTrash() async throws {
        let changes: [@Sendable (VideoCompressionMediaInfo) -> VideoCompressionMediaInfo] = [
            { var m = $0; m.encodedWidth = 160; return m },
            { var m = $0; m.displayHeight = 120; return m },
            { var m = $0; m.duration = 1; return m },
            { var m = $0; m.frameRate = 15; return m },
            { var m = $0; m.audio = []; return m },
            { var m = $0; m.audio[0].duration = 1; return m },
            { var m = $0; m.audio[0].channels = 1; return m },
            { var m = $0; m.hasAlpha = true; return m },
            { var m = $0; m.hasHDR = true; return m },
            { var m = $0; m.color["primaries"] = "bt2020"; return m },
            { var m = $0; m.color["transfer"] = "pq"; return m },
            { var m = $0; m.color.removeValue(forKey: "matrix"); return m },
            { var m = $0; m.codec = kCMVideoCodecType_H264; return m }
        ]
        for change in changes {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            do { _ = try await service(fixture, changedOutput: change).compress(fixture.candidate(), folders: [fixture.folder]); XCTFail("Expected failed verification") }
            catch VideoCompressionError.invalidOutput { }
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 7, count: 1_000))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fakeTrash.path))
            XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
        }
    }

    func testHDRSourceIsSkippedBeforeExportOrTrash() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let service = VideoCompressionService(scanner: fixture.scanner, journal: fixture.journal,
                                               inspect: { _, _ in var info = Self.media; info.hasHDR = true; return info },
                                               export: { _, _, _ in XCTFail("HDR inputs must not reach export") },
                                               moveToTrash: { _ in XCTFail("HDR inputs must not reach Trash"); throw POSIXError(.EIO) })
        do { _ = try await service.compress(fixture.candidate(), folders: [fixture.folder]); XCTFail("Expected HDR skip") }
        catch VideoCompressionError.unsupported { }
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 7, count: 1_000))
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }

    func testUnsupportedExtensionAndResourceForkLeaveOriginalUntouched() async throws {
        let unsupported = try Fixture(extension: "avi"); defer { unsupported.cleanup() }
        do { _ = try await service(unsupported).compress(unsupported.candidate(), folders: [unsupported.folder]); XCTFail("Expected unsupported container") }
        catch VideoCompressionError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupported.fakeTrash.path))

        let resource = try Fixture(); defer { resource.cleanup() }
        let extra = Data("extra resource data".utf8)
        XCTAssertEqual(extra.withUnsafeBytes { setxattr(resource.source.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
        let candidate = try resource.candidate()
        do { _ = try await service(resource).compress(candidate, folders: [resource.folder]); XCTFail("Expected resource-fork protection") }
        catch VideoCompressionError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.fakeTrash.path))
        XCTAssertTrue(try resource.stagingDirectories().isEmpty)
    }

    func testOriginalChangedDuringExportIsNeverTrashed() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        let service = VideoCompressionService(scanner: fixture.scanner, journal: fixture.journal, inspect: { _, _ in Self.media },
                                               export: { original, output, _ in
                                                   try Data("new user work".utf8).write(to: original)
                                                   try Data(repeating: 9, count: 100).write(to: output)
                                               }, moveToTrash: { try fixture.move($0) })
        do { _ = try await service.compress(candidate, folders: [fixture.folder]); XCTFail("Expected original change rejection") }
        catch SafetyError.changed { }
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new user work".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fakeTrash.path))
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }

    func testCancellationDuringExportLeavesOriginalAndCleansPartialOutput() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        let service = VideoCompressionService(scanner: fixture.scanner, journal: fixture.journal, inspect: { _, _ in Self.media },
                                               export: { _, output, _ in
                                                   try Data(repeating: 9, count: 100).write(to: output)
                                                   withUnsafeCurrentTask { $0?.cancel() }
                                                   try Task.checkCancellation()
                                               }, moveToTrash: { try fixture.move($0) })
        let work = Task { try await service.compress(candidate, folders: [fixture.folder]) }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 7, count: 1_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fakeTrash.path))
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }

    func testInstallFailureRestoresOriginalAndRemovesJournalRecord() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        do {
            _ = try await service(fixture, installer: { _, _ in throw POSIXError(.EIO) }).compress(fixture.candidate(), folders: [fixture.folder])
            XCTFail("Expected install failure")
        } catch VideoCompressionError.transaction(let message) { XCTAssertTrue(message.contains("original video was restored")) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 7, count: 1_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fakeTrash.path))
        XCTAssertTrue(try TrashService(scanner: fixture.scanner, journal: fixture.journal).records().isEmpty)
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }

    func testConcurrentDestinationIsNeverOverwrittenAndRecoveryPathsAreRetained() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let newWork = Data("concurrent user work".utf8)
        do {
            _ = try await service(fixture, installer: { stage, destination in
                try newWork.write(to: destination, options: .withoutOverwriting)
                try VideoCompressionService.installExclusively(stage, destination)
            }).compress(fixture.candidate(), folders: [fixture.folder])
            XCTFail("Expected concurrent destination rejection")
        } catch VideoCompressionError.transaction(let message) {
            XCTAssertTrue(message.contains(fixture.fakeTrash.path))
            XCTAssertTrue(message.contains("Verified replacement retained"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), newWork)
        XCTAssertEqual(try Data(contentsOf: fixture.fakeTrash), Data(repeating: 7, count: 1_000))
        let staged = try XCTUnwrap(fixture.stagingDirectories().first).appendingPathComponent(fixture.source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: staged), Data(repeating: 9, count: 100))
        XCTAssertEqual(try TrashService(scanner: fixture.scanner, journal: fixture.journal).records().count, 1)
    }

    func testCriticalReplacementFinishesEvenIfItsTaskBecomesCancelled() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let result = try await service(fixture, installer: { stage, destination in
            withUnsafeCurrentTask { $0?.cancel() }
            try VideoCompressionService.installExclusively(stage, destination)
        }).compress(fixture.candidate(), folders: [fixture.folder])
        XCTAssertEqual(result.compressedBytes, 100)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 9, count: 100))
        XCTAssertEqual(try Data(contentsOf: fixture.fakeTrash), Data(repeating: 7, count: 1_000))
    }

    func testJournalFailureAfterTrashRestoresOriginalInsteadOfInstalling() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let service = VideoCompressionService(scanner: fixture.scanner, journal: fixture.journal, inspect: { _, _ in Self.media },
                                               export: { _, output, _ in try Data(repeating: 9, count: 100).write(to: output) },
                                               moveToTrash: { source in
                                                   let moved = try fixture.move(source)
                                                   let events = fixture.journal.deletingPathExtension().appendingPathExtension("events.jsonl")
                                                   try FileManager.default.removeItem(at: events)
                                                   try FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
                                                   return moved
                                               })
        do { _ = try await service.compress(fixture.candidate(), folders: [fixture.folder]); XCTFail("Expected recovery-history failure") }
        catch VideoCompressionError.transaction(let message) { XCTAssertTrue(message.contains("original video was restored")) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 7, count: 1_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fakeTrash.path))
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
    }

    func testNativeHEVCExportPreservesMP4ResolutionDurationAndStereoAudio() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else { throw XCTSkip("The synthetic writer uses the current AVFoundation pixel-buffer receiver.") }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.source)
        try await makeNativeFixture(at: fixture.source, root: fixture.root)
        let original = try fixture.candidate()
        let service = VideoCompressionService(scanner: fixture.scanner, journal: fixture.journal, moveToTrash: { try fixture.move($0) })
        let result: VideoCompressionOutcome
        do { result = try await service.compress(original, folders: [fixture.folder]) }
        catch VideoCompressionError.unsupported(let reason) { throw XCTSkip(reason) }
        XCTAssertGreaterThan(result.savedBytes, 0)
        XCTAssertEqual(result.url.pathExtension, "mp4")
        XCTAssertEqual(try Fingerprint.read(fixture.fakeTrash), original.fingerprint)
        let asset = AVURLAsset(url: result.url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videos.first)
        let originalVideoFormats = try await video.load(.formatDescriptions)
        let dimensions = CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(originalVideoFormats.first))
        XCTAssertEqual(dimensions.width, 320)
        XCTAssertEqual(dimensions.height, 240)
        XCTAssertEqual(audio.count, 1)
        let audioFormats = try await audio[0].load(.formatDescriptions)
        let audioDescription = try XCTUnwrap(audioFormats.first)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee.mChannelsPerFrame, 2)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        let videoFormats = try await video.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(videoFormats.first)), kCMVideoCodecType_HEVC)
        XCTAssertTrue(try fixture.stagingDirectories().isEmpty)
        #else
        throw XCTSkip("The native synthetic fixture requires the macOS 26 SDK; injected transaction tests still run.")
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private func makeNativeFixture(at destination: URL, root: URL) async throws {
        let videoURL = root.appendingPathComponent("fixture-video.mp4")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                        AVVideoWidthKey: 320, AVVideoHeightKey: 240,
                                                                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: 1]])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            var buffer = try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 320, height: 240)))
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                let plane = planes[0]
                for y in 0..<240 {
                    for x in 0..<320 {
                        let position = y * plane.properties.bytesPerRow + x * 4
                        plane.bytes[position] = UInt8((x + frame * 3) % 256)
                        plane.bytes[position + 1] = UInt8(y % 256)
                        plane.bytes[position + 2] = UInt8((x + y) % 256)
                        plane.bytes[position + 3] = 255
                    }
                }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(frame), timescale: 30))
        }
        receiver.finish(); writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw try XCTUnwrap(writer.error) }

        let wav = root.appendingPathComponent("fixture-audio.wav")
        var audio = Data()
        let payload = Data(repeating: 0, count: 44_100 * 2 * 2)
        audio.append(Data("RIFF".utf8)); appendLE(UInt32(36 + payload.count), to: &audio)
        audio.append(Data("WAVEfmt ".utf8)); appendLE(UInt32(16), to: &audio)
        appendLE(UInt16(1), to: &audio); appendLE(UInt16(2), to: &audio)
        appendLE(UInt32(44_100), to: &audio); appendLE(UInt32(176_400), to: &audio)
        appendLE(UInt16(4), to: &audio); appendLE(UInt16(16), to: &audio)
        audio.append(Data("data".utf8)); appendLE(UInt32(payload.count), to: &audio); audio.append(payload)
        try audio.write(to: wav)
        let videoAsset = AVURLAsset(url: videoURL), audioAsset = AVURLAsset(url: wav)
        let sourceVideos = try await videoAsset.loadTracks(withMediaType: .video)
        let sourceAudios = try await audioAsset.loadTracks(withMediaType: .audio)
        let sourceVideo = try XCTUnwrap(sourceVideos.first)
        let sourceAudio = try XCTUnwrap(sourceAudios.first)
        let composition = AVMutableComposition()
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await export.export(to: destination, as: .mp4)
        // A legal unused MP4 atom makes a smaller valid re-export deterministic.
        var padding = Data(); var size = UInt32(1_048_584).bigEndian
        withUnsafeBytes(of: &size) { padding.append(contentsOf: $0) }
        padding.append(Data("free".utf8)); padding.append(Data(repeating: 0, count: 1_048_576))
        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd(); try handle.write(contentsOf: padding); try handle.close()
    }
    #endif

    private func appendLE<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var number = number.littleEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
    }
}
