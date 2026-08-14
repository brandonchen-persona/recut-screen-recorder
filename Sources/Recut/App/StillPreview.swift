import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import Metal

/// Draws the paused preview frame directly, instead of nudging `AVPlayer` and
/// letting it redraw.
///
/// Asking the player to re-render a paused frame means an exact seek, and an
/// exact seek on a composition with a custom compositor costs ~107 ms — it has
/// to decode from the previous keyframe and composite forward. Compositing one
/// frame costs ~4 ms. So while the playhead is parked, the source frame is
/// decoded once and cached, and moving a slider re-composites only that frame.
/// Dragging padding went from roughly 9 fps to the renderer's own speed.
@MainActor
final class StillPreview: ObservableObject {

    /// The composited frame to show over the player while it's paused.
    @Published private(set) var image: CGImage?

    private let renderer = FrameRenderer()
    private let context: CIContext
    private var generator: AVAssetImageGenerator?
    /// Only the screen track; a webcam track needs its own generator because
    /// `AVAssetImageGenerator` always takes the first video track of an asset.
    private var webcamGenerator: AVAssetImageGenerator?

    private var cachedSourceTime: Double = .nan
    private var cachedSource: CIImage?
    private var cachedWebcam: CIImage?
    private var renderTask: Task<Void, Never>?

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    // MARK: - Loading

    func load(project: Project) async {
        clear()
        let asset = AVURLAsset(url: project.videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.generator = generator

        // A second video track means the camera rode along with the screen.
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              tracks.count > 1 else { return }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ), let duration = try? await asset.load(.duration) else { return }
        try? track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: tracks[1], at: .zero
        )
        let webcamGenerator = AVAssetImageGenerator(asset: composition)
        webcamGenerator.requestedTimeToleranceBefore = .zero
        webcamGenerator.requestedTimeToleranceAfter = .zero
        self.webcamGenerator = webcamGenerator
    }

    func clear() {
        renderTask?.cancel()
        renderTask = nil
        generator = nil
        webcamGenerator = nil
        cachedSource = nil
        cachedWebcam = nil
        cachedSourceTime = .nan
        image = nil
    }

    /// Hides the still so the player shows through — call when playback starts.
    func hide() {
        renderTask?.cancel()
        renderTask = nil
        image = nil
    }

    // MARK: - Rendering

    /// Re-composites the paused frame. Decoding only happens when the playhead
    /// has actually moved; a settings change reuses the cached source frame.
    func update(sourceTime: Double, snapshot: RenderSnapshot, canvasSize: CGSize) {
        guard let generator, canvasSize.width > 1 else { return }

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }

            let needsDecode = cachedSource == nil
                || abs(cachedSourceTime - sourceTime) > 0.004
            if needsDecode {
                let time = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
                let decoded = try? await generator.image(at: time).image
                guard !Task.isCancelled else { return }
                if let decoded {
                    cachedSource = CIImage(cgImage: decoded)
                    cachedSourceTime = sourceTime
                    cachedWebcam = (try? await webcamGenerator?.image(at: time).image)
                        .flatMap { $0 }
                        .map { CIImage(cgImage: $0) }
                }
            }
            guard !Task.isCancelled, let source = cachedSource else { return }

            // The generator has already applied the track's transform.
            var snapshot = snapshot
            snapshot.sourceTransform = .identity

            let canvas = CGRect(origin: .zero, size: canvasSize)
            let composed = renderer.render(
                source: source,
                canvas: canvas,
                sourceTime: sourceTime,
                snapshot: snapshot,
                webcam: snapshot.webcam.enabled ? cachedWebcam : nil
            )
            guard !Task.isCancelled,
                  let output = context.createCGImage(composed, from: canvas) else { return }
            image = output
        }
    }

    /// Composites one frame at full output size, for "Save frame as image".
    ///
    /// Deliberately separate from `update`: that one renders at preview size
    /// and reuses a cached decode, and a still meant for a slide wants the real
    /// canvas, decoded fresh.
    func renderStill(
        sourceTime: Double, snapshot: RenderSnapshot, canvasSize: CGSize
    ) async -> CGImage? {
        guard let generator, canvasSize.width > 1 else { return nil }
        let time = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
        guard let decoded = try? await generator.image(at: time).image else { return nil }
        let webcamFrame = (try? await webcamGenerator?.image(at: time).image)
            .flatMap { $0 }
            .map { CIImage(cgImage: $0) }

        var snapshot = snapshot
        snapshot.sourceTransform = .identity
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let composed = renderer.render(
            source: CIImage(cgImage: decoded),
            canvas: canvas,
            sourceTime: sourceTime,
            snapshot: snapshot,
            webcam: snapshot.webcam.enabled ? webcamFrame : nil
        )
        return context.createCGImage(composed, from: canvas)
    }
}
