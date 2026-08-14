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
    static func selectArea() async -> (rect: CGRect, screen: NSScreen)? {
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

    private var origin: NSPoint?
    private var current: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed so a full-screen transparent overlay composites reliably.
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

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

        // Punch the selection out of the dimming.
        NSColor.clear.setFill()
        current.fill(using: .copy)

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: current)
        path.lineWidth = 1.5
        path.stroke()

        let label = "\(Int(current.width)) × \(Int(current.height))"
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
            string: "Drag to choose an area — Esc to cancel", attributes: attrs
        )
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY))
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
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
        if event.keyCode == 53 { onFinish?(nil) } // Esc
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
