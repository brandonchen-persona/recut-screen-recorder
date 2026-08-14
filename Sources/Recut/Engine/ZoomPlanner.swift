import Foundation

/// Turns raw click/scroll events into a set of zoom segments.
///
/// The shape it aims for is the one that reads well on screen: start moving in
/// *before* the click lands, sit still while the user is working in one place,
/// then pull back out once they leave. So events are first grouped into
/// "bursts" — runs of activity that are close together in both time and space —
/// and each burst becomes one segment.
enum ZoomPlanner {

    static func plan(
        events: [InputEvent],
        settings: AutoZoomSettings,
        range: ClosedRange<Double>
    ) -> [ZoomSegment] {
        guard settings.enabled else { return [] }

        let triggers = events
            .filter { $0.isTrigger && range.contains($0.t) }
            .sorted { $0.t < $1.t }
        guard !triggers.isEmpty else { return [] }

        // 1. Group into bursts.
        var bursts: [[InputEvent]] = []
        var current: [InputEvent] = []
        var centroid = NPoint(0, 0)

        for e in triggers {
            if current.isEmpty {
                current = [e]
                centroid = e.point
                continue
            }
            let gap = e.t - current[current.count - 1].t
            let dx = e.x - centroid.x
            let dy = e.y - centroid.y
            let dist = (dx * dx + dy * dy).squareRoot()

            if gap > settings.clusterGap || dist > settings.clusterRadius {
                bursts.append(current)
                current = [e]
                centroid = e.point
            } else {
                current.append(e)
                let n = Double(current.count)
                centroid = NPoint(
                    centroid.x + (e.x - centroid.x) / n,
                    centroid.y + (e.y - centroid.y) / n
                )
            }
        }
        if !current.isEmpty { bursts.append(current) }

        // 2. One segment per burst.
        var segments: [ZoomSegment] = bursts.compactMap { burst in
            guard let first = burst.first, let last = burst.last else { return nil }

            // Clicks pin the camera harder than scrolls do, so weight them up.
            var wx = 0.0, wy = 0.0, wsum = 0.0
            for e in burst {
                let w: Double = (e.kind == .scroll) ? 0.4 : 1.0
                wx += e.x * w; wy += e.y * w; wsum += w
            }
            let anchor = wsum > 0 ? NPoint(wx / wsum, wy / wsum) : .center

            let hasClick = burst.contains { $0.kind != .scroll }
            let scale = hasClick ? settings.clickScale : settings.scrollScale

            var start = first.t - settings.leadIn
            var end = last.t + settings.hold + settings.easeOut
            if end - start < settings.minDuration {
                let extra = (settings.minDuration - (end - start)) / 2
                start -= extra
                end += extra
            }
            start = max(range.lowerBound, start)
            end = min(range.upperBound, end)
            guard end - start > 0.2 else { return nil }

            return ZoomSegment(
                start: start,
                end: end,
                scale: scale,
                easeIn: settings.leadIn,
                easeOut: settings.easeOut,
                mode: settings.followCursor ? .followCursor : .auto,
                anchor: anchor,
                isManual: false
            )
        }

        // 3. Resolve neighbours that touch or overlap.
        //
        //    Two bursts in the *same* place are really one — fold them together
        //    so the camera doesn't bounce out and straight back in. Two bursts
        //    in *different* places must stay separate, or their anchors average
        //    into a point that isn't interesting; instead their ramps are lined
        //    up so `CameraSolver` pans smoothly from one to the other.
        segments.sort { $0.start < $1.start }
        var resolved: [ZoomSegment] = []

        for var seg in segments {
            guard var prev = resolved.last else { resolved.append(seg); continue }

            let dx = seg.anchor.x - prev.anchor.x
            let dy = seg.anchor.y - prev.anchor.y
            let sameSpot = (dx * dx + dy * dy).squareRoot() <= settings.clusterRadius
            let touching = seg.start - prev.end < 0.45

            if touching && sameSpot {
                let prevWeight = prev.duration
                let segWeight = seg.duration
                let total = max(0.0001, prevWeight + segWeight)
                prev.anchor = NPoint(
                    (prev.anchor.x * prevWeight + seg.anchor.x * segWeight) / total,
                    (prev.anchor.y * prevWeight + seg.anchor.y * segWeight) / total
                )
                prev.end = max(prev.end, seg.end)
                prev.scale = max(prev.scale, seg.scale)
                prev.easeOut = seg.easeOut
                resolved[resolved.count - 1] = prev
                continue
            }

            if touching {
                // Give the two an overlap exactly the length of the ramp they
                // share, which makes the crossfade sum to one throughout.
                // Segments that merely abut are pulled together too — without
                // the overlap the camera would snap all the way out for an
                // instant between them.
                let ramp = max(prev.easeOut, seg.easeIn)
                let mid = (prev.end + seg.start) / 2
                let newPrevEnd = mid + ramp / 2
                let newSegStart = mid - ramp / 2
                if newPrevEnd - prev.start > 0.3 && seg.end - newSegStart > 0.3 {
                    prev.end = newPrevEnd
                    prev.easeOut = ramp
                    seg.start = newSegStart
                    seg.easeIn = ramp
                    resolved[resolved.count - 1] = prev
                } else if seg.end > prev.end {
                    // Too short to be worth keeping apart; absorb it.
                    prev.end = seg.end
                    prev.easeOut = seg.easeOut
                    resolved[resolved.count - 1] = prev
                    continue
                } else {
                    continue
                }
            }
            resolved.append(seg)
        }
        return resolved
    }

    /// Regenerates the automatic segments while leaving hand-made ones alone.
    static func regenerate(in edit: inout EditModel, events: [InputEvent], duration: Double) {
        let manual = edit.segments.filter(\.isManual)
        let span = edit.sourceRange
        let auto = plan(
            events: events,
            settings: edit.autoZoom,
            range: span.lowerBound...max(span.lowerBound + 0.01, min(span.upperBound, duration))
        )
        // Drop generated segments that would collide with something hand-placed.
        let kept = auto.filter { a in
            !manual.contains { m in a.start < m.end && m.start < a.end }
        }
        edit.segments = (manual + kept).sorted { $0.start < $1.start }
    }
}
