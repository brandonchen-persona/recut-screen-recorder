import Foundation
import CoreGraphics

/// The recorded pointer track, resampled onto a fixed grid and smoothed.
///
/// Raw pointer samples are far too twitchy to drive a camera — magnified 3x,
/// a two-pixel jitter becomes a six-pixel shake. The filter below is a
/// forward-then-backward exponential average, which smooths without the phase
/// lag a one-directional filter would introduce (the camera would otherwise
/// always arrive at the click a beat late).
///
/// Also serves the drawn cursor: click times feed the click ring, and the
/// per-sample speed feeds "hide when idle".
final class CursorPath: @unchecked Sendable {
    static let rate: Double = 120

    private let xs: [Double]
    private let ys: [Double]
    /// Seconds since the pointer last moved meaningfully, per grid sample.
    private let stillFor: [Double]
    let clickTimes: [Double]
    let duration: Double
    private let loopToStart: Bool
    /// How long before the end the pointer starts easing home, for a clean loop.
    private let loopTail: Double = 0.9

    static let empty = CursorPath(
        samples: [], clicks: [], duration: 0, timeConstant: 0.22, loopToStart: false
    )

    convenience init(events: [InputEvent], duration: Double, settings: CursorSettings = CursorSettings()) {
        let samples = events
            .filter { $0.kind == .move || $0.kind == .drag }
            .map { (t: $0.t, x: $0.x, y: $0.y) }
        let clicks = events
            .filter { $0.kind == .click || $0.kind == .rightClick }
            .map(\.t)
        self.init(
            samples: samples,
            clicks: clicks,
            duration: duration,
            timeConstant: max(0.01, settings.smoothing),
            loopToStart: settings.loopToStart
        )
    }

    private init(
        samples: [(t: Double, x: Double, y: Double)],
        clicks: [Double],
        duration: Double,
        timeConstant: Double,
        loopToStart: Bool
    ) {
        self.duration = max(0, duration)
        self.clickTimes = clicks.sorted()
        self.loopToStart = loopToStart

        let count = Int((self.duration * Self.rate).rounded()) + 1
        guard count > 1, !samples.isEmpty else {
            xs = [0.5]; ys = [0.5]; stillFor = [0]
            return
        }

        let sorted = samples.sorted { $0.t < $1.t }
        var gx = [Double](repeating: 0.5, count: count)
        var gy = [Double](repeating: 0.5, count: count)

        // Resample onto the uniform grid with linear interpolation.
        var cursor = 0
        for i in 0..<count {
            let t = Double(i) / Self.rate
            while cursor + 1 < sorted.count, sorted[cursor + 1].t <= t { cursor += 1 }
            let a = sorted[cursor]
            if cursor + 1 < sorted.count {
                let b = sorted[cursor + 1]
                let span = b.t - a.t
                let u = span > 1e-6 ? min(max((t - a.t) / span, 0), 1) : 0
                gx[i] = a.x + (b.x - a.x) * u
                gy[i] = a.y + (b.y - a.y) * u
            } else {
                gx[i] = a.x
                gy[i] = a.y
            }
        }

        let alpha = 1 - exp(-1.0 / (Self.rate * max(0.01, timeConstant)))
        Self.smooth(&gx, alpha)
        Self.smooth(&gy, alpha)
        xs = gx
        ys = gy

        // How long the pointer has been parked, used by "hide when idle".
        var still = [Double](repeating: 0, count: count)
        let step = 1.0 / Self.rate
        let moveThreshold = 0.0004
        for i in 1..<count {
            let dx = gx[i] - gx[i - 1]
            let dy = gy[i] - gy[i - 1]
            let moved = (dx * dx + dy * dy).squareRoot()
            still[i] = moved > moveThreshold ? 0 : still[i - 1] + step
        }
        stillFor = still
    }

    private static func smooth(_ v: inout [Double], _ alpha: Double) {
        guard v.count > 1 else { return }
        var acc = v[0]
        for i in v.indices {
            acc += alpha * (v[i] - acc)
            v[i] = acc
        }
        acc = v[v.count - 1]
        for i in stride(from: v.count - 1, through: 0, by: -1) {
            acc += alpha * (v[i] - acc)
            v[i] = acc
        }
    }

    private func index(for t: Double) -> (i: Int, j: Int, u: Double) {
        let f = min(max(t * Self.rate, 0), Double(max(0, xs.count - 1)))
        let i = Int(f)
        return (i, min(i + 1, xs.count - 1), f - Double(i))
    }

    /// Smoothed pointer position at `t`, in normalized top-left-origin coords.
    func position(at t: Double) -> NPoint {
        guard xs.count > 1 else { return NPoint(xs.first ?? 0.5, ys.first ?? 0.5) }
        let (i, j, u) = index(for: t)
        var p = NPoint(xs[i] + (xs[j] - xs[i]) * u, ys[i] + (ys[j] - ys[i]) * u)

        if loopToStart, duration > loopTail, t > duration - loopTail {
            let home = NPoint(xs[0], ys[0])
            let k = CameraSolver.ease((t - (duration - loopTail)) / loopTail)
            p = NPoint(p.x + (home.x - p.x) * k, p.y + (home.y - p.y) * k)
        }
        return p
    }

    /// 0 while the pointer is active, ramping to 1 once it has been parked
    /// longer than `delay`.
    func idleAmount(at t: Double, delay: Double) -> Double {
        guard stillFor.count > 1 else { return 0 }
        let (i, j, u) = index(for: t)
        let still = stillFor[i] + (stillFor[j] - stillFor[i]) * u
        guard still > delay else { return 0 }
        return min(1, (still - delay) / 0.4)
    }

    /// Strength of the click ring at `t`, 1 at the moment of the click and
    /// falling to 0 over `window`.
    func clickPulse(at t: Double, window: Double = 0.42) -> Double {
        guard !clickTimes.isEmpty else { return 0 }
        var best = Double.greatestFiniteMagnitude
        for c in clickTimes {
            if c > t + window { break }
            let d = t - c
            if d >= 0, d < best { best = d }
        }
        guard best < window else { return 0 }
        return 1 - best / window
    }
}
