import SwiftUI

/// Drag-to-place rectangle for a mask or highlight, drawn over the preview.
///
/// Positioning a blur by typing percentages into four sliders means looking at
/// the numbers rather than at the thing being covered — and a blur that misses
/// is worse than no blur at all. Like `CropOverlay` this is shown over an
/// *unzoomed, uncropped* preview (`RenderSnapshot.previewFullFrame`), because
/// masks are stored against the full source frame; without that a zoom in force
/// at the playhead would put the outline somewhere other than the blur.
struct MaskOverlay: View {
    @Binding var mask: MaskRegion
    /// width / height of the exported canvas.
    let canvasAspect: Double
    /// width / height of the full source frame.
    let contentAspect: Double
    /// Fraction of the canvas' smaller side used as padding.
    let padding: Double
    /// False when the playhead sits outside the mask's own span, where the
    /// effect isn't on screen to line the rectangle up against.
    let isActiveNow: Bool

    private let handle: CGFloat = 12
    /// Keeps a mask from being dragged down to nothing and lost.
    private let minSide: Double = 0.02

    @State private var dragStart: NRect?

    private var tint: Color { mask.kind == .highlight ? .yellow : .teal }

    var body: some View {
        GeometryReader { geo in
            let content = CropOverlay.contentRect(
                container: geo.size,
                canvasAspect: canvasAspect,
                contentAspect: contentAspect,
                padding: padding
            )
            let rect = CGRect(
                x: content.minX + CGFloat(mask.rect.x) * content.width,
                y: content.minY + CGFloat(mask.rect.y) * content.height,
                width: CGFloat(mask.rect.width) * content.width,
                height: CGFloat(mask.rect.height) * content.height
            )

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(tint, lineWidth: 2)
                    .background(Rectangle().fill(tint.opacity(isActiveNow ? 0.10 : 0.04)))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                // Body drag moves the whole rectangle.
                Color.white.opacity(0.001)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    // Global space on purpose. `DragGesture` reports
                    // `translation` in the space of the view it is attached to,
                    // and these views are moved *by* the drag — so measuring
                    // locally feeds each frame's movement into the next event
                    // and the rectangle bolts across the frame instead of
                    // following the pointer.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let base = dragStart ?? mask.rect
                            dragStart = base
                            move(by: value.translation, in: content, from: base)
                        }
                        .onEnded { _ in dragStart = nil })
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .accessibilityLabel("\(mask.kind.label) area")
                    .accessibilityHint("Drag to move. Use the inspector sliders for exact values.")

                ForEach(RectDrag.Corner.allCases, id: \.self) { corner in
                    let point = corner.position(in: rect)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(tint, lineWidth: 2))
                        .frame(width: handle, height: handle)
                        .offset(x: point.x - handle / 2, y: point.y - handle / 2)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStart ?? mask.rect
                                dragStart = base
                                resize(corner, by: value.translation,
                                       in: content, from: base)
                            }
                            .onEnded { _ in dragStart = nil })
                        .onHover { inside in
                            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                }

                label(rect: rect, content: content)
            }
        }
    }

    private func label(rect: CGRect, content: CGRect) -> some View {
        // Above the rectangle normally, tucked inside when it's near the top.
        let above = rect.minY - 24 > content.minY
        return HStack(spacing: 5) {
            Image(systemName: mask.kind == .highlight ? "flashlight.on.fill" : "eye.slash")
            Text(isActiveNow
                 ? mask.kind.label
                 : "\(mask.kind.label) — not shown at the playhead")
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.white)
        .fixedSize()
        .offset(x: rect.minX, y: above ? rect.minY - 24 : rect.minY + 6)
        .allowsHitTesting(false)
    }

    private func move(by translation: CGSize, in content: CGRect, from base: NRect) {
        guard content.width > 0, content.height > 0 else { return }
        mask.rect = RectDrag.moved(
            base,
            dx: Double(translation.width / content.width),
            dy: Double(translation.height / content.height)
        )
    }

    private func resize(
        _ corner: RectDrag.Corner, by translation: CGSize, in content: CGRect, from base: NRect
    ) {
        guard content.width > 0, content.height > 0 else { return }
        mask.rect = RectDrag.resized(
            base,
            corner: corner,
            dx: Double(translation.width / content.width),
            dy: Double(translation.height / content.height),
            minSide: minSide
        )
    }
}

private extension RectDrag.Corner {
    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}
