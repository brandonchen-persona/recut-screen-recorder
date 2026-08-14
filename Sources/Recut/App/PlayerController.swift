import Foundation
import AVFoundation
import Combine
import AppKit

struct LoadedMedia {
    var sourceDuration: Double
    var sourceSize: CGSize
    var transform: CGAffineTransform
    var fps: Int
    var hasAudio: Bool
    var hasWebcam: Bool
}

@MainActor
final class PlayerController: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var currentTime: Double = 0
    /// Length of the edited timeline, not of the source.
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false

    private(set) var media: LoadedMedia?

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var webcamTrack: AVAssetTrack?
    private var timeObserver: Any?
    private var rateObserver: AnyCancellable?
    private var refreshPending = false
    private var refreshJitter = false

    init() {
        player.actionAtItemEnd = .pause
        rateObserver = player.publisher(for: \.rate).sink { [weak self] rate in
            self?.isPlaying = rate != 0
        }
    }

    // MARK: - Loading

    func load(url: URL) async throws -> LoadedMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecutError.message("That file has no video track.")
        }
        let assetDuration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let displaySize = naturalSize.applying(transform)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        // A second video track means the camera was recorded alongside.
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let camera = videoTracks.count > 1 ? videoTracks[1] : nil

        self.asset = asset
        self.videoTrack = track
        self.audioTrack = audio
        self.webcamTrack = camera

        let loaded = LoadedMedia(
            sourceDuration: assetDuration.seconds,
            sourceSize: CGSize(width: abs(displaySize.width), height: abs(displaySize.height)),
            transform: transform,
            fps: max(24, min(60, Int(nominal.rounded()))),
            hasAudio: audio != nil,
            hasWebcam: camera != nil
        )
        media = loaded
        return loaded
    }

    /// Rebuilds the AV composition. Needed whenever the clip list changes —
    /// cuts, removals, speed — but *not* for zoom, background or cursor edits,
    /// which the compositor picks up from the shared render state.
    func rebuild(clips: [Clip], frame: FrameSettings, state: RenderState, quality: PreviewQuality) throws {
        guard let asset, let videoTrack, let media else { return }

        state.update { $0.sourceTransform = media.transform.isIdentity ? .identity : media.transform }

        let renderSize = CompositionBuilder.canvasSize(
            forWidth: CompositionBuilder.previewWidth(
                quality: quality.previewWidth, source: media.sourceSize
            ),
            source: media.sourceSize,
            frame: frame
        )
        let built = try CompositionBuilder.build(
            asset: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            webcamTrack: webcamTrack,
            clips: clips,
            renderSize: renderSize,
            fps: min(quality.previewFPS, media.fps),
            state: state
        )

        let wasPlaying = isPlaying
        let previous = currentTime

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)

        duration = built.duration.seconds

        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 60),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentTime = time.seconds
                }
            }
        }

        seek(to: min(previous, duration))
        if wasPlaying { player.play() }
    }

    func unload() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        asset = nil
        videoTrack = nil
        audioTrack = nil
        webcamTrack = nil
        media = nil
        duration = 0
        currentTime = 0
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if currentTime >= duration - 0.02 { seek(to: 0) }
        player.play()
    }

    func pause() { player.pause() }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), max(0, duration))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func step(by delta: Double) { seek(to: currentTime + delta) }

    /// Forces the compositor to redraw the paused frame after a setting changed.
    ///
    /// AVFoundation will happily reuse the frame it already has for a given
    /// time, so each refresh asks for a time half a millisecond either side of
    /// the playhead — imperceptible, but different enough to invalidate.
    func refresh() {
        guard !isPlaying, !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            refreshPending = false
            refreshJitter.toggle()
            let jitter = refreshJitter ? 0.0005 : 0.0
            let t = min(max(currentTime + jitter, 0), max(0, duration))
            await player.seek(
                to: CMTime(seconds: t, preferredTimescale: 60_000),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        }
    }
}
