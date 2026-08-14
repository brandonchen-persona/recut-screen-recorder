import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import Metal

/// Everything the compositor needs to draw a frame. Copied out under a lock so
/// the render thread never touches the UI's mutable state.
struct RenderSnapshot {
    var timeline = Timeline.empty
    var segments: [ZoomSegment] = []
    var background = BackgroundSettings()
    var frame = FrameSettings()
    var cursorSettings = CursorSettings()
    var masks: [MaskRegion] = []
    var cursor: CursorPath = .empty
    var webcam = WebcamSettings()
    var shortcuts = ShortcutSettings()
    var texts: [TextOverlay] = []
    var watermark = WatermarkSettings()
    /// Pan to keep the pointer on screen while magnified.
    var keepCursorInFrame = true
    /// Key presses, for the on-screen shortcut labels.
    var keyEvents: [InputEvent] = []
    var sourceTransform: CGAffineTransform = .identity
    /// Preview-only: show the whole frame, unzoomed and uncropped, so the crop
    /// rectangle and the manual-zoom anchor map straight onto what's on screen.
    var previewFullFrame = false
}

/// Shared, mutable, thread-safe box read by the compositor and written by the UI.
///
/// Handing the compositor a live reference rather than baking settings into the
/// composition means a slider drag doesn't require rebuilding (and reattaching)
/// an `AVVideoComposition` on every frame.
final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RenderSnapshot()

    var snapshot: RenderSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ mutate: (inout RenderSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&value)
    }
}

