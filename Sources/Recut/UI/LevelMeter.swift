import SwiftUI

/// A small segmented input meter.
///
/// Segments rather than a continuous bar: a bar that's slightly wider than a
/// moment ago is hard to read at a glance, whereas "three lit, now five" is
/// obvious out of the corner of an eye while you're talking.
struct LevelMeter: View {
    var level: Double
    var segments: Int = 12
    var width: CGFloat = 3
    var height: CGFloat = 12
    var spacing: CGFloat = 2

    /// Whether the mic is live at all. When it isn't, the meter greys out
    /// rather than sitting at zero looking like silence.
    var isActive: Bool = true

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Double(index) / Double(segments)
                let lit = isActive && level > threshold
                RoundedRectangle(cornerRadius: width / 2)
                    .fill(lit ? colour(for: index) : Color.primary.opacity(0.12))
                    .frame(width: width, height: height)
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(isActive
                            ? "\(Int((level * 100).rounded())) percent"
                            : "No microphone")
    }

    /// Green through most of the range, amber near the top, red at the very
    /// top — the usual convention, so "too hot" needs no explaining.
    private func colour(for index: Int) -> Color {
        let position = Double(index) / Double(segments - 1)
        if position > 0.92 { return .red }
        if position > 0.75 { return .orange }
        return .green
    }
}
