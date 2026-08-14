import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Renders the edit to a movie file.
///
/// Uses a reader/writer pair rather than `AVAssetExportSession` so the output
/// dimensions, frame rate and bitrate are exactly what the user picked — an
/// export preset would quietly impose its own.
@MainActor
final class Exporter: ObservableObject {

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastOutputURL: URL?

    /// Builds the composition once and hands it to whichever writer the chosen
    /// format needs.
    func export(
        project: Project,
        edit: EditModel,
        settings: ExportSettings,
        to outputURL: URL
    ) async throws {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        defer { isExporting = false }

        if settings.format == .gif {
            try await writeGIF(project: project, edit: edit, settings: settings, to: outputURL)
            progress = 1
            lastOutputURL = outputURL
            return
        }

        guard project.videoFileExists else { throw project.missingVideoError }
        let asset = AVURLAsset(url: project.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecutError.message("The project's video track is missing.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let webcamTrack = videoTracks.count > 1 ? videoTracks[1] : nil
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))

        let renderSize = CompositionBuilder.canvasSize(
            forWidth: settings.width, source: sourceSize, frame: edit.frame
        )

        // A private copy so a slider nudged mid-export can't change the output.
        let state = RenderState()
        state.update {
            $0.timeline = Timeline(clips: edit.clips)
            $0.segments = edit.segments
            $0.background = edit.background
            $0.frame = edit.frame
            $0.cursorSettings = edit.cursor
            $0.masks = edit.masks
            $0.cursor = CursorPath(
                events: project.events, duration: project.meta.duration, settings: edit.cursor
            )
            $0.webcam = edit.webcam
            $0.shortcuts = edit.shortcuts
            $0.texts = edit.texts
            $0.watermark = edit.watermark
            $0.keepCursorInFrame = edit.autoZoom.keepCursorInFrame
            $0.keyEvents = project.events.filter { $0.kind == .key }
            $0.sourceTransform = transform.isIdentity ? .identity : transform
        }

        let built = try CompositionBuilder.build(
            asset: asset,
            videoTrack: track,
            audioTrack: audioTrack,
            webcamTrack: webcamTrack,
            clips: edit.clips,
            renderSize: renderSize,
            fps: settings.fps,
            state: state
        )

        guard built.duration.seconds > 0.05 else {
            throw RecutError.message("The timeline is empty.")
        }

        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: built.composition)
        let compVideoTracks = built.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: compVideoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw RecutError.message("Could not set up the render pass.")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        let compAudioTracks = built.composition.tracks(withMediaType: .audio)
        if !compAudioTracks.isEmpty, !settings.format.isAnimatedImage {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: compAudioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                ]
            )
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let fileType: AVFileType = settings.format == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        let bitrate = min(
            Int(renderSize.width * renderSize.height * Double(settings.fps)
                * settings.quality.bitsPerPixel),
            80_000_000
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw RecutError.message("Could not configure the export encoder.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecutError.message("Could not start the export.")
        }
        guard reader.startReading() else {
            throw reader.error ?? RecutError.message("Could not read the recording.")
        }
        writer.startSession(atSourceTime: .zero)

        let total = built.duration.seconds
        let tracker = ProgressBox()

        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.progress = tracker.value
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pump(
                    output: videoOutput, input: videoInput,
                    label: "video", start: .zero, total: total, progress: tracker
                )
            }
            if let audioOutput, let audioInput {
                group.addTask {
                    await Self.pump(
                        output: audioOutput, input: audioInput,
                        label: "audio", start: .zero, total: total, progress: nil
                    )
                }
            }
        }

        poller.cancel()

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? RecutError.message("Rendering failed.")
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? RecutError.message("Writing the export failed.")
        }
        progress = 1
        lastOutputURL = outputURL
    }

    /// Shared setup: everything both writers need from the project.
    private func prepare(
        project: Project, edit: EditModel, settings: ExportSettings, fps: Int
    ) async throws -> CompositionBuilder.Built {
        guard project.videoFileExists else { throw project.missingVideoError }
        let asset = AVURLAsset(url: project.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecutError.message("The project's video track is missing.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let webcamTrack = videoTracks.count > 1 ? videoTracks[1] : nil
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))

        let state = RenderState()
        state.update {
            $0.timeline = Timeline(clips: edit.clips)
            $0.segments = edit.segments
            $0.background = edit.background
            $0.frame = edit.frame
            $0.cursorSettings = edit.cursor
            $0.masks = edit.masks
            $0.cursor = CursorPath(
                events: project.events, duration: project.meta.duration, settings: edit.cursor
            )
            $0.webcam = edit.webcam
            $0.shortcuts = edit.shortcuts
            $0.texts = edit.texts
            $0.watermark = edit.watermark
            $0.keepCursorInFrame = edit.autoZoom.keepCursorInFrame
            $0.keyEvents = project.events.filter { $0.kind == .key }
            $0.sourceTransform = transform.isIdentity ? .identity : transform
        }

        return try CompositionBuilder.build(
            asset: asset,
            videoTrack: track,
            audioTrack: audioTrack,
            webcamTrack: webcamTrack,
            clips: edit.clips,
            renderSize: CompositionBuilder.canvasSize(
                forWidth: settings.width, source: sourceSize, frame: edit.frame
            ),
            fps: fps,
            state: state
        )
    }

    /// Animated GIF, via ImageIO. Frame rate is clamped hard — a 60 fps GIF is
    /// enormous and no better to look at than 20.
    private func writeGIF(
        project: Project, edit: EditModel, settings: ExportSettings, to outputURL: URL
    ) async throws {
        let fps = min(settings.fps, 20)
        let built = try await prepare(
            project: project, edit: edit, settings: settings, fps: fps
        )
        guard built.duration.seconds > 0.05 else {
            throw RecutError.message("The timeline is empty.")
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, 0, nil
        ) else {
            throw RecutError.message("Could not create the GIF.")
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.videoComposition = built.videoComposition
        guard reader.canAdd(output) else {
            throw RecutError.message("Could not set up the render pass.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecutError.message("Could not read the recording.")
        }

        let context = CIContext()
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)
            ]
        ] as CFDictionary
        let total = built.duration.seconds
        var written = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let image = CIImage(cvPixelBuffer: pixels)
            guard let cg = context.createCGImage(image, from: image.extent) else { continue }
            CGImageDestinationAddImage(destination, cg, frameProperties)
            written += 1

            let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            progress = min(max(t / total, 0), 0.99)
            // ImageIO work is synchronous; yield so the UI keeps painting.
            await Task.yield()
        }

        guard written > 0, CGImageDestinationFinalize(destination) else {
            throw RecutError.message("The GIF came out empty.")
        }
    }

    /// Drains one reader output into its writer input.
    private static func pump(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        label: String,
        start: CMTime,
        total: Double,
        progress: ProgressBox?
    ) async {
        let queue = DispatchQueue(label: "com.recut.export.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if let progress, total > 0 {
                        let t = CMSampleBufferGetPresentationTimeStamp(buffer)
                        progress.set(min(max((t - start).seconds / total, 0), 1))
                    }
                    if !input.append(buffer) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}

/// Written from the reader queues, read on the main actor. A lock rather than
/// an actor so the per-frame write doesn't have to spawn a task.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double = 0

    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        stored = max(stored, v)
    }
}
