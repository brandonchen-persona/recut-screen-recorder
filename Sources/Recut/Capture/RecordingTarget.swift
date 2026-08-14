import Foundation
import ScreenCaptureKit
import AppKit

/// What a recording is pointed at. Screen Studio calls these Display, Window
/// and Area; ScreenCaptureKit models the first two as content filters and the
/// third as a `sourceRect` on a display filter.
enum RecordingTarget {
    case display(SCDisplay)
    case window(SCWindow)
    /// Rect in display points, top-left origin, as `SCStreamConfiguration`
    /// wants it.
    case area(SCDisplay, CGRect)

    var display: SCDisplay? {
        switch self {
        case .display(let d), .area(let d, _): return d
        case .window: return nil
        }
    }

    var kind: CaptureSource {
        switch self {
        case .display: return .display
        case .window: return .window
        case .area: return .area
        }
    }

    var label: String {
        switch self {
        case .display(let d):
            return ScreenRecorder.nsScreen(for: d)?.localizedName ?? "Display"
        case .window(let w):
            let app = w.owningApplication?.applicationName ?? "Window"
            let title = w.title.flatMap { $0.isEmpty ? nil : $0 }
            return title.map { "\(app) — \($0)" } ?? app
        case .area(_, let rect):
            return "Area \(Int(rect.width)) × \(Int(rect.height))"
        }
    }

    /// Pixel size to capture at, capped so a 6K display doesn't produce a file
    /// nothing can play back smoothly.
    func captureSize(maxWidth: Double = 3840) -> (width: Int, height: Int) {
        var points: CGSize
        var scale: CGFloat

        switch self {
        case .display(let d):
            points = CGSize(width: Double(d.width), height: Double(d.height))
            scale = ScreenRecorder.nsScreen(for: d)?.backingScaleFactor ?? 2
        case .area(let d, let rect):
            points = rect.size
            scale = ScreenRecorder.nsScreen(for: d)?.backingScaleFactor ?? 2
        case .window(let w):
            points = w.frame.size
            scale = NSScreen.screens.first { $0.frame.intersects(w.frame) }?
                .backingScaleFactor ?? 2
        }

        var w = max(2, Double(points.width * scale))
        var h = max(2, Double(points.height * scale))
        if w > maxWidth {
            h *= maxWidth / w
            w = maxWidth
        }
        return (Int((w / 2).rounded()) * 2, Int((h / 2).rounded()) * 2)
    }

    /// The pointer track is normalized against this rect, in AppKit global
    /// coordinates (bottom-left origin), so capture resolution drops out.
    var pointerFrame: CGRect {
        switch self {
        case .display(let d):
            return ScreenRecorder.nsScreen(for: d)?.frame
                ?? CGRect(x: 0, y: 0, width: Double(d.width), height: Double(d.height))
        case .window(let w):
            return AppKitRect(fromScreenCaptureKit: w.frame)
        case .area(let d, let rect):
            let screen = ScreenRecorder.nsScreen(for: d)?.frame ?? .zero
            // sourceRect is top-left relative to the display; AppKit is
            // bottom-left relative to the primary screen.
            return CGRect(
                x: screen.minX + rect.minX,
                y: screen.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
    }

    func contentFilter(excluding apps: [SCRunningApplication]) -> SCContentFilter {
        switch self {
        case .display(let d), .area(let d, _):
            return SCContentFilter(
                display: d, excludingApplications: apps, exceptingWindows: []
            )
        case .window(let w):
            return SCContentFilter(desktopIndependentWindow: w)
        }
    }
}

/// ScreenCaptureKit reports window frames with a top-left origin on the primary
/// display; AppKit uses bottom-left. Only the y axis differs.
func AppKitRect(fromScreenCaptureKit rect: CGRect) -> CGRect {
    guard let primary = NSScreen.screens.first else { return rect }
    return CGRect(
        x: rect.minX,
        y: primary.frame.maxY - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}