/// Carries the render state to the compositor. AVFoundation instantiates the
/// compositor class itself, so the instruction is the only clean channel.
final class RecutInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    /// Second video track, when the recording has a camera alongside the screen.
    let webcamTrackID: CMPersistentTrackID?
    let state: RenderState

    init(
        timeRange: CMTimeRange,
        trackID: CMPersistentTrackID,
        webcamTrackID: CMPersistentTrackID? = nil,
        state: RenderState
    ) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.webcamTrackID = webcamTrackID
        self.state = state
        var ids = [NSNumber(value: trackID)]
        if let webcamTrackID { ids.append(NSNumber(value: webcamTrackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

final class RecutCompositor: NSObject, AVVideoCompositing {

    private let renderer = FrameRenderer()
    private let ciContext: CIContext
    private let queue = DispatchQueue(label: "com.recut.compositor", qos: .userInitiated)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .name: "RecutCompositor",
            ])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? RecutInstruction else {
                request.finish(with: RecutError.message("Unexpected composition instruction."))
                return
            }
            guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.trackID) else {
                request.finish(with: RecutError.message("Missing source frame."))
                return
            }
            guard let destination = request.renderContext.newPixelBuffer() else {
                request.finish(with: RecutError.message("Could not allocate an output buffer."))
                return
            }

            let snapshot = instruction.state.snapshot
            var source = CIImage(cvPixelBuffer: sourceBuffer)
            if !snapshot.sourceTransform.isIdentity {
                source = source.transformed(by: snapshot.sourceTransform)
                source = source.transformed(by: CGAffineTransform(
                    translationX: -source.extent.minX,
                    y: -source.extent.minY
                ))
            }

            let canvas = CGRect(origin: .zero, size: request.renderContext.size)
            // Zooms, masks and the cursor all live in source time, so undo the
            // cuts and speed changes before asking where the camera should be.
            let sourceTime = snapshot.timeline.sourceTime(at: request.compositionTime.seconds)

            var webcamImage: CIImage?
            if snapshot.webcam.enabled,
               let webcamTrackID = instruction.webcamTrackID,
               let buffer = request.sourceFrame(byTrackID: webcamTrackID) {
                webcamImage = CIImage(cvPixelBuffer: buffer)
            }

            let image = renderer.render(
                source: source,
                canvas: canvas,
                sourceTime: sourceTime,
                snapshot: snapshot,
                webcam: webcamImage
            )

            ciContext.render(image, to: destination, bounds: canvas, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: destination)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Building compositions

enum CompositionBuilder {

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition
        var audioMix: AVMutableAudioMix?
        var duration: CMTime
        var renderSize: CGSize
    }

    /// How wide to render the preview canvas.
    ///
    /// There's no point rendering beyond the detail the source can supply, but
    /// clamping to the source *width* collapses the canvas whenever the output
    /// is wider than the recording — a 308pt-wide portrait strip in a 16:9
    /// frame came out as a 308×174 postage stamp. The longest side is the right
    /// bound: it's what limits real detail whichever way the recording is
    /// oriented.
    static func previewWidth(quality: Int, source: CGSize) -> Int {
        let longestSide = Int(max(source.width, source.height).rounded())
        return max(320, min(quality, max(longestSide, 320)))
    }

    /// The canvas the recording is composited onto, honouring the chosen aspect
    /// ratio. Rounded to even numbers because H.264/HEVC reject odd dimensions.
    /// Longest side any canvas is allowed to reach. A portrait strip on an Auto
    /// canvas asked for 1920 wide comes out 15000 tall, which nothing decodes;
    /// the requested width is treated as a target, not a promise.
    static let maxCanvasSide: Double = 4096

    static func canvasSize(forWidth width: Int, source: CGSize, frame: FrameSettings) -> CGSize {
        let cropped = CGSize(
            width: max(1, source.width * frame.crop.width),
            height: max(1, source.height * frame.crop.height)
        )
        let ratio = frame.aspect.value ?? (cropped.width / max(1, cropped.height))
        var w = max(2, Double(width))
        var h = max(2, w / max(0.01, ratio))

        let longest = max(w, h)
        if longest > maxCanvasSide {
            let shrink = maxCanvasSide / longest
            w *= shrink
            h *= shrink
        }

        // Even numbers: H.264 and HEVC reject odd dimensions.
        return CGSize(
            width: max(2, (w / 2).rounded() * 2),
            height: max(2, (h / 2).rounded() * 2)
        )
    }

    /// Lays the clips end to end, applying per-clip speed and volume.
    static func build(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        webcamTrack: AVAssetTrack? = nil,
        clips: [Clip],
        renderSize: CGSize,
        fps: Int,
        state: RenderState
    ) throws -> Built {
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecutError.message("Could not create the video track.")
        }
        let compAudio = audioTrack.flatMap { _ in
            composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        let compWebcam = webcamTrack.flatMap { _ in
            composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        var cursor = CMTime.zero
        var volumeRanges: [(CMTimeRange, Double)] = []

        for clip in clips where clip.sourceDuration > 0.001 {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                end: CMTime(seconds: clip.sourceEnd, preferredTimescale: 600)
            )
            try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            if let compAudio, let audioTrack {
                try? compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
            }
            if let compWebcam, let webcamTrack {
                // The camera may have started a beat late; pad so the two video
                // tracks stay aligned rather than sliding out of sync.
                let available = CMTimeRangeGetIntersection(
                    range, otherRange: CMTimeRange(start: .zero, duration: webcamTrack.timeRange.end)
                )
                if available.duration.seconds > 0.01 {
                    try? compWebcam.insertTimeRange(available, of: webcamTrack, at: cursor)
                } else {
                    compWebcam.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
                }
            }

            let inserted = CMTimeRange(start: cursor, duration: range.duration)
            let speed = max(0.05, clip.speed)
            var outDuration = range.duration
            if abs(speed - 1) > 0.001 {
                outDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1.0 / speed)
                compVideo.scaleTimeRange(inserted, toDuration: outDuration)
                compAudio?.scaleTimeRange(inserted, toDuration: outDuration)
                compWebcam?.scaleTimeRange(inserted, toDuration: outDuration)
            }
            volumeRanges.append((CMTimeRange(start: cursor, duration: outDuration), clip.volume))
            cursor = cursor + outDuration
        }

        guard cursor.seconds > 0.01 else {
            throw RecutError.message("The timeline is empty — nothing left to play.")
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = RecutCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        videoComposition.instructions = [
            RecutInstruction(
                timeRange: CMTimeRange(start: .zero, duration: cursor),
                trackID: compVideo.trackID,
                webcamTrackID: compWebcam?.trackID,
                state: state
            )
        ]

        var audioMix: AVMutableAudioMix?
        if let compAudio, volumeRanges.contains(where: { abs($0.1 - 1) > 0.001 }) {
            let parameters = AVMutableAudioMixInputParameters(track: compAudio)
            for (range, volume) in volumeRanges {
                // A ramp with the same volume at both ends, rather than
                // setVolume(at:). A bare set point is interpolated *from the
                // previous one*, so two clips at 100% and 25% came out as a
                // six-second fade across the first clip instead of a step at
                // the cut.
                let level = Float(max(0, min(2, volume)))
                parameters.setVolumeRamp(
                    fromStartVolume: level, toEndVolume: level, timeRange: range
                )
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            audioMix = mix
        }

        return Built(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: cursor,
            renderSize: renderSize
        )
    }
}
