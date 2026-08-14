import Foundation
import CoreGraphics

struct Camera {
    /// 1.0 = whole frame visible.
    var scale: Double
    /// Where the camera is pointed, normalized top-left origin.
    var center: NPoint

    static let identity = Camera(scale: 1, center: .center)
}

enum CameraSolver {

    /// Smootherstep. Zero first *and* second derivative at both ends, which is
    /// what keeps the start and end of a zoom from looking like a hinge.
    static func ease(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// How strongly a segment is applied at time `t`, 0...1.
    static func weight(of segment: ZoomSegment, at t: Double) -> Double {
        guard t > segment.start, t < segment.end else { return 0 }
        let (inRamp, outRamp) = segment.effectiveRamps
        if t < segment.start + inRamp {
            return ease((t - segment.start) / inRamp)
        }
        if t > segment.end - outRamp {
            return ease((segment.end - t) / outRamp)
        }
        return 1
    }

    /// Blends every segment active at `t` rather than picking a winner.
    ///
    /// Where two zooms overlap this makes the camera *pan* from one anchor to
    /// the next while staying magnified, instead of dropping all the way out
    /// and diving back in. Smootherstep satisfies `f(1-u) == 1 - f(u)`, so when
    /// one segment's ease-out lines up with the next one's ease-in the weights
    /// sum to exactly 1 and the magnification holds steady through the move.
    /// Pans the camera the minimum needed to keep the pointer on screen.
    ///
    /// Magnified 2x, half the screen is out of frame — a camera parked on the
    /// click that started the zoom loses the cursor as soon as it moves away.
    /// This nudges the centre only once the pointer passes `margin` of the way
    /// to the edge, so a zoom aimed at a fixed spot stays put while the pointer
    /// is near it, and follows once it isn't.
    static func containing(
        cursor: NPoint, center: NPoint, scale: Double, margin: Double = 0.62
    ) -> NPoint {
        guard scale > 1.001 else { return center }
        let limit = (0.5 / scale) * min(max(margin, 0), 1)
        var result = center
        if cursor.x - result.x > limit { result.x = cursor.x - limit }
        if result.x - cursor.x > limit { result.x = cursor.x + limit }
        if cursor.y - result.y > limit { result.y = cursor.y - limit }
        if result.y - cursor.y > limit { result.y = cursor.y + limit }
        return result
    }

    static func camera(
        at t: Double,
        segments: [ZoomSegment],
        cursor: CursorPath,
        keepCursorInFrame: Bool = false
    ) -> Camera {
        var weightSum = 0.0
        var peakSum = 0.0
        var ax = 0.0
        var ay = 0.0

        for seg in segments where seg.isEnabled {
            let w = weight(of: seg, at: t)
            guard w > 0 else { continue }
            let anchor = seg.mode == .followCursor ? cursor.position(at: t) : seg.anchor
            weightSum += w
            peakSum += w * max(1, seg.scale)
            ax += w * anchor.x
            ay += w * anchor.y
        }

        guard weightSum > 0 else { return .identity }

        let peak = peakSum / weightSum
        let strength = min(1, weightSum)
        let scale = 1 + (peak - 1) * strength
        // No blend toward the frame centre is needed: at low magnification the
        // visible rect covers nearly everything and gets clamped there anyway.
        var center = NPoint(ax / weightSum, ay / weightSum)

        if keepCursorInFrame {
            center = containing(cursor: cursor.position(at: t), center: center, scale: scale)
        }
        return Camera(scale: scale, center: center)
    }

    /// The rect the camera sees inside `bounds` (already-cropped source pixels),
    /// clamped so it never runs off the edge. Core Image's bottom-left origin.
    ///
    /// `aspect`, when set, narrows the view to that width/height ratio — this is
    /// what "always keep zoomed in" uses to fill a vertical frame instead of
    /// letterboxing it.
    static func visibleRect(camera: Camera, bounds: CGRect, aspect: Double? = nil) -> CGRect {
        let s = max(1, camera.scale)
        var w = bounds.width / s
        var h = bounds.height / s

        if let aspect, aspect > 0 {
            if w / h > aspect {
                w = h * aspect
            } else {
                h = w / aspect
            }
        }
        w = min(w, bounds.width)
        h = min(h, bounds.height)

        let cx = bounds.minX + camera.center.x * bounds.width
        let cy = bounds.minY + (1 - camera.center.y) * bounds.height
        let x = min(max(cx - w / 2, bounds.minX), max(bounds.minX, bounds.maxX - w))
        let y = min(max(cy - h / 2, bounds.minY), max(bounds.minY, bounds.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
