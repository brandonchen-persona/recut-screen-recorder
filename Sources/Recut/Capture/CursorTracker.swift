import Foundation
import AppKit

/// Samples the pointer and its clicks/scrolls while a recording runs.
///
/// Clicks are detected by polling `NSEvent.pressedMouseButtons` rather than by
/// installing an event tap: polling needs no Accessibility permission, so
/// auto-zoom works the moment screen recording is allowed. The global monitor
/// is only used for scroll wheel events, which can't be polled.
final class CursorTracker {

    private var events: [InputEvent] = []
    private var timer: Timer?
    private var scrollMonitor: Any?
    private var keyMonitor: Any?

    /// Pixel-space rect of the display being recorded, in AppKit global
    /// coordinates (bottom-left origin).
    private var displayFrame: CGRect = .zero

    private var lastButtons: Int = 0
    private var lastMove: NPoint = .center
    private var lastScrollTime: Double = -1
    private var startTime: Double = 0
    private var pausedAt: Double?
    private var pausedTotal: Double = 0

    /// Sample rate for the pointer path.
    private let sampleInterval: TimeInterval = 1.0 / 60.0
    /// Scroll bursts fire dozens of events per gesture; one every 150 ms is plenty.
    private let scrollThrottle: Double = 0.15

    var isRunning: Bool { timer != nil }

    func start(displayFrame: CGRect, captureKeys: Bool = false) {
        stop()
        self.displayFrame = displayFrame
        events.removeAll()
        lastButtons = NSEvent.pressedMouseButtons
        startTime = CACurrentMediaTime()
        pausedAt = nil
        pausedTotal = 0

        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            self?.recordScroll()
        }

        // Key events need Accessibility; without it the monitor installs but
        // never fires, so there's nothing to fail loudly about here.
        if captureKeys, KeyTracker.isTrusted {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.recordKey(event)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Recording pauses close the gap in the written movie, so the pointer
    /// track has to skip the same interval rather than record through it.
    func pause() {
        guard pausedAt == nil else { return }
        pausedAt = CACurrentMediaTime()
    }

    func resume() {
        guard let pausedAt else { return }
        pausedTotal += CACurrentMediaTime() - pausedAt
        self.pausedAt = nil
    }

    /// Rebases every timestamp so that zero is the first captured video frame,
    /// then hands over the track.
    func finish(timeOrigin: Double) -> [InputEvent] {
        stop()
        let offset = timeOrigin - startTime
        let rebased = events.compactMap { e -> InputEvent? in
            let t = e.t - offset
            guard t >= -0.5 else { return nil }
            var copy = e
            copy.t = max(0, t)
            return copy
        }
        events.removeAll()
        return rebased
    }

    // MARK: - Sampling

    private var isPaused: Bool { pausedAt != nil }

    private func now() -> Double { CACurrentMediaTime() - startTime - pausedTotal }

    private func currentPoint() -> NPoint {
        let p = NSEvent.mouseLocation
        guard displayFrame.width > 0, displayFrame.height > 0 else { return .center }
        let x = (p.x - displayFrame.minX) / displayFrame.width
        // AppKit is bottom-left origin; image space is top-left.
        let y = 1 - (p.y - displayFrame.minY) / displayFrame.height
        return NPoint(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func sample() {
        guard !isPaused else { return }
        let t = now()
        let p = currentPoint()

        let dx = p.x - lastMove.x
        let dy = p.y - lastMove.y
        if events.isEmpty || (dx * dx + dy * dy) > 1e-8 {
            events.append(InputEvent(t: t, kind: .move, x: p.x, y: p.y))
            lastMove = p
        }

        let buttons = NSEvent.pressedMouseButtons
        let pressed = buttons & ~lastButtons
        if pressed & 0x1 != 0 {
            events.append(InputEvent(t: t, kind: .click, x: p.x, y: p.y))
        }
        if pressed & 0x2 != 0 {
            events.append(InputEvent(t: t, kind: .rightClick, x: p.x, y: p.y))
        }
        lastButtons = buttons
    }

    private func recordKey(_ event: NSEvent) {
        guard !isPaused else { return }
        guard let label = KeyTracker.label(for: event) else { return }
        let p = currentPoint()
        events.append(InputEvent(t: now(), kind: .key, x: p.x, y: p.y, label: label))
    }

    private func recordScroll() {
        guard !isPaused else { return }
        let t = now()
        guard t - lastScrollTime >= scrollThrottle else { return }
        lastScrollTime = t
        let p = currentPoint()
        events.append(InputEvent(t: t, kind: .scroll, x: p.x, y: p.y))
    }
}
