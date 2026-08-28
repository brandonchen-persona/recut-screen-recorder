import SwiftUI

/// Draggable crop rectangle drawn over the preview.
///
/// While the tool is open the compositor shows the *uncropped* frame (see
/// `RenderSnapshot.previewFullFrame`), so the rectangle maps one-to-one onto
/// what's on screen instead of cropping relative to an already-cropped image.
struct CropOverlay: View {
    @Binding var crop: NRect
    /// width / height of the exported canvas.
    let canvasAspect: Double
    /// width / height of the full source frame.
    let contentAspect: Double
    /// Fraction of the canvas' smaller side used as padding.
    let padding: Double

    private let handle: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let canvas = Self.fit(aspect: canvasAspect, in: CGRect(origin: .zero, size: geo.size))
            let inset = padding * Double(min(canvas.width, canvas.height))
            let content = Self.fit(
                aspect: contentAspect,
                in: canvas.insetBy(dx: CGFloat(inset), dy: CGFloat(inset))
            )
            let rect = CGRect(
                x: content.minX + CGFloat(crop.x) * content.width,
                y: content.minY + CGFloat(crop.y) * content.height,
                width: CGFloat(crop.width) * content.width,
                height: CGFloat(crop.height) * content.height
            )

            ZStack(alignment: .topLeading) {
                // Dim everything outside the crop.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                thirds(rect: rect)

                // Body drag moves the whole rectangle.
                Color.white.opacity(0.001)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    // Global space: `translation` reported in a moving view's
                    // own space folds each frame's movement back into the next
                    // event, so the rectangle accelerates away from the pointer.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let base = dragStart ?? crop
                            dragStart = base
                            move(by: value.translation, in: content, from: base)
                        }
                        .onEnded { _ in dragStart = nil })

                ForEach(Corner.allCases, id: \.self) { corner in
                    corner.position(in: rect)
                        .map { point in
                            Circle()
                                .fill(Color.white)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.35)))
                                .frame(width: handle, height: handle)
                                .offset(x: point.x - handle / 2, y: point.y - handle / 2)
                                .gesture(DragGesture(minimumDistance: 0,
                                                     coordinateSpace: .global)
                                    .onChanged { value in
                                        let base = dragStart ?? crop
                                        dragStart = base
                                        resize(corner, by: value.translation,
                                               in: content, from: base)
                                    }
                                    .onEnded { _ in dragStart = nil })
                        }
                }

                Text(String(format: "%.0f%% × %.0f%%", crop.width * 100, crop.height * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .offset(x: rect.minX + 6, y: rect.minY + 6)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var dragStart: NRect?

    private func thirds(rect: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: rect.minY))
                p.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: rect.minX, y: y))
                p.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private func move(by translation: CGSize, in content: CGRect, from base: NRect) {
        guard content.width > 0, content.height > 0 else { return }
        let dx = Double(translation.width / content.width)
        let dy = Double(translation.height / content.height)
        crop = NRect(
            min(max(0, base.x + dx), 1 - base.width),
            min(max(0, base.y + dy), 1 - base.height),
            base.width, base.height
        )
    }

    private func resize(_ corner: Corner, by translation: CGSize, in content: CGRect, from base: NRect) {
        guard content.width > 0, content.height > 0 else { return }
        let dx = Double(translation.width / content.width)
        let dy = Double(translation.height / content.height)

        var left = base.x
        var top = base.y
        var right = base.x + base.width
        var bottom = base.y + base.height

        if corner.isLeading { left += dx } else { right += dx }
        if corner.isTop { top += dy } else { bottom += dy }

        left = min(max(0, left), right - 0.03)
        top = min(max(0, top), bottom - 0.03)
        right = max(min(1, right), left + 0.03)
        bottom = max(min(1, bottom), top + 0.03)

        crop = NRect(left, top, right - left, bottom - top)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeading: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }

        func position(in rect: CGRect) -> CGPoint? {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    /// The rect the recording occupies inside the preview, accounting for the
    /// player's letterboxing and the background padding.
    static func contentRect(
        container: CGSize, canvasAspect: Double, contentAspect: Double, padding: Double
    ) -> CGRect {
        let canvas = fit(aspect: canvasAspect, in: CGRect(origin: .zero, size: container))
        let inset = CGFloat(padding) * min(canvas.width, canvas.height)
        return fit(aspect: contentAspect, in: canvas.insetBy(dx: inset, dy: inset))
    }

    /// Aspect-fit, matching `AVPlayerLayer`'s `.resizeAspect`.
    static func fit(aspect: Double, in rect: CGRect) -> CGRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return rect }
        let containerAspect = Double(rect.width / rect.height)
        var w = rect.width
        var h = rect.height
        if containerAspect > aspect {
            w = rect.height * CGFloat(aspect)
        } else {
            h = rect.width / CGFloat(aspect)
        }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// The purple dot that aims a manual zoom, as in Screen Studio. Shown over an
/// unzoomed preview so dragging it maps directly onto the recording.
struct AnchorOverlay: View {
    @Binding var anchor: NPoint
    let canvasAspect: Double
    let contentAspect: Double
    let padding: Double
    let scale: Double

    var body: some View {
        GeometryReader { geo in
            let content = CropOverlay.contentRect(
                container: geo.size,
                canvasAspect: canvasAspect,
                contentAspect: contentAspect,
                padding: padding
            )
            let point = CGPoint(
                x: content.minX + CGFloat(anchor.x) * content.width,
                y: content.minY + CGFloat(anchor.y) * content.height
            )
            // Outline of what the zoom will actually frame at this magnification.
            let boxW = content.width / CGFloat(max(1, scale))
            let boxH = content.height / CGFloat(max(1, scale))
            let boxX = min(max(point.x - boxW / 2, content.minX), content.maxX - boxW)
            let boxY = min(max(point.y - boxH / 2, content.minY), content.maxY - boxH)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(Color.purple.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: boxW, height: boxH)
                    .offset(x: boxX, y: boxY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.purple)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .shadow(radius: 3)
                    .offset(x: point.x - 9, y: point.y - 9)
                    // Same reason as the crop handles, except this one reads an
                    // absolute position rather than a delta, so the global
                    // point is mapped back into the overlay's own space.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            guard content.width > 0, content.height > 0 else { return }
                            let origin = geo.frame(in: .global).origin
                            let local = CGPoint(x: value.location.x - origin.x,
                                                y: value.location.y - origin.y)
                            anchor = NPoint(
                                min(max(0, Double((local.x - content.minX) / content.width)), 1),
                                min(max(0, Double((local.y - content.minY) / content.height)), 1)
                            )
                        })
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard content.width > 0, content.height > 0 else { return }
                anchor = NPoint(
                    min(max(0, Double((location.x - content.minX) / content.width)), 1),
                    min(max(0, Double((location.y - content.minY) / content.height)), 1)
                )
            }
        }
    }
}
