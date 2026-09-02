import Foundation
import AppKit

/// Samples the pointer and its clicks/scrolls while a recording runs.
///
/// Pointer position and clicks are polled rather than monitored. A global
/// `NSEvent` monitor would carry the exact moment of each click, but monitors
/// need Input Monitoring permission and Recut asks for none — measured with
/// `--clicks`, a mouse-down monitor installs happily and then never fires, so
/// relying on it means capturing no clicks at all.
///
/// What polling has to get right is *when* it polls. Both symptoms reported
/// against the old version came from the sampler living on the main run loop:
///
/// - **Clicks went missing.** A press and release that both land between two
///   ticks is never seen. Main-thread work — writer setup, the controls
///   appearing, a camera preview starting — stretches that gap well past one
///   frame.
/// - **The ones it caught were dated late.** The timestamp came from the tick
///   that noticed the click, so a stalled run loop pushed the event later by
///   however long the stall lasted. Auto-zoom eases in *before* a click so the
///   frame has settled by the time it lands; a click dated a second late
///   produces a zoom a second late.
///
/// So the sampler runs on its own queue at 120 Hz and reads the pointer through
/// Core Graphics, which is safe off the main thread. Nothing the UI does can
/// delay it, and the worst-case dating error is one 8 ms tick.
final class CursorTracker {

    private var events: [InputEvent] = []
    private var timer: DispatchSourceTimer?
    private var scrollMonitor: Any?
    private var keyMonitor: Any?

    /// Guards `events` and the sampling state: the sampler runs off the main
    /// thread while the monitors deliver on it.
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.recut.capture.pointer", qos: .userInteractive)

    /// Captured on the main thread at `start`, so the sampler never touches
    /// AppKit. Core Graphics puts the origin at the top left; AppKit puts it at
    /// the bottom left, and `displayFrame` is in AppKit's.
    private var primaryMaxY: CGFloat = 0

    /// Pixel-space rect of the display being recorded, in AppKit global
    /// coordinates (bottom-left origin).
    private var displayFrame: CGRect = .zero

    private var lastButtons: (left: Bool, right: Bool) = (false, false)
    private var lastMove: NPoint = .center
    private var lastScrollTime: Double = -1
    private var startTime: Double = 0
    private var pausedAt: Double?
    private var pausedTotal: Double = 0

    /// Sample rate for the pointer path and click edges. Twice the frame rate:
    /// the cost is negligible and it halves the window a click can hide in.
    private let sampleInterval: TimeInterval = 1.0 / 120.0
    /// Scroll bursts fire dozens of events per gesture; one every 150 ms is plenty.
    private let scrollThrottle: Double = 0.15

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    func start(displayFrame: CGRect, captureKeys: Bool = false) {
        stop()
        lock.lock()
        self.displayFrame = displayFrame
        self.primaryMaxY = NSScreen.screens.first?.frame.maxY ?? displayFrame.maxY
        events.removeAll()
        startTime = CACurrentMediaTime()
        pausedAt = nil
        pausedTotal = 0
        lastButtons = Self.buttonState()
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: sampleInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        lock.lock(); self.timer = timer; lock.unlock()

        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.recordScroll(event)
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
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Recording pauses close the gap in the written movie, so the pointer
    /// track has to skip the same interval rather than record through it.
    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard pausedAt == nil else { return }
        pausedAt = CACurrentMediaTime()
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard let pausedAt else { return }
        pausedTotal += CACurrentMediaTime() - pausedAt
        self.pausedAt = nil
    }

    /// Rebases every timestamp so that zero is the first captured video frame,
    /// then hands over the track.
    func finish(timeOrigin: Double) -> [InputEvent] {
        stop()
        lock.lock(); defer { lock.unlock() }
        let rebased = Self.rebase(events, startTime: startTime, timeOrigin: timeOrigin)
        events.removeAll()
        return rebased
    }

