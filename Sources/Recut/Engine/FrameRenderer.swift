import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AppKit

/// Composites one output frame: backdrop, drop shadow, then the cropped,
/// masked and zoomed screen layer with the drawn cursor on top.
///
/// Deliberately stateless apart from a few caches, so the same code path can
/// serve the scrubbing preview and the final export.
final class FrameRenderer {

    private var maskCache: [MaskKey: CIImage] = [:]
    private var cursorCache: [Int: CIImage] = [:]
    private var imageCache: [String: CIImage] = [:]
    private var captionCache: [String: CIImage] = [:]
    private let cacheLock = NSLock()

    private struct MaskKey: Hashable {
        var w: Int
        var h: Int
        var r: Int
    }

    // MARK: - Entry point

    func render(
        source: CIImage,
        canvas: CGRect,
        sourceTime: Double,
        snapshot: RenderSnapshot,
        webcam: CIImage? = nil
    ) -> CIImage {
        let bg = snapshot.background
        let full = source.extent
        guard full.width > 0, full.height > 0 else { return source }

        let minSide = min(canvas.width, canvas.height)

        // 1. Crop, in source pixels.
        let cropRect = (snapshot.frame.crop.isFull || snapshot.previewFullFrame)
            ? full
            : snapshot.frame.crop.pixelRect(in: full.size).intersection(full)
        let cropped = cropRect.isEmpty ? full : cropRect

        // 2. Masks and highlights, applied before the zoom so they travel with
        //    the content they cover.
        var content = source
        if !snapshot.masks.isEmpty {
            content = applyMasks(snapshot.masks, to: content, at: sourceTime, bounds: full)
        }

        // 3. Where the camera is looking.
        let camera = snapshot.previewFullFrame
            ? Camera.identity
            : CameraSolver.camera(
                at: sourceTime, segments: snapshot.segments, cursor: snapshot.cursor,
                keepCursorInFrame: snapshot.keepCursorInFrame
            )
        let canvasRatio = canvas.width / max(1, canvas.height)
        let wantsFill = snapshot.frame.alwaysZoomedIn && snapshot.frame.aspect != .auto
        let visible = CameraSolver.visibleRect(
            camera: camera,
            bounds: cropped,
            aspect: wantsFill ? Double(canvasRatio) : nil
        )

        // 4. The rect on the canvas the recording is drawn into. A device frame
        //    takes its thickness out of that rect, so the bezel sits around the
        //    picture rather than on top of it.
        let pad = CGFloat(bg.padding) * minSide
        let avail = canvas.insetBy(dx: pad, dy: pad)
        let outerRect = Self.aspectFit(visible.size, in: avail)
        let device = snapshot.frame.device
        let bezel = CGFloat(device.bezelFraction) * min(outerRect.width, outerRect.height)
        let fitted = bezel > 0 ? outerRect.insetBy(dx: bezel, dy: bezel) : outerRect
        let zoom = fitted.width / max(1, visible.width)

        var foreground = content
            .cropped(to: visible)
            .transformed(by: CGAffineTransform(translationX: -visible.minX, y: -visible.minY))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
            .cropped(to: fitted)

        // 5. Cursor, drawn in canvas space so it stays crisp when magnified.
        if let pointer = cursorImage(
            at: sourceTime,
            snapshot: snapshot,
            sourceExtent: full,
            visible: visible,
            fitted: fitted,
            zoom: zoom,
            magnification: cropped.width / max(1, visible.width),
            minSide: minSide
        ) {
            foreground = pointer.cropped(to: fitted).composited(over: foreground)
        }

        // 6. Rounded corners and inner border. Inside a device frame the corner
        //    radius comes from the hardware, not the background settings.
        let outerRadius = bezel > 0
            ? CGFloat(device.cornerFraction) * min(outerRect.width, outerRect.height)
            : 0
        let radius = bezel > 0
            ? max(0, outerRadius - bezel)
            : CGFloat(bg.cornerRadius) * minSide
        let shape = roundedMask(size: fitted.size, radius: radius)
            .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))

        if bg.inset > 0.0001 {
            foreground = insetBorder(on: foreground, rect: fitted, radius: radius,
                                     width: CGFloat(bg.inset) * minSide, color: bg.insetColor)
        }
        if radius > 0.5 {
            foreground = blend(foreground, mask: shape)
        }

        // 7. Backdrop and shadow.
        var result = backdrop(source: source, canvas: canvas, bg: bg)

        if bg.shadowOpacity > 0.001 {
            let sigma = max(1, CGFloat(bg.shadowRadius) * minSide)
            let dy = CGFloat(bg.shadowOffsetY) * minSide
            // The shadow follows the outside of the device, not the screen.
            let castShape = bezel > 0
                ? roundedMask(size: outerRect.size, radius: outerRadius)
                    .transformed(by: CGAffineTransform(translationX: outerRect.minX,
                                                       y: outerRect.minY))
                : (radius > 0.5 ? shape : solidMask(rect: fitted))
            let shadowShape = castShape
                .transformed(by: CGAffineTransform(translationX: 0, y: -dy))
                .applyingGaussianBlur(sigma: Double(sigma))
            var shadow = blend(
                CIImage(color: .black).cropped(to: shadowShape.extent),
                mask: shadowShape
            )
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = shadow
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(bg.shadowOpacity))
            shadow = matrix.outputImage ?? shadow
            result = shadow.composited(over: result)
        }

        if bezel > 0 {
            result = deviceBezel(
                outer: outerRect, radius: outerRadius, thickness: bezel, device: device
            ).composited(over: result)
        }

        var composed = foreground.composited(over: result)

        if device.hasDynamicIsland {
            composed = dynamicIsland(in: fitted).composited(over: composed)
        }

        // 7b. Keyboard shortcut caption, below the screen layer.
        if snapshot.shortcuts.show,
           let caption = shortcutLabel(at: sourceTime, snapshot: snapshot,
                                       fitted: fitted, minSide: minSide) {
            composed = caption.composited(over: composed)
        }

        // 7c. Callouts, positioned against the recording so they travel with it.
        for overlay in snapshot.texts {
            if let layer = textLayer(overlay, at: sourceTime, fitted: fitted, minSide: minSide) {
                composed = layer.composited(over: composed)
            }
        }

        // 7d. Brand mark. Under the camera: a person outranks a logo.
        if snapshot.watermark.enabled,
           let mark = watermarkLayer(canvas: canvas, settings: snapshot.watermark) {
            composed = mark.composited(over: composed)
        }

        // 8. Camera on top of everything, so a zoom never covers the speaker.
        if let webcam, snapshot.webcam.enabled,
           let pip = webcamLayer(webcam, canvas: canvas, settings: snapshot.webcam) {
            composed = pip.composited(over: composed)
        }

        return composed.cropped(to: canvas)
    }

    // MARK: - Text callouts

    /// One callout, faded in and out so it doesn't pop.
    private func textLayer(
        _ overlay: TextOverlay, at t: Double, fitted: CGRect, minSide: CGFloat
    ) -> CIImage? {
        let trimmed = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let alpha = overlay.opacity(at: t)
        guard alpha > 0.01 else { return nil }

        let height = minSide * 0.075 * CGFloat(max(0.3, overlay.size))
        guard let image = calloutImage(overlay, height: height) else { return nil }

        // Positioned within the recording, not the canvas, so padding and
        // aspect changes don't slide the text off the picture.
        let x = fitted.minX + CGFloat(overlay.position.x) * fitted.width
            - image.extent.width / 2
        let y = fitted.minY + (1 - CGFloat(overlay.position.y)) * fitted.height
            - image.extent.height / 2
        var placed = image.transformed(by: CGAffineTransform(translationX: x.rounded(),
                                                             y: y.rounded()))
        if alpha < 0.999 {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = placed
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
            placed = matrix.outputImage ?? placed
        }
        return placed
    }

    private func calloutImage(_ overlay: TextOverlay, height: CGFloat) -> CIImage? {
        let key = [
            overlay.text, String(Int(height)), overlay.style.rawValue,
            overlay.bold ? "b" : "r",
            String(format: "%.2f,%.2f,%.2f,%.2f", overlay.color.r, overlay.color.g,
                   overlay.color.b, overlay.color.a),
            String(format: "%.2f,%.2f,%.2f,%.2f", overlay.background.r, overlay.background.g,
                   overlay.background.b, overlay.background.a),
        ].joined(separator: "|")

        cacheLock.lock()
        if let hit = captionCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let font = NSFont.systemFont(ofSize: height * 0.6,
                                     weight: overlay.bold ? .semibold : .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(
                srgbRed: overlay.color.r, green: overlay.color.g,
                blue: overlay.color.b, alpha: overlay.color.a
            ),
        ]
        let string = NSAttributedString(string: overlay.text, attributes: attributes)
        let textSize = string.size()

        let padX: CGFloat = overlay.style == .plain ? 0 : height * (overlay.style == .card ? 0.7 : 0.45)
        let padY: CGFloat = overlay.style == .plain ? 0 : height * (overlay.style == .card ? 0.5 : 0.3)
        let w = max(1, Int((textSize.width + padX * 2).rounded()))
        let h = max(1, Int((textSize.height + padY * 2).rounded()))

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        if overlay.style != .plain {
            ctx.setFillColor(CGColor(
                red: overlay.background.r, green: overlay.background.g,
                blue: overlay.background.b, alpha: overlay.background.a
            ))
            let radius: CGFloat = overlay.style == .pill
                ? CGFloat(h) / 2
                : CGFloat(h) * 0.18
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            ctx.fillPath()
        } else {
            // With no chip behind it, the text needs its own contrast.
            ctx.setShadow(offset: CGSize(width: 0, height: -height * 0.04),
                          blur: height * 0.12,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
        }

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        string.draw(at: NSPoint(x: padX, y: (CGFloat(h) - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)

        cacheLock.lock()
        if captionCache.count > 40 { captionCache.removeAll() }
        captionCache[key] = image
        cacheLock.unlock()
        return image
    }

    // MARK: - Watermark

    private func watermarkLayer(canvas: CGRect, settings: WatermarkSettings) -> CIImage? {
        guard let path = settings.imagePath, let logo = cachedImage(path) else { return nil }
        let extent = logo.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let minSide = min(canvas.width, canvas.height)
        let target = max(8, CGFloat(settings.size) * minSide)
        // Fit by height so wide and tall logos both land at a sensible size.
        let scale = target / extent.height
        var layer = logo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let margin = CGFloat(settings.margin) * minSide
        let size = layer.extent.size
        let origin: CGPoint
        switch settings.corner {
        case .bottomLeft: origin = CGPoint(x: canvas.minX + margin, y: canvas.minY + margin)
        case .bottomRight: origin = CGPoint(x: canvas.maxX - margin - size.width,
                                            y: canvas.minY + margin)
        case .topLeft: origin = CGPoint(x: canvas.minX + margin,
                                        y: canvas.maxY - margin - size.height)
        case .topRight: origin = CGPoint(x: canvas.maxX - margin - size.width,
                                         y: canvas.maxY - margin - size.height)
        }
        layer = layer.transformed(by: CGAffineTransform(
            translationX: origin.x - layer.extent.minX,
            y: origin.y - layer.extent.minY
        ))

        guard settings.opacity < 0.999 else { return layer }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = layer
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, settings.opacity)))
        return matrix.outputImage
    }

    // MARK: - Device frame

    /// The body of the phone or tablet: a dark rounded slab with a lighter rim,
    /// drawn behind the screen layer so the picture sits inside it.
    private func deviceBezel(
        outer: CGRect, radius: CGFloat, thickness: CGFloat, device: DeviceFrame
    ) -> CIImage {
        let body = roundedMask(size: outer.size, radius: radius)
            .transformed(by: CGAffineTransform(translationX: outer.minX, y: outer.minY))

        let fill = CIFilter.linearGradient()
        fill.point0 = CGPoint(x: outer.minX, y: outer.maxY)
        fill.color0 = CIColor(red: 0.30, green: 0.31, blue: 0.34, alpha: 1)
        fill.point1 = CGPoint(x: outer.maxX, y: outer.minY)
        fill.color1 = CIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        let slab = blend(
            (fill.outputImage ?? CIImage(color: .gray)).cropped(to: outer), mask: body
        )

        // A hairline of brighter metal just inside the edge reads as a rim.
        let rimOuter = body
        let rimInnerRect = outer.insetBy(dx: thickness * 0.28, dy: thickness * 0.28)
        let rimInner = roundedMask(
            size: rimInnerRect.size, radius: max(0, radius - thickness * 0.28)
        ).transformed(by: CGAffineTransform(translationX: rimInnerRect.minX, y: rimInnerRect.minY))

        let subtract = CIFilter.blendWithMask()
        subtract.inputImage = CIImage.empty()
        subtract.backgroundImage = rimOuter
        subtract.maskImage = rimInner
        guard let ring = subtract.outputImage else { return slab }

        let rim = blend(
            CIImage(color: CIColor(red: 0.62, green: 0.64, blue: 0.68, alpha: 0.85))
                .cropped(to: outer),
            mask: ring.cropped(to: outer)
        )
        return rim.composited(over: slab)
    }

    /// The pill cut-out at the top of a modern iPhone screen.
    private func dynamicIsland(in screen: CGRect) -> CIImage {
        let width = screen.width * 0.30
        let height = min(screen.height * 0.05, width * 0.30)
        let rect = CGRect(
            x: screen.midX - width / 2,
            y: screen.maxY - height - screen.height * 0.018,
            width: width,
            height: height
        )
        let mask = roundedMask(size: rect.size, radius: height / 2)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return blend(
            CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
                .cropped(to: rect),
            mask: mask
        )
    }

    // MARK: - Shortcut captions

    /// The keys pressed in the last `duration` seconds, drawn as one caption.
    private func shortcutLabel(
        at t: Double, snapshot: RenderSnapshot, fitted: CGRect, minSide: CGFloat
    ) -> CIImage? {
        let settings = snapshot.shortcuts
        let window = max(0.3, settings.duration)

        var recent: [String] = []
        for event in snapshot.keyEvents {
            guard event.t <= t, t - event.t <= window, let label = event.label else { continue }
            // A lone letter is usually just typing; only show it if asked.
            let isCombination = label.contains("⌘") || label.contains("⌃")
                || label.contains("⌥") || label.count > 1
            guard settings.includeSingleKeys || isCombination else { continue }
            recent.append(label)
        }
        guard let newest = recent.last else { return nil }

        // Collapse a held-down repeat into one caption.
        var display = newest
        if recent.count > 1, Set(recent).count == 1 {
            display = "\(newest) ×\(recent.count)"
        } else if recent.count > 1 {
            display = recent.suffix(3).joined(separator: "  ")
        }

        let height = minSide * 0.075 * CGFloat(max(0.4, settings.size))
        guard let image = captionImage(display, height: height) else { return nil }

        // Fade out over the last third of the window.
        let age = t - (snapshot.keyEvents.last { $0.t <= t }?.t ?? t)
        let fade = age > window * 0.66
            ? max(0, 1 - (age - window * 0.66) / (window * 0.34))
            : 1

        let placed = image.transformed(by: CGAffineTransform(
            translationX: fitted.midX - image.extent.width / 2,
            y: fitted.minY + minSide * 0.045
        ))
        guard fade < 0.999 else { return placed }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = placed
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: fade)
        return matrix.outputImage
    }

    private func captionImage(_ text: String, height: CGFloat) -> CIImage? {
        let key = "\(text)|\(Int(height))"
        cacheLock.lock()
        if let hit = captionCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let font = NSFont.systemFont(ofSize: height * 0.52, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = height * 0.34
        let w = max(1, Int((textSize.width + padding * 2).rounded()))
        let h = max(1, Int((textSize.height + padding).rounded()))

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.78))
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
            cornerWidth: CGFloat(h) * 0.28, cornerHeight: CGFloat(h) * 0.28, transform: nil
        ))
        ctx.fillPath()

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        string.draw(at: NSPoint(x: padding, y: (CGFloat(h) - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)

        cacheLock.lock()
        if captionCache.count > 40 { captionCache.removeAll() }
        captionCache[key] = image
        cacheLock.unlock()
        return image
    }

    // MARK: - Webcam

    private func webcamLayer(
        _ image: CIImage, canvas: CGRect, settings: WebcamSettings
    ) -> CIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let minSide = min(canvas.width, canvas.height)
        let side = max(24, CGFloat(settings.size) * minSide)
        let margin = CGFloat(settings.margin) * minSide

        // Circle and square crop to the middle of the frame; rounded keeps the
        // camera's own aspect ratio.
        let targetAspect: CGFloat = settings.shape == .rounded ? extent.width / extent.height : 1
        let target = CGSize(
            width: targetAspect >= 1 ? side * targetAspect : side,
            height: targetAspect >= 1 ? side : side / targetAspect
        )

        let scale = max(target.width / extent.width, target.height / extent.height)
        var layer = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if settings.mirrored {
            layer = layer
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: layer.extent.width * 2, y: 0))
        }

        let corner: CGPoint
        switch settings.corner {
        case .bottomLeft:
            corner = CGPoint(x: canvas.minX + margin, y: canvas.minY + margin)
        case .bottomRight:
            corner = CGPoint(x: canvas.maxX - margin - target.width, y: canvas.minY + margin)
        case .topLeft:
            corner = CGPoint(x: canvas.minX + margin, y: canvas.maxY - margin - target.height)
        case .topRight:
            corner = CGPoint(x: canvas.maxX - margin - target.width,
                             y: canvas.maxY - margin - target.height)
        }
        let frame = CGRect(origin: corner, size: target)

        // Centre-crop, then move into place.
        layer = layer.transformed(by: CGAffineTransform(
            translationX: frame.midX - layer.extent.midX,
            y: frame.midY - layer.extent.midY
        )).cropped(to: frame)

        let radius: CGFloat
        switch settings.shape {
        case .circle: radius = min(frame.width, frame.height) / 2
        case .rounded: radius = minSide * 0.02
        case .square: radius = 0
        }

        let mask = roundedMask(size: frame.size, radius: radius)
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
        var result = radius > 0.5 ? blend(layer, mask: mask) : layer

        if settings.shadowOpacity > 0.001 {
            let blurred = mask
                .transformed(by: CGAffineTransform(translationX: 0, y: -minSide * 0.006))
                .applyingGaussianBlur(sigma: Double(minSide * 0.012))
            var shadow = blend(
                CIImage(color: .black).cropped(to: blurred.extent), mask: blurred
            )
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = shadow
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(settings.shadowOpacity))
            shadow = matrix.outputImage ?? shadow
            result = result.composited(over: shadow)
        }
        return result
    }

    // MARK: - Masks and highlights

    private func applyMasks(
        _ masks: [MaskRegion], to image: CIImage, at t: Double, bounds: CGRect
    ) -> CIImage {
        var result = image
        for mask in masks where t >= mask.start && t <= mask.end {
            let rect = mask.rect.clamped.pixelRect(in: bounds.size).intersection(bounds)
            guard !rect.isEmpty else { continue }
            let radius = CGFloat(mask.cornerRadius) * min(bounds.width, bounds.height)
            let shape = roundedMask(size: rect.size, radius: radius)
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

            switch mask.kind {
            case .blur:
                // Blur small then scale back — a heavy blur throws the detail
                // away regardless, and this keeps it cheap on 4K frames.
                let patch = result.cropped(to: rect)
                let blurred = patch
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: max(2, mask.blurRadius))
                    .cropped(to: rect)
                result = blend(blurred, mask: shape).composited(over: result)

            case .solid:
                let fill = CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.09,
                                                 alpha: mask.opacity))
                    .cropped(to: rect)
                result = blend(fill, mask: shape).composited(over: result)

            case .highlight:
                // Dim everything outside the rect rather than touching inside it.
                let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0,
                                                 alpha: 0.55 * mask.opacity))
                    .cropped(to: bounds)
                let inverse = CIFilter.blendWithMask()
                inverse.inputImage = CIImage.empty()
                inverse.backgroundImage = dim
                inverse.maskImage = shape
                if let veil = inverse.outputImage?.cropped(to: bounds) {
                    result = veil.composited(over: result)
                }
            }
        }
        return result
    }

    // MARK: - Cursor

    /// Draws the pointer from the recorded track, in canvas space so it stays
    /// crisp however far the camera is zoomed in.
    private func cursorImage(
        at t: Double,
        snapshot: RenderSnapshot,
        sourceExtent: CGRect,
        visible: CGRect,
        fitted: CGRect,
        zoom: CGFloat,
        magnification: CGFloat,
        minSide: CGFloat
    ) -> CIImage? {
        let settings = snapshot.cursorSettings
        guard settings.mode == .synthetic else { return nil }

        let path = snapshot.cursor
        var alpha = 1.0
        if settings.hideWhenIdle {
            alpha = 1 - path.idleAmount(at: t, delay: settings.idleDelay)
            guard alpha > 0.01 else { return nil }
        }

        // Normalized source point → source pixels → canvas.
        let p = path.position(at: t)
        let sx = sourceExtent.minX + p.x * sourceExtent.width
        let sy = sourceExtent.minY + (1 - p.y) * sourceExtent.height
        let cx = fitted.minX + (sx - visible.minX) * zoom
        let cy = fitted.minY + (sy - visible.minY) * zoom

        // Growing the pointer linearly with the zoom makes it enormous at 5x,
        // so damp it — it still reads as part of the scene, without taking over.
        let size = minSide * 0.052 * CGFloat(max(0.2, settings.size))
            * max(1, magnification).squareRoot()

        var result: CIImage?

        if settings.clickHighlight {
            let pulse = path.clickPulse(at: t)
            if pulse > 0.01 {
                let radius = size * (0.55 + 1.5 * (1 - pulse))
                let ring = CIFilter.radialGradient()
                ring.center = CGPoint(x: cx, y: cy)
                ring.radius0 = Float(radius * 0.55)
                ring.radius1 = Float(radius)
                ring.color0 = CIColor(red: 1, green: 0.83, blue: 0.25, alpha: 0.55 * pulse)
                ring.color1 = CIColor(red: 1, green: 0.83, blue: 0.25, alpha: 0)
                if let g = ring.outputImage?.cropped(to: CGRect(
                    x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2
                )) {
                    result = g
                }
            }
        }

        let arrow = pointerShape(height: size)
        // The hot spot is the tip, which sits at the shape's top-left corner.
        let placed = arrow.transformed(by: CGAffineTransform(
            translationX: cx, y: cy - arrow.extent.height
        ))
        result = result.map { placed.composited(over: $0) } ?? placed

        guard var out = result else { return nil }
        if alpha < 0.999 {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = out
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
            out = matrix.outputImage ?? out
        }
        return out
    }

    /// The macOS arrow, rasterized once per size and cached.
    private func pointerShape(height: CGFloat) -> CIImage {
        let h = max(8, Int(height.rounded()))
        cacheLock.lock()
        if let hit = cursorCache[h] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let w = max(6, Int((CGFloat(h) * 0.62).rounded()))
        // Outline and shadow need room beyond the silhouette.
        let padding = max(2, h / 12)
        let cw = w + padding * 2
        let ch = h + padding * 2

        guard let ctx = CGContext(
            data: nil, width: cw, height: ch,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        ctx.clear(CGRect(x: 0, y: 0, width: cw, height: ch))

        // Unit outline of the pointer, top-left origin, tip at (0,0).
        let unit: [CGPoint] = [
            CGPoint(x: 0.00, y: 0.00), CGPoint(x: 0.00, y: 0.74),
            CGPoint(x: 0.19, y: 0.58), CGPoint(x: 0.31, y: 0.88),
            CGPoint(x: 0.45, y: 0.82), CGPoint(x: 0.33, y: 0.53),
            CGPoint(x: 0.56, y: 0.51),
        ]
        let path = CGMutablePath()
        for (i, u) in unit.enumerated() {
            let p = CGPoint(
                x: CGFloat(padding) + u.x * CGFloat(h),
                y: CGFloat(ch - padding) - u.y * CGFloat(h)
            )
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()

        ctx.setShadow(
            offset: CGSize(width: 0, height: -CGFloat(padding) / 2),
            blur: CGFloat(padding),
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        )
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        ctx.setStrokeColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.92))
        ctx.setLineWidth(max(1, CGFloat(h) / 26))
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let image = CIImage(cgImage: cg)

        cacheLock.lock()
        if cursorCache.count > 12 { cursorCache.removeAll() }
        cursorCache[h] = image
        cacheLock.unlock()
        return image
    }

    // MARK: - Backdrop

    private func backdrop(source: CIImage, canvas: CGRect, bg: BackgroundSettings) -> CIImage {
        switch bg.kind {
        case .none:
            return CIImage(color: .black).cropped(to: canvas)

        case .color:
            return CIImage(color: ci(bg.color)).cropped(to: canvas)

        case .gradient:
            return linearGradient(
                canvas: canvas, top: bg.gradientTop, bottom: bg.gradientBottom
            )

        case .wallpaper:
            let (a, b, c) = bg.wallpaper.colors
            var image = linearGradient(canvas: canvas, top: a, bottom: c)
            // A soft off-centre glow keeps the flat gradient from looking like
            // a placeholder.
            let glow = CIFilter.radialGradient()
            glow.center = CGPoint(x: canvas.minX + canvas.width * 0.72,
                                  y: canvas.minY + canvas.height * 0.78)
            glow.radius0 = Float(min(canvas.width, canvas.height) * 0.05)
            glow.radius1 = Float(max(canvas.width, canvas.height) * 0.8)
            glow.color0 = ci(b)
            glow.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let g = glow.outputImage?.cropped(to: canvas) {
                image = g.composited(over: image)
            }
            return image.cropped(to: canvas)

        case .image:
            if let path = bg.imagePath, let loaded = cachedImage(path) {
                return cover(loaded, in: canvas)
            }
            return CIImage(color: ci(bg.color)).cropped(to: canvas)

        case .blur:
            // Blurring a 4K frame every tick is far too slow, and a heavy blur
            // throws away the detail anyway — so shrink first, blur small,
            // then scale the result back up to cover the canvas.
            let shrink: CGFloat = 0.18
            let small = source.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
            let blurred = small
                .clampedToExtent()
                .applyingGaussianBlur(sigma: max(1, bg.blurRadius * Double(shrink)))
                .cropped(to: small.extent)

            var out = cover(blurred, in: canvas)
            let controls = CIFilter.colorControls()
            controls.inputImage = out
            controls.saturation = Float(bg.saturation)
            controls.brightness = Float(-bg.dim)
            controls.contrast = 1
            out = controls.outputImage ?? out
            return out.cropped(to: canvas)
        }
    }

    private func linearGradient(canvas: CGRect, top: RGBAColor, bottom: RGBAColor) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: canvas.midX, y: canvas.maxY)
        gradient.color0 = ci(top)
        gradient.point1 = CGPoint(x: canvas.midX, y: canvas.minY)
        gradient.color1 = ci(bottom)
        return (gradient.outputImage ?? CIImage(color: .black)).cropped(to: canvas)
    }

    private func cover(_ image: CIImage, in canvas: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(canvas.width / extent.width, canvas.height / extent.height)
        var out = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        out = out.transformed(by: CGAffineTransform(
            translationX: canvas.midX - out.extent.midX,
            y: canvas.midY - out.extent.midY
        ))
        return out.cropped(to: canvas)
    }

    private func cachedImage(_ path: String) -> CIImage? {
        cacheLock.lock()
        if let hit = imageCache[path] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let nsImage = NSImage(contentsOfFile: path),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let image = CIImage(cgImage: cg)

        cacheLock.lock()
        if imageCache.count > 6 { imageCache.removeAll() }
        imageCache[path] = image
        cacheLock.unlock()
        return image
    }

    // MARK: - Helpers

    private func insetBorder(
        on image: CIImage, rect: CGRect, radius: CGFloat, width: CGFloat, color: RGBAColor
    ) -> CIImage {
        let outer = roundedMask(size: rect.size, radius: radius)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let innerRect = rect.insetBy(dx: width, dy: width)
        guard innerRect.width > 2, innerRect.height > 2 else { return image }
        let inner = roundedMask(size: innerRect.size, radius: max(0, radius - width))
            .transformed(by: CGAffineTransform(translationX: innerRect.minX, y: innerRect.minY))

        // Ring = outer minus inner.
        let subtract = CIFilter.blendWithMask()
        subtract.inputImage = CIImage.empty()
        subtract.backgroundImage = outer
        subtract.maskImage = inner
        guard let ring = subtract.outputImage else { return image }

        let fill = CIImage(color: ci(color)).cropped(to: rect)
        let border = blend(fill, mask: ring.cropped(to: rect))
        return border.composited(over: image)
    }

    private func blend(_ image: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = image
        f.backgroundImage = CIImage.empty()
        f.maskImage = mask
        return f.outputImage ?? image
    }

    private func solidMask(rect: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: rect)
    }

    private func roundedMask(size: CGSize, radius: CGFloat) -> CIImage {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let r = max(0, min(radius, CGFloat(min(w, h)) / 2))
        let key = MaskKey(w: w, h: h, r: Int(r.rounded()))

        cacheLock.lock()
        if let hit = maskCache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return solidMask(rect: CGRect(origin: .zero, size: size))
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
            cornerWidth: r, cornerHeight: r, transform: nil
        ))
        ctx.fillPath()

        guard let cg = ctx.makeImage() else {
            return solidMask(rect: CGRect(origin: .zero, size: size))
        }
        let image = CIImage(cgImage: cg)

        cacheLock.lock()
        if maskCache.count > 24 { maskCache.removeAll() }
        maskCache[key] = image
        cacheLock.unlock()
        return image
    }

    private func ci(_ c: RGBAColor) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = (size.width * scale).rounded()
        let h = (size.height * scale).rounded()
        return CGRect(
            x: (rect.midX - w / 2).rounded(),
            y: (rect.midY - h / 2).rounded(),
            width: w, height: h
        )
    }
}
