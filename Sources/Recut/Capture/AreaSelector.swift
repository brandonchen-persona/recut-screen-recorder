import AppKit
import SwiftUI

/// Full-screen overlay for dragging out a capture region, plus the countdown
/// that runs just before recording starts. Both are borderless panels above
/// everything else; neither ends up in the recording, because the content
/// filter excludes this whole application.
@MainActor
enum ScreenOverlay {

    // MARK: - Area selection

    /// Covers *every* display and returns the region dragged out on whichever
    /// one you used, in that display's points with a top-left origin — the
    /// coordinates `SCStreamConfiguration.sourceRect` takes.
    ///
    /// Putting a panel on one display only meant an external monitor couldn't
    /// be selected at all, since the Area controls carry no display picker.
    /// - Parameter fixedPixelSize: when set, the overlay offers a box of exactly
    ///   this capture resolution to position rather than a free drag. The box is
    ///   sized per display, so the same request records the same pixels on a 1×
    ///   monitor and a 2× one.
    static func selectArea(
        fixedPixelSize: CGSize? = nil
    ) async -> (rect: CGRect, screen: NSScreen)? {
        await withCheckedContinuation { continuation in
            var resumed = false
            var panels: [NSPanel] = []

            let finish: ((rect: CGRect, screen: NSScreen)?) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                for panel in panels { panel.orderOut(nil) }
                panels.removeAll()
                continuation.resume(returning: result)
            }

            let pointer = NSEvent.mouseLocation

            for screen in NSScreen.screens {
                // Deliberately *not* a non-activating panel. The selector has
                // to take over the screen: a non-activating panel never becomes
                // key, so Esc wouldn't reach it, and its first click would be
                // spent activating the app instead of starting the drag.
                let panel = SelectionPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                // Verified empirically: at `.screenSaver` these panels report
                // isVisible == true but never composite, on this machine at
                // least. `.floating` renders reliably. It sits below the menu
                // bar, which is a fair trade for actually being on screen.
                panel.level = .floating
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

                let view = AreaSelectionView(
                    frame: NSRect(origin: .zero, size: screen.frame.size)
                )
                if let fixedPixelSize {
                    view.fixedBox = AreaGeometry.boxSize(
                        forPixels: fixedPixelSize,
                        scale: screen.backingScaleFactor,
                        screen: screen.frame.size
                    )
                    view.fixedPixels = fixedPixelSize
                    view.pointScale = screen.backingScaleFactor
                }
                view.onFinish = { rect in
                    guard let rect, rect.width > 8, rect.height > 8 else {
                        finish(nil)
                        return
                    }
                    finish((
                        AreaGeometry.sourceRect(
                            fromView: rect, screenHeight: screen.frame.height
                        ),
                        screen
                    ))
                }
                panel.contentView = view
                panel.setFrameOrigin(screen.frame.origin)
                panel.orderFrontRegardless()
                panels.append(panel)

                // Key goes to the display the pointer is already on, so Esc
                // works without having to click first.
                if screen.frame.contains(pointer) {
                    panel.makeKeyAndOrderFront(nil)
                    panel.makeFirstResponder(view)
                }
            }

            if panels.isEmpty {
                finish(nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if !panels.contains(where: { $0.isKeyWindow }) {
                panels[0].makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Countdown

    static func countdown(from seconds: Int, on screen: NSScreen?) async {
        guard seconds > 0 else { return }
        let target = screen ?? NSScreen.main ?? NSScreen.screens[0]

        let size = CGSize(width: 220, height: 220)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrameOrigin(NSPoint(
            x: target.frame.midX - size.width / 2,
            y: target.frame.midY - size.height / 2
        ))

        let model = CountdownModel(value: seconds)
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()

        for remaining in stride(from: seconds, through: 1, by: -1) {
            model.value = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        panel.orderOut(nil)
    }
}

/// Converting between the selector's coordinates and ScreenCaptureKit's.
///
/// Pulled out of the view so the geometry can be tested — the drag itself
/// can't be, but getting the flip wrong is the easy mistake.
enum AreaGeometry {

    /// View coordinates are bottom-left origin; `SCStreamConfiguration.sourceRect`
    /// is top-left origin relative to the display.
    static func sourceRect(fromView rect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX.rounded(),
            y: (screenHeight - rect.maxY).rounded(),
            width: rect.width.rounded(),
            height: rect.height.rounded()
        )
    }

    /// The inverse, for drawing the recording highlight back onto the screen.
    static func viewRect(fromSource rect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: screenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The on-screen box, in points, that records at `pixels`.
    ///
    /// Capture resolution is the region's point size multiplied by the display's
    /// backing scale, so a 1080p capture is 960×540pt on a 2× display and
    /// 1920×1080pt on a 1× one. Sizing the box this way is what makes a preset
    /// mean the same output file whichever monitor it lands on.
    ///
    /// A box that cannot fit is scaled down rather than refused: an oversized
    /// region would be clipped by the display bounds anyway, and shrinking it
    /// keeps the aspect ratio the preset was chosen for.
    static func boxSize(forPixels pixels: CGSize, scale: CGFloat, screen: CGSize) -> CGSize {
        let scale = max(1, scale)
        var w = max(2, pixels.width / scale)
        var h = max(2, pixels.height / scale)

        let shrink = min(1, min(screen.width / w, screen.height / h))
        if shrink < 1 {
            w *= shrink
            h *= shrink
        }
        // Even point sizes keep the pixel size even too, which the encoders
        // require, and stop the box shimmering by a pixel as it moves.
        return CGSize(
            width: max(2, (w / 2).rounded() * 2),
            height: max(2, (h / 2).rounded() * 2)
        )
    }

    /// Places a fixed box centred on the pointer, held fully inside the display.
    ///
    /// Without the clamp the box would hang off the edge as the pointer nears
    /// it, and `SCStreamConfiguration.sourceRect` would be asked for pixels the
    /// display doesn't have.
    static func clampedRect(size: CGSize, centeredOn point: CGPoint, in screen: CGSize) -> CGRect {
        let x = (point.x - size.width / 2)
            .clamped(to: 0...max(0, screen.width - size.width))
        let y = (point.y - size.height / 2)
            .clamped(to: 0...max(0, screen.height - size.height))
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Selection view

/// A borderless `NSPanel` refuses key status by default, which would swallow
/// the Esc key.
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AreaSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    /// Size of the box to position, in points. Nil means the free-drag mode.
    var fixedBox: CGSize?
    /// What that box records, for the readout. Nil in free-drag mode.
    var fixedPixels: CGSize?
    /// The display's backing scale, so the readout can show both numbers.
    var pointScale: CGFloat = 1

    private var origin: NSPoint?
    private var current: NSRect = .zero
    /// Set once the pointer has been seen, so the box doesn't flash at the
    /// origin before the first mouse move.
    private var hasPlacedBox = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed so a full-screen transparent overlay composites reliably.
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Mouse-moved events are off by default; the fixed box follows the pointer
    /// without any button held, so it needs them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard fixedBox != nil, let window else { return }
        window.acceptsMouseMovedEvents = true
        // Show the box where the pointer already is rather than waiting for the
        // first move, which otherwise leaves the screen looking inert.
        let inWindow = window.mouseLocationOutsideOfEventStream
        if bounds.contains(convert(inWindow, from: nil)) {
            moveBox(to: convert(inWindow, from: nil))
        }
    }

    /// Only the key window gets `mouseMoved` by default, so on a second display
    /// the box would sit frozen until clicked. An `.activeAlways` tracking area
    /// delivers moves to every panel, letting the box follow the pointer across
    /// monitors — and `mouseExited` takes it off the ones being left behind, so
    /// there is never more than one box on screen.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard fixedBox != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    /// Key status follows the pointer so Esc and the arrow keys always act on
    /// the display the box is actually on.
    override func mouseEntered(with event: NSEvent) {
        guard fixedBox != nil, let window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        guard fixedBox != nil else { return }
        current = .zero
        hasPlacedBox = false
        needsDisplay = true
    }

    /// Centres the fixed box on a point, kept fully on screen.
    private func moveBox(to point: NSPoint) {
        guard let fixedBox else { return }
        current = AreaGeometry.clampedRect(
            size: fixedBox, centeredOn: point, in: bounds.size
        )
        hasPlacedBox = true
        needsDisplay = true
    }

    /// Without this the first click is consumed activating the window and
    /// never reaches `mouseDown`, so the drag never starts — which looked
    /// exactly like the selector ignoring the mouse.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard current.width > 1, current.height > 1 else {
            drawHint()
            return
        }

        // The fixed box keeps its instructions on screen: unlike a drag, which
        // is over as soon as the button comes up, placing a box is a state you
        // can sit in, nudging, and the keys are worth repeating.
        if fixedBox != nil { drawHint() }

        // Punch the selection out of the dimming.
        NSColor.clear.setFill()
        current.fill(using: .copy)

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: current)
        path.lineWidth = 1.5
        path.stroke()

        let label: String
        if let fixedPixels {
            // The points the box covers are rarely the numbers the user typed,
            // so show what actually gets recorded and keep the on-screen size
            // as the secondary figure.
            label = "\(Int(fixedPixels.width)) × \(Int(fixedPixels.height)) px"
                + "  ·  \(Int(current.width)) × \(Int(current.height)) pt"
        } else {
            label = "\(Int(current.width)) × \(Int(current.height))"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let textSize = text.size()
        let box = NSRect(
            x: current.midX - textSize.width / 2 - 6,
            y: current.minY - textSize.height - 10,
            width: textSize.width + 12,
            height: textSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private func drawHint() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let text = NSAttributedString(
            string: fixedBox == nil
                ? "Drag to choose an area — Esc to cancel"
                : "Move the box, click to place — arrows nudge, Esc to cancel",
            attributes: attrs
        )
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY))
    }

    override func mouseMoved(with event: NSEvent) {
        guard fixedBox != nil else { return }
        moveBox(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard fixedBox == nil else {
            // In fixed mode a press starts a drag of the whole box, and a click
            // without movement confirms it on mouseUp.
            moveBox(to: convert(event.locationInWindow, from: nil))
            return
        }
        origin = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard fixedBox == nil else {
            moveBox(to: point)
            return
        }
        guard let origin else { return }
        current = NSRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(current)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onFinish?(nil)
        case 36, 76: // Return, Enter
            guard fixedBox != nil, hasPlacedBox else { return }
            onFinish?(current)
        case 123, 124, 125, 126: // ←, →, ↓, ↑
            nudge(event)
        default:
            break
        }
    }

    /// Arrow keys move a fixed box a point at a time, Shift by ten — the only
    /// way to land it exactly when the pointer keeps rounding to whole points.
    private func nudge(_ event: NSEvent) {
        guard fixedBox != nil, hasPlacedBox else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var delta = CGPoint.zero
        switch event.keyCode {
        case 123: delta.x = -step
        case 124: delta.x = step
        case 125: delta.y = -step
        case 126: delta.y = step
        default: return
        }
        moveBox(to: CGPoint(x: current.midX + delta.x, y: current.midY + delta.y))
    }
}

// MARK: - Countdown view

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.72))
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 2)
            Text("\(model.value)")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: model.value)
        }
        .frame(width: 220, height: 220)
    }
}
