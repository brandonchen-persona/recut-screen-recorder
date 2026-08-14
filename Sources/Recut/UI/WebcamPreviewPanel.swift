import AppKit
import AVFoundation

/// Floating camera preview shown while recording, so you can see how you're
/// framed. It never lands in the capture — the content filter excludes this
/// whole application — which is exactly what Screen Studio does.
@MainActor
final class WebcamPreviewPanel {

    private var panel: NSPanel?

    func show(session: AVCaptureSession) {
        close()

        let side: CGFloat = 180
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = PreviewView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.attach(session: session)
        panel.contentView = view

        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.minX + 32,
                y: screen.frame.minY + 32
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        (panel?.contentView as? PreviewView)?.detach()
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class PreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.cornerRadius = frameRect.width / 2
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        // Mirrored, so it reads like a mirror rather than a stranger.
        previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer.connection?.isVideoMirrored = true
    }

    func detach() {
        previewLayer.session = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        layer?.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }
}
