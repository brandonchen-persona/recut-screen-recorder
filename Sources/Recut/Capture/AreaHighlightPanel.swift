import AppKit

/// Dims everything outside the capture region while an area recording runs, so
/// you can see exactly what's being recorded without guessing at the bounds.
///
/// Click-through, and never part of the output: the content filter excludes
/// this whole application, so the dimming is only ever on your screen.
@MainActor
final class AreaHighlightPanel {

    private var panel: NSPanel?

    /// `rect` is in display points with a top-left origin — the same
    /// coordinates `SCStreamConfiguration.sourceRect` takes.
    func show(rect: CGRect, on screen: NSScreen) {
        close()

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above ordinary windows but below the recording HUD, and invisible to
        // the mouse so it can't get in the way of whatever is being recorded.
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = HighlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.cutout = AreaGeometry.viewRect(
            fromSource: rect, screenHeight: screen.frame.height
        )
        panel.contentView = view
        panel.setFrameOrigin(screen.frame.origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Amber border while paused, so a paused recording doesn't look live.
    func setPaused(_ paused: Bool) {
        guard let view = panel?.contentView as? HighlightView else { return }
        view.isPaused = paused
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class HighlightView: NSView {

    var cutout: CGRect = .zero { didSet { needsDisplay = true } }
    var isPaused = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim everything, then punch the recorded region back out.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(bounds)
        ctx.setBlendMode(.copy)
        ctx.setFillColor(NSColor.clear.cgColor)
        ctx.fill(cutout)
        ctx.setBlendMode(.normal)

        let accent = isPaused
            ? NSColor.systemOrange
            : NSColor.systemRed
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(cutout.insetBy(dx: -1, dy: -1))

        // Corner ticks, which read as a viewfinder rather than a selection.
        let tick: CGFloat = min(26, min(cutout.width, cutout.height) / 4)
        ctx.setLineWidth(4)
        ctx.setStrokeColor(accent.cgColor)
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: cutout.minX, y: cutout.minY + tick),
             CGPoint(x: cutout.minX, y: cutout.minY),
             CGPoint(x: cutout.minX + tick, y: cutout.minY)),
            (CGPoint(x: cutout.maxX - tick, y: cutout.minY),
             CGPoint(x: cutout.maxX, y: cutout.minY),
             CGPoint(x: cutout.maxX, y: cutout.minY + tick)),
            (CGPoint(x: cutout.maxX, y: cutout.maxY - tick),
             CGPoint(x: cutout.maxX, y: cutout.maxY),
             CGPoint(x: cutout.maxX - tick, y: cutout.maxY)),
            (CGPoint(x: cutout.minX + tick, y: cutout.maxY),
             CGPoint(x: cutout.minX, y: cutout.maxY),
             CGPoint(x: cutout.minX, y: cutout.maxY - tick)),
        ]
        for (a, b, c) in corners {
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.addLine(to: c)
            ctx.strokePath()
        }

        let label = isPaused ? "Paused" : "Recording"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let box = CGRect(
            x: cutout.minX,
            y: cutout.maxY + 8,
            width: size.width + 16,
            height: size.height + 8
        )
        if box.maxY < bounds.maxY {
            ctx.setFillColor(accent.withAlphaComponent(0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2,
                               cornerHeight: box.height / 2, transform: nil))
            ctx.fillPath()
            text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4))
        }
    }
}
