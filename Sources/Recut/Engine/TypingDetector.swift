import Foundation

/// Finds stretches where the user was typing, so they can be sped up.
///
/// Watching someone type in real time is the dullest part of any demo, and it's
/// the one part where the *result* matters and the journey doesn't.
enum TypingDetector {

    struct Settings {
        /// Keys further apart than this end a run.
        var maxGap: Double = 1.1
        /// Runs shorter than this aren't worth cutting into their own clip.
        var minDuration: Double = 1.2
        var minKeystrokes: Int = 5
        /// Room either side, so the speed change doesn't clip the first letter.
        var padding: Double = 0.25
    }

    /// Source-time ranges that look like typing.
    static func detect(
        events: [InputEvent],
        range: ClosedRange<Double>,
        settings: Settings = Settings()
    ) -> [ClosedRange<Double>] {
        // Only plain characters count. ⌘S is someone driving the app, not
        // writing, and speeding that up helps nobody.
        let keys = events
            .filter { $0.kind == .key && isProse($0.label) && range.contains($0.t) }
            .map(\.t)
            .sorted()
        guard keys.count >= settings.minKeystrokes else { return [] }

        var runs: [[Double]] = []
        var current: [Double] = []
        for t in keys {
            if let last = current.last, t - last > settings.maxGap {
                runs.append(current)
                current = []
            }
            current.append(t)
        }
        if !current.isEmpty { runs.append(current) }

        var result: [ClosedRange<Double>] = []
        for run in runs {
            guard run.count >= settings.minKeystrokes,
                  let first = run.first, let last = run.last,
                  last - first >= settings.minDuration
            else { continue }
            let lower = max(range.lowerBound, first - settings.padding)
            let upper = min(range.upperBound, last + settings.padding)
            guard upper - lower > 0.4 else { continue }

            // Merge with the previous run if padding made them touch.
            if let previous = result.last, lower <= previous.upperBound {
                result[result.count - 1] = previous.lowerBound...max(previous.upperBound, upper)
            } else {
                result.append(lower...upper)
            }
        }
        return result
    }

    /// A label is prose when it carries no command-style modifier.
    private static func isProse(_ label: String?) -> Bool {
        guard let label else { return false }
        return !label.contains("⌘") && !label.contains("⌃") && !label.contains("⌥")
    }

    /// Splits the clip list at `time`, if it falls strictly inside one.
    static func split(_ clips: [Clip], at time: Double) -> [Clip] {
        guard let index = clips.firstIndex(where: {
            time > $0.sourceStart + 0.05 && time < $0.sourceEnd - 0.05
        }) else { return clips }

        var result = clips
        var left = result[index]
        var right = result[index]
        left.sourceEnd = time
        right.id = UUID()
        right.sourceStart = time
        result.replaceSubrange(index...index, with: [left, right])
        return result
    }

    /// Cuts the timeline at every typing boundary and marks the clips between.
    static func apply(
        ranges: [ClosedRange<Double>], to clips: [Clip], speed: Double
    ) -> [Clip] {
        var result = clips
        for range in ranges {
            result = split(result, at: range.lowerBound)
            result = split(result, at: range.upperBound)
        }
        for i in result.indices {
            let inside = ranges.contains {
                result[i].sourceStart >= $0.lowerBound - 0.01
                    && result[i].sourceEnd <= $0.upperBound + 0.01
            }
            if inside {
                result[i].isTyping = true
                result[i].speed = speed
            }
        }
        return result
    }
}
