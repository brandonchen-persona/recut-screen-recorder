import Foundation

/// Maps between timeline time (what the playhead shows, after cuts and speed
/// changes) and source time (where things live in the original recording).
///
/// Zooms, masks and the cursor track are all stored in source time, so cutting
/// a section out takes its zooms with it and speeding a clip up speeds its
/// zooms up too — no re-timing needed anywhere else.
struct Timeline: Sendable {

    struct Entry: Sendable {
        var clipID: UUID
        var sourceStart: Double
        var sourceEnd: Double
        var speed: Double
        var volume: Double
        var outputStart: Double
        var outputEnd: Double

        var outputDuration: Double { outputEnd - outputStart }
    }

    private(set) var entries: [Entry] = []
    private(set) var duration: Double = 0

    static let empty = Timeline()

    init() {}

    init(clips: [Clip]) {
        var cursor = 0.0
        for clip in clips where clip.sourceDuration > 0.001 {
            let out = clip.outputDuration
            entries.append(Entry(
                clipID: clip.id,
                sourceStart: clip.sourceStart,
                sourceEnd: clip.sourceEnd,
                speed: max(0.05, clip.speed),
                volume: clip.volume,
                outputStart: cursor,
                outputEnd: cursor + out
            ))
            cursor += out
        }
        duration = cursor
    }

    var isEmpty: Bool { entries.isEmpty }

    func entry(atOutput t: Double) -> Entry? {
        guard !entries.isEmpty else { return nil }
        if t <= entries[0].outputStart { return entries[0] }
        // Linear scan: a timeline with enough cuts for this to matter would be
        // unusual, and it keeps the mapping obvious.
        for e in entries where t < e.outputEnd { return e }
        return entries.last
    }

    /// Timeline time → source time.
    func sourceTime(at t: Double) -> Double {
        guard let e = entry(atOutput: t) else { return t }
        let local = min(max(t - e.outputStart, 0), e.outputDuration)
        return min(e.sourceStart + local * e.speed, e.sourceEnd)
    }

    /// Source time → timeline time, if that moment survived the cuts.
    func outputTime(forSource s: Double) -> Double? {
        for e in entries where s >= e.sourceStart && s <= e.sourceEnd {
            return e.outputStart + (s - e.sourceStart) / e.speed
        }
        return nil
    }

    /// Source time → timeline time, snapping to the nearest surviving moment.
    func nearestOutputTime(forSource s: Double) -> Double {
        if let exact = outputTime(forSource: s) { return exact }
        guard let first = entries.first, let last = entries.last else { return 0 }
        if s < first.sourceStart { return 0 }
        if s > last.sourceEnd { return duration }
        // Landed in a removed gap — snap to the start of the next surviving clip.
        for e in entries where s < e.sourceStart { return e.outputStart }
        return duration
    }

    /// The timeline spans covered by a source range, one per clip it crosses.
    func outputRanges(forSource range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for e in entries {
            let lo = max(range.lowerBound, e.sourceStart)
            let hi = min(range.upperBound, e.sourceEnd)
            guard hi > lo else { continue }
            let a = e.outputStart + (lo - e.sourceStart) / e.speed
            let b = e.outputStart + (hi - e.sourceStart) / e.speed
            if b > a { result.append(a...b) }
        }
        return result
    }
}
