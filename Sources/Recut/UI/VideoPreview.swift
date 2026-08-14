import SwiftUI
import AVFoundation
import AppKit

/// Hosts an `AVPlayerLayer`, which shows the output of our custom compositor —
/// so the preview and the export are literally the same pixels.
struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer
    /// Shown over the player while paused — see `StillPreview` for why the
    /// paused frame is drawn directly rather than seeking the player.
    var still: CGImage?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.setStill(still)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.setStill(still)
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    private let stillLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        layer?.addSublayer(stillLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStill(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.contents = image
        stillLayer.isHidden = image == nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillLayer.frame = bounds
        CATransaction.commit()
    }
}