    /// Shifts tracker time onto video time.
    ///
    /// Tracking starts before the stream does, so the earliest events sit
    /// slightly before the first frame. Those are pulled forward to zero rather
    /// than discarded — a click a fraction before the first frame is a click on
    /// what the first frame shows. Anything more than half a second early is
    /// from before the recording meant anything and is dropped.
    static func rebase(
        _ events: [InputEvent], startTime: Double, timeOrigin: Double
    ) -> [InputEvent] {
        let offset = timeOrigin - startTime
        return events.compactMap { e in
            let t = e.t - offset
            guard t >= -0.5 else { return nil }
            var copy = e
            copy.t = max(0, t)
            return copy
        }
    }

    // MARK: - Sampling

    private func now() -> Double { CACurrentMediaTime() - startTime - pausedTotal }

    /// When an event happened, rather than when we got round to noticing.
    private func time(of event: NSEvent) -> Double {
        event.timestamp - startTime - pausedTotal
    }

    private func currentPoint() -> NPoint {
        let p = NSEvent.mouseLocation
        guard displayFrame.width > 0, displayFrame.height > 0 else { return .center }
        let x = (p.x - displayFrame.minX) / displayFrame.width
        // AppKit is bottom-left origin; image space is top-left.
        let y = 1 - (p.y - displayFrame.minY) / displayFrame.height
        return NPoint(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// Reads the pointer and the mouse buttons through Core Graphics.
    ///
    /// `CGEventSource.buttonState` and `CGEvent(source:)?.location` are safe off
    /// the main thread, which `NSEvent.mouseLocation` and AppKit generally are
    /// not — and being off the main thread is the whole point.
    private static func buttonState() -> (left: Bool, right: Bool) {
        (CGEventSource.buttonState(.combinedSessionState, button: .left),
         CGEventSource.buttonState(.combinedSessionState, button: .right))
    }

    private func sample() {
        lock.lock()
        defer { lock.unlock() }
        guard pausedAt == nil else { return }

        let t = CACurrentMediaTime() - startTime - pausedTotal
        let p = currentPointLocked()

        let dx = p.x - lastMove.x
        let dy = p.y - lastMove.y
        if events.isEmpty || (dx * dx + dy * dy) > 1e-8 {
            events.append(InputEvent(t: t, kind: .move, x: p.x, y: p.y))
            lastMove = p
        }

        let buttons = Self.buttonState()
        if buttons.left, !lastButtons.left {
            events.append(InputEvent(t: t, kind: .click, x: p.x, y: p.y))
        }
        if buttons.right, !lastButtons.right {
            events.append(InputEvent(t: t, kind: .rightClick, x: p.x, y: p.y))
        }
        lastButtons = buttons
    }

    /// The pointer, normalised against the recorded display. Caller holds the
    /// lock.
    private func currentPointLocked() -> NPoint {
        guard displayFrame.width > 0, displayFrame.height > 0,
              let location = CGEvent(source: nil)?.location else { return .center }
        // Core Graphics counts down from the top of the primary display.
        let appKitY = primaryMaxY - location.y
        let x = (location.x - displayFrame.minX) / displayFrame.width
        let y = 1 - (appKitY - displayFrame.minY) / displayFrame.height
        return NPoint(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    // The two monitors below deliver on the main thread while the sampler runs
    // on its own queue, so both take the lock before touching `events`.

    private func recordKey(_ event: NSEvent) {
        guard let label = KeyTracker.label(for: event) else { return }
        let p = currentPoint()
        lock.lock(); defer { lock.unlock() }
        guard pausedAt == nil else { return }
        events.append(InputEvent(t: max(0, time(of: event)), kind: .key,
                                 x: p.x, y: p.y, label: label))
    }

    private func recordScroll(_ event: NSEvent) {
        let p = currentPoint()
        lock.lock(); defer { lock.unlock() }
        guard pausedAt == nil else { return }
        let t = max(0, time(of: event))
        guard t - lastScrollTime >= scrollThrottle else { return }
        lastScrollTime = t
        events.append(InputEvent(t: t, kind: .scroll, x: p.x, y: p.y))
    }
}
