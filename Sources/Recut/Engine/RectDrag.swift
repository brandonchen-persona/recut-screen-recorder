import Foundation

/// The arithmetic behind dragging a normalised rectangle around the preview.
///
/// Pulled out of the overlay views so the clamping can be tested: every bug in
/// a drag handle is a boundary bug — a rectangle pushed off the edge, inverted
/// by dragging one corner past the opposite one, or shrunk to nothing and lost.
enum RectDrag {

    /// Corners, named the way a drag gesture needs to ask about them.
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeading: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// Moves `rect` by a normalised delta, keeping it fully inside 0...1.
    ///
    /// The size never changes: a rectangle dragged into a corner stops there
    /// rather than being squashed against it.
    static func moved(_ rect: NRect, dx: Double, dy: Double) -> NRect {
        let width = min(rect.width, 1)
        let height = min(rect.height, 1)
        return NRect(
            min(max(0, rect.x + dx), 1 - width),
            min(max(0, rect.y + dy), 1 - height),
            width, height
        )
    }

    /// Moves one corner by a normalised delta.
    ///
    /// Edges are clamped to the frame and held at least `minSide` apart, so a
    /// corner dragged past its opposite pins instead of turning the rectangle
    /// inside out.
    static func resized(
        _ rect: NRect, corner: Corner, dx: Double, dy: Double, minSide: Double = 0.02
    ) -> NRect {
        let floor = min(max(0.001, minSide), 0.5)

        var left = rect.x
        var top = rect.y
        var right = rect.x + rect.width
        var bottom = rect.y + rect.height

        if corner.isLeading { left += dx } else { right += dx }
        if corner.isTop { top += dy } else { bottom += dy }

        left = min(max(0, left), 1 - floor)
        top = min(max(0, top), 1 - floor)
        right = max(min(1, right), left + floor)
        bottom = max(min(1, bottom), top + floor)
        left = min(left, right - floor)
        top = min(top, bottom - floor)

        return NRect(left, top, right - left, bottom - top)
    }
}
