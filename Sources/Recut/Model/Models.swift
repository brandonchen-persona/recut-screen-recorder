import Foundation
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Small codable value types

struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// A point in normalized image space: (0,0) is top-left, (1,1) is bottom-right.
struct NPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    static let center = NPoint(0.5, 0.5)

    var cg: CGPoint { CGPoint(x: x, y: y) }
}

/// A rectangle in normalized image space, top-left origin.
struct NRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    static let full = NRect(0, 0, 1, 1)

    var isFull: Bool { x <= 0.0001 && y <= 0.0001 && width >= 0.9999 && height >= 0.9999 }
    var center: NPoint { NPoint(x + width / 2, y + height / 2) }

    var clamped: NRect {
        let w = min(max(width, 0.02), 1)
        let h = min(max(height, 0.02), 1)
        return NRect(min(max(x, 0), 1 - w), min(max(y, 0), 1 - h), w, h)
    }

    /// Pixel rect in Core Image's bottom-left-origin space.
    func pixelRect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: (1 - y - height) * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

// MARK: - Captured input

struct InputEvent: Codable {
    enum Kind: String, Codable {
        case move
        case click
        case rightClick
        case drag
        case scroll
        case key
    }

    /// Seconds from the first captured video frame.
    var t: Double
    var kind: Kind
    var x: Double
    var y: Double
    /// For `.key`, the rendered shortcut label, e.g. "⌘S".
    var label: String?

    init(t: Double, kind: Kind, x: Double, y: Double, label: String? = nil) {
        self.t = t; self.kind = kind; self.x = x; self.y = y; self.label = label
    }

    var point: NPoint { NPoint(x, y) }

    /// Events that should pull the camera somewhere.
    var isTrigger: Bool { kind == .click || kind == .rightClick || kind == .drag || kind == .scroll }
}

// MARK: - Recording metadata

enum CaptureSource: String, Codable {
    case display
    case window
    case area
}

struct RecordingMeta: Codable {
    var width: Int
    var height: Int
    var duration: Double
    var fps: Int
    var createdAt: Date
    /// "video.mov" (relative to the bundle) or an absolute path for imported media.
    var videoFile: String
    var displayName: String?
    /// True when the OS cursor was hidden at capture time, so the editor draws
    /// its own from the recorded pointer track.
    var cursorIsSynthetic: Bool?
    var source: CaptureSource?
    /// Relative path of the webcam movie, when one was recorded.
    var webcamFile: String?

    var size: CGSize { CGSize(width: width, height: height) }
}

// MARK: - Clips

/// One piece of the source on the timeline. Cutting splits a clip in two;
/// removing deletes one. Speed and volume are per-clip, matching how Screen
/// Studio applies them to a selected fragment.
struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double = 1
    var volume: Double = 1
    /// Set on clips the typing detector produced, so "apply to all typing
    /// parts" knows which ones to touch.
    var isTyping: Bool = false

    var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
    var outputDuration: Double { sourceDuration / max(0.05, speed) }

    static let speedChoices: [Double] = [0.5, 1, 1.25, 1.5, 2, 3, 4, 8, 16]
    static let volumeChoices: [Double] = [0, 0.25, 0.5, 0.75, 1, 1.5, 2]
}

// MARK: - Look of the frame around the recording

enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
    case blur
    case wallpaper
    case gradient
    case color
    case image
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur: return "Blurred screen"
        case .wallpaper: return "Wallpaper"
        case .gradient: return "Gradient"
        case .color: return "Color"
        case .image: return "Image"
        case .none: return "None"
        }
    }
}

/// Built-in wallpapers, generated rather than shipped as assets so the app
/// stays a single binary.
enum Wallpaper: String, Codable, CaseIterable, Identifiable {
    case dusk, ocean, forest, ember, graphite, candy

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var colors: (RGBAColor, RGBAColor, RGBAColor) {
        switch self {
        case .dusk:
            return (RGBAColor(0.36, 0.24, 0.60), RGBAColor(0.85, 0.35, 0.45), RGBAColor(0.13, 0.10, 0.25))
        case .ocean:
            return (RGBAColor(0.10, 0.45, 0.72), RGBAColor(0.25, 0.78, 0.80), RGBAColor(0.04, 0.13, 0.28))
        case .forest:
            return (RGBAColor(0.14, 0.42, 0.30), RGBAColor(0.55, 0.78, 0.36), RGBAColor(0.05, 0.15, 0.13))
        case .ember:
            return (RGBAColor(0.85, 0.42, 0.14), RGBAColor(0.96, 0.74, 0.30), RGBAColor(0.24, 0.08, 0.06))
        case .graphite:
            return (RGBAColor(0.28, 0.30, 0.34), RGBAColor(0.48, 0.52, 0.58), RGBAColor(0.09, 0.10, 0.12))
        case .candy:
            return (RGBAColor(0.96, 0.55, 0.75), RGBAColor(0.60, 0.66, 0.98), RGBAColor(0.20, 0.16, 0.35))
        }
    }
}

struct BackgroundSettings: Codable {
    var kind: BackgroundKind = .blur

    /// Blur strength, in source pixels.
    var blurRadius: Double = 90
    /// 0 = untouched, 1 = black.
    var dim: Double = 0.28
    var saturation: Double = 1.15

    var wallpaper: Wallpaper = .dusk
    var color: RGBAColor = RGBAColor(0.09, 0.10, 0.13)
    var gradientTop: RGBAColor = RGBAColor(0.29, 0.33, 0.55)
    var gradientBottom: RGBAColor = RGBAColor(0.08, 0.09, 0.14)
    /// Absolute path of a user-supplied background image.
    var imagePath: String?

    /// All of these are fractions of the canvas' smaller dimension.
    var padding: Double = 0.055
    var cornerRadius: Double = 0.018
    /// Inner border drawn between the recording and the background.
    var inset: Double = 0
    var insetColor: RGBAColor = RGBAColor(1, 1, 1, 0.9)
    var shadowOpacity: Double = 0.5
    var shadowRadius: Double = 0.022
    var shadowOffsetY: Double = 0.012
}

// MARK: - Output frame shape

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case auto, wide, vertical, square, classic, tall

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .wide: return "Wide"
        case .vertical: return "Vertical"
        case .square: return "Square"
        case .classic: return "Classic"
        case .tall: return "Tall"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Original"
        case .wide: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .classic: return "4:3"
        case .tall: return "3:4"
        }
    }

    /// width / height, or nil to keep the recording's own ratio.
    var value: Double? {
        switch self {
        case .auto: return nil
        case .wide: return 16.0 / 9.0
        case .vertical: return 9.0 / 16.0
        case .square: return 1
        case .classic: return 4.0 / 3.0
        case .tall: return 3.0 / 4.0
        }
    }
}

/// A hardware bezel drawn around the recording. Screen Studio offers this for
/// iPhone Mirroring captures, which are otherwise just a bare rounded rectangle.
enum DeviceFrame: String, Codable, CaseIterable, Identifiable {
    case none, phone, tablet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .phone: return "iPhone"
        case .tablet: return "iPad"
        }
    }

    /// Bezel thickness as a fraction of the frame's smaller side.
    var bezelFraction: Double {
        switch self {
        case .none: return 0
        case .phone: return 0.022
        case .tablet: return 0.026
        }
    }

    /// Outer corner radius, again relative to the frame's smaller side.
    var cornerFraction: Double {
        switch self {
        case .none: return 0
        case .phone: return 0.13
        case .tablet: return 0.055
        }
    }

    var hasDynamicIsland: Bool { self == .phone }
}

struct FrameSettings: Codable {
    var aspect: AspectRatio = .auto
    var device: DeviceFrame = .none
    /// Crop the visible area to the chosen ratio and let the cursor decide
    /// which part stays on screen, instead of letterboxing.
    var alwaysZoomedIn: Bool = false
    /// Region of the source kept, before any zoom.
    var crop: NRect = .full
}

// MARK: - Cursor

enum CursorMode: String, Codable, CaseIterable, Identifiable {
    /// Whatever the capture baked in.
    case recorded
    /// Drawn by the editor from the recorded pointer track.
    case synthetic
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recorded: return "As recorded"
        case .synthetic: return "Smoothed"
        case .hidden: return "Hidden"
        }
    }
}

struct CursorSettings: Codable {
    var mode: CursorMode = .recorded
    /// Multiplier on the drawn pointer.
    var size: Double = 1.0
    /// Smoothing time constant in seconds; higher is calmer.
    var smoothing: Double = 0.22
    var hideWhenIdle: Bool = false
    var idleDelay: Double = 2.5
    var clickHighlight: Bool = true
    /// Ease the pointer back to where it started, for a seamless loop.
    var loopToStart: Bool = false
}

// MARK: - Zoom

enum ZoomMode: String, Codable, CaseIterable, Identifiable {
    /// Point at the clicks that fall inside the segment.
    case auto
    /// Point at a fixed spot the user placed.
    case manual
    /// Track the pointer for the whole segment.
    case followCursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .followCursor: return "Follow cursor"
        }
    }
}

struct ZoomSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Full extent of the segment in *source* time, ramps included. Keeping
    /// zooms in source time means cuts and speed changes carry them along.
    var start: Double
    var end: Double
    /// Peak magnification, 1.0 = no zoom.
    var scale: Double
    var easeIn: Double = 0.55
    var easeOut: Double = 0.7
    var mode: ZoomMode = .auto
    var anchor: NPoint = .center
    /// Auto-generated segments are replaced when auto-zoom is regenerated;
    /// hand-made or hand-edited ones are kept.
    var isManual: Bool = false
    /// Kept on the timeline but not applied.
    var isEnabled: Bool = true

    var duration: Double { max(0, end - start) }

    /// Ramps clipped so they always fit inside the segment.
    var effectiveRamps: (inRamp: Double, outRamp: Double) {
        let d = duration
        guard d > 0 else { return (0, 0) }
        let i = max(0.01, easeIn)
        let o = max(0.01, easeOut)
        let total = i + o
        if total <= d { return (i, o) }
        let k = d / total
        return (i * k, o * k)
    }
}

struct AutoZoomSettings: Codable {
    var enabled: Bool = true
    /// Magnification used for bursts that contain a click.
    var clickScale: Double = 2.0
    /// Magnification used for scroll-only bursts.
    var scrollScale: Double = 1.5
    /// How long the camera takes to move in, and how early it starts.
    var leadIn: Double = 0.55
    /// Extra time held at full zoom after the last event in a burst.
    var hold: Double = 1.0
    var easeOut: Double = 0.7
    /// Events further apart than this start a new burst.
    var clusterGap: Double = 1.7
    /// Events further from the burst centroid than this start a new burst.
    var clusterRadius: Double = 0.24
    var minDuration: Double = 1.6
    /// Zooms track the pointer rather than sitting on the click that caused
    /// them. On by default: while magnified, a still camera loses the cursor
    /// the moment it moves anywhere else.
    var followCursor: Bool = true
    /// Even for zooms aimed at a fixed spot, pan just enough to keep the
    /// pointer inside the frame instead of letting it walk off the edge.
    var keepCursorInFrame: Bool = true
}

// MARK: - Masks and highlights

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case blur
    case solid
    case highlight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur: return "Blur"
        case .solid: return "Solid"
        case .highlight: return "Highlight"
        }
    }
}

/// A rectangle applied over part of the recording for part of its length.
/// Masks hide, highlights draw the eye by dimming everything else.
struct MaskRegion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Source time.
    var start: Double
    var end: Double
    var rect: NRect = NRect(0.35, 0.4, 0.3, 0.2)
    var kind: MaskKind = .blur
    var opacity: Double = 1
    var blurRadius: Double = 40
    var cornerRadius: Double = 0.01

    /// Source span a newly added mask should cover: the whole clip it lands in.
    ///
    /// A blur is nearly always hiding something that's on screen for the whole
    /// shot — a customer name, an API key, a colleague's face. A three-second
    /// default meant dragging the edges out every single time, and a mask that
    /// stops early leaks exactly what it was there to cover.
    static func defaultSpan(
        atOutput t: Double, timeline: Timeline, bounds: ClosedRange<Double>
    ) -> (start: Double, end: Double) {
        if let entry = timeline.entry(atOutput: t) {
            return (max(bounds.lowerBound, entry.sourceStart),
                    min(bounds.upperBound, entry.sourceEnd))
        }
        // Off the end of the timeline: fall back to a span around the playhead.
        let source = timeline.sourceTime(at: t)
        let start = max(bounds.lowerBound, source - 0.2)
        return (start, min(bounds.upperBound, start + 3.0))
    }
}

// MARK: - Keyboard shortcut labels

/// Screen Studio shows the shortcuts you pressed as captions. Needs key events,
/// which means Accessibility permission at capture time.
struct ShortcutSettings: Codable {
    var show: Bool = false
    /// Multiplier on the label size.
    var size: Double = 1.0
    /// Plain letters as well as ⌘-style combinations.
    var includeSingleKeys: Bool = false
    /// How long a label stays on screen.
    var duration: Double = 1.6
}

/// Default applied when typing runs are turned into their own clips.
struct TypingSettings: Codable {
    var speed: Double = 2.0
}

// MARK: - Text callouts

enum TextStyle: String, Codable, CaseIterable, Identifiable {
    /// Just the words — for title cards over a plain background.
    case plain
    /// Words on a rounded chip, legible over any part of a recording.
    case pill
    /// A wider panel, for a sentence rather than a label.
    case card

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A caption placed over the recording for part of its length: a title card, or
/// a label pointing at the thing you just shipped.
struct TextOverlay: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Source time, like every other timed thing here.
    var start: Double
    var end: Double
    var text: String = "New in this release"
    /// Normalized position within the recording, top-left origin.
    var position: NPoint = NPoint(0.5, 0.12)
    /// Multiplier on the base size, which scales with the canvas.
    var size: Double = 1
    var color: RGBAColor = RGBAColor(1, 1, 1)
    var background: RGBAColor = RGBAColor(0.05, 0.05, 0.07, 0.78)
    var style: TextStyle = .pill
    var bold: Bool = true
    /// Appearing and vanishing on a hard cut reads as a glitch.
    var fadeIn: Double = 0.25
    var fadeOut: Double = 0.25

    var duration: Double { max(0, end - start) }

    /// How opaque the callout is at `t`, ramping in and out.
    ///
    /// Ramps are clipped to half the span each, so a callout shorter than its
    /// own fades still reaches full strength instead of never quite appearing.
    func opacity(at t: Double) -> Double {
        guard t >= start, t <= end else { return 0 }
        let span = max(0.01, duration)
        let inRamp = min(max(0, fadeIn), span / 2)
        let outRamp = min(max(0, fadeOut), span / 2)
        if inRamp > 0, t < start + inRamp {
            return CameraSolver.ease((t - start) / inRamp)
        }
        if outRamp > 0, t > end - outRamp {
            return CameraSolver.ease((end - t) / outRamp)
        }
        return 1
    }
}

/// A brand mark held in one corner for the whole clip.
struct WatermarkSettings: Codable {
    var enabled: Bool = false
    /// Absolute path; the image is not copied into the project.
    var imagePath: String?
    var corner: WebcamCorner = .topRight
    /// Fraction of the canvas' smaller dimension.
    var size: Double = 0.1
    var margin: Double = 0.03
    var opacity: Double = 0.85
}

// MARK: - Webcam overlay

enum WebcamShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded, square
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum WebcamCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
}

struct WebcamSettings: Codable {
    var enabled: Bool = true
    var shape: WebcamShape = .circle
    /// Fraction of the canvas' smaller dimension.
    var size: Double = 0.22
    var corner: WebcamCorner = .bottomLeft
    var margin: Double = 0.03
    var mirrored: Bool = true
    var shadowOpacity: Double = 0.45
}

// MARK: - The edit

struct EditModel: Codable {
    var clips: [Clip] = []
    var background = BackgroundSettings()
    var autoZoom = AutoZoomSettings()
    var segments: [ZoomSegment] = []
    var cursor = CursorSettings()
    var frame = FrameSettings()
    var masks: [MaskRegion] = []
    var webcam = WebcamSettings()
    var shortcuts = ShortcutSettings()
    var typing = TypingSettings()
    var texts: [TextOverlay] = []
    var watermark = WatermarkSettings()

    init() {}

    /// Total length after cuts and speed changes.
    var outputDuration: Double { clips.reduce(0) { $0 + $1.outputDuration } }

    /// Earliest and latest source time still in the edit.
    var sourceRange: ClosedRange<Double> {
        guard let first = clips.first, let last = clips.last else { return 0...0.01 }
        return first.sourceStart...max(first.sourceStart + 0.01, last.sourceEnd)
    }

    /// Reads older project files, which had a single trim range and no clips.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(BackgroundSettings.self, forKey: .background) ?? BackgroundSettings()
        autoZoom = try c.decodeIfPresent(AutoZoomSettings.self, forKey: .autoZoom) ?? AutoZoomSettings()
        segments = try c.decodeIfPresent([ZoomSegment].self, forKey: .segments) ?? []
        cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? CursorSettings()
        frame = try c.decodeIfPresent(FrameSettings.self, forKey: .frame) ?? FrameSettings()
        masks = try c.decodeIfPresent([MaskRegion].self, forKey: .masks) ?? []
        webcam = try c.decodeIfPresent(WebcamSettings.self, forKey: .webcam) ?? WebcamSettings()
        shortcuts = try c.decodeIfPresent(ShortcutSettings.self, forKey: .shortcuts) ?? ShortcutSettings()
        typing = try c.decodeIfPresent(TypingSettings.self, forKey: .typing) ?? TypingSettings()
        texts = try c.decodeIfPresent([TextOverlay].self, forKey: .texts) ?? []
        watermark = try c.decodeIfPresent(WatermarkSettings.self, forKey: .watermark)
            ?? WatermarkSettings()

        if let stored = try c.decodeIfPresent([Clip].self, forKey: .clips), !stored.isEmpty {
            clips = stored
        } else {
            let start = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
            let end = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
            clips = end > start ? [Clip(sourceStart: start, sourceEnd: end)] : []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clips, forKey: .clips)
        try c.encode(background, forKey: .background)
        try c.encode(autoZoom, forKey: .autoZoom)
        try c.encode(segments, forKey: .segments)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(frame, forKey: .frame)
        try c.encode(masks, forKey: .masks)
        try c.encode(webcam, forKey: .webcam)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(typing, forKey: .typing)
        try c.encode(texts, forKey: .texts)
        try c.encode(watermark, forKey: .watermark)
    }

    private enum CodingKeys: String, CodingKey {
        case clips, background, autoZoom, segments, cursor, frame, masks, webcam
        case shortcuts, typing, texts, watermark
        case trimStart, trimEnd
    }
}

// MARK: - Export

struct ExportSettings: Codable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case mp4, mov, gif
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var isAnimatedImage: Bool { self == .gif }
        var contentType: UTType {
            switch self {
            case .mp4: return .mpeg4Movie
            case .mov: return .quickTimeMovie
            case .gif: return .gif
            }
        }
    }

    enum Quality: String, Codable, CaseIterable, Identifiable {
        case social, high, best
        var id: String { rawValue }
        var label: String {
            switch self {
            case .social: return "Smaller file"
            case .high: return "High"
            case .best: return "Best"
            }
        }
        /// Bits per pixel per frame.
        var bitsPerPixel: Double {
            switch self {
            case .social: return 0.05
            case .high: return 0.1
            case .best: return 0.2
            }
        }
    }

    /// Width of the exported video; height follows the canvas aspect ratio.
    var width: Int = 1920
    var fps: Int = 60
    var format: Format = .mp4
    var quality: Quality = .high

    static let widthChoices = [854, 1280, 1920, 2560, 3840]
}

// MARK: - App-wide preferences

enum PreviewQuality: String, Codable, CaseIterable, Identifiable {
    case quality, performance, powerSaving

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quality: return "Quality"
        case .performance: return "Performance"
        case .powerSaving: return "Power saving"
        }
    }

    var detail: String {
        switch self {
        case .quality: return "Preview matches the export exactly."
        case .performance: return "Renders smaller for a smoother playhead."
        case .powerSaving: return "Lowest CPU and GPU use."
        }
    }

    var previewWidth: Int {
        switch self {
        case .quality: return 2560
        case .performance: return 1280
        case .powerSaving: return 854
        }
    }

    var previewFPS: Int {
        switch self {
        case .quality: return 60
        case .performance: return 30
        case .powerSaving: return 24
        }
    }
}

// MARK: - Tolerant decoding
//
// Swift's synthesized `Decodable` does NOT fall back to a property's default
// when a key is missing — it throws. That makes every stored project fail to
// load the moment a new setting is added, which is exactly what happened when
// `FrameSettings.device` arrived: existing edit.json files had no "device" key,
// decoding threw, and the edit silently reverted to defaults.
//
// These initialisers decode each field with `decodeIfPresent` and keep the
// default when it's absent, so a project written by any earlier build still
// opens with everything it had. They live in this file because a synthesized
// `CodingKeys` is private, and `private` reaches extensions in the same file.

extension BackgroundSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        kind = try c.decodeIfPresent(BackgroundKind.self, forKey: .kind) ?? kind
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? blurRadius
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? dim
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        wallpaper = try c.decodeIfPresent(Wallpaper.self, forKey: .wallpaper) ?? wallpaper
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color) ?? color
        gradientTop = try c.decodeIfPresent(RGBAColor.self, forKey: .gradientTop) ?? gradientTop
        gradientBottom = try c.decodeIfPresent(RGBAColor.self, forKey: .gradientBottom) ?? gradientBottom
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? cornerRadius
        inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? inset
        insetColor = try c.decodeIfPresent(RGBAColor.self, forKey: .insetColor) ?? insetColor
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? shadowOpacity
        shadowRadius = try c.decodeIfPresent(Double.self, forKey: .shadowRadius) ?? shadowRadius
        shadowOffsetY = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetY) ?? shadowOffsetY
    }
}

extension FrameSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        aspect = try c.decodeIfPresent(AspectRatio.self, forKey: .aspect) ?? aspect
        device = try c.decodeIfPresent(DeviceFrame.self, forKey: .device) ?? device
        alwaysZoomedIn = try c.decodeIfPresent(Bool.self, forKey: .alwaysZoomedIn) ?? alwaysZoomedIn
        crop = try c.decodeIfPresent(NRect.self, forKey: .crop) ?? crop
    }
}

extension CursorSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        mode = try c.decodeIfPresent(CursorMode.self, forKey: .mode) ?? mode
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        hideWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? hideWhenIdle
        idleDelay = try c.decodeIfPresent(Double.self, forKey: .idleDelay) ?? idleDelay
        clickHighlight = try c.decodeIfPresent(Bool.self, forKey: .clickHighlight) ?? clickHighlight
        loopToStart = try c.decodeIfPresent(Bool.self, forKey: .loopToStart) ?? loopToStart
    }
}

extension AutoZoomSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        clickScale = try c.decodeIfPresent(Double.self, forKey: .clickScale) ?? clickScale
        scrollScale = try c.decodeIfPresent(Double.self, forKey: .scrollScale) ?? scrollScale
        leadIn = try c.decodeIfPresent(Double.self, forKey: .leadIn) ?? leadIn
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? hold
        easeOut = try c.decodeIfPresent(Double.self, forKey: .easeOut) ?? easeOut
        clusterGap = try c.decodeIfPresent(Double.self, forKey: .clusterGap) ?? clusterGap
        clusterRadius = try c.decodeIfPresent(Double.self, forKey: .clusterRadius) ?? clusterRadius
        minDuration = try c.decodeIfPresent(Double.self, forKey: .minDuration) ?? minDuration
        followCursor = try c.decodeIfPresent(Bool.self, forKey: .followCursor) ?? followCursor
        keepCursorInFrame = try c.decodeIfPresent(Bool.self, forKey: .keepCursorInFrame) ?? keepCursorInFrame
    }
}

extension WebcamSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        shape = try c.decodeIfPresent(WebcamShape.self, forKey: .shape) ?? shape
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        corner = try c.decodeIfPresent(WebcamCorner.self, forKey: .corner) ?? corner
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? mirrored
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? shadowOpacity
    }
}

extension ShortcutSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? show
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        includeSingleKeys = try c.decodeIfPresent(Bool.self, forKey: .includeSingleKeys) ?? includeSingleKeys
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? duration
    }
}

extension TypingSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
    }
}

extension Clip {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceStart: try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0,
            sourceEnd: try c.decodeIfPresent(Double.self, forKey: .sourceEnd) ?? 0
        )
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? volume
        isTyping = try c.decodeIfPresent(Bool.self, forKey: .isTyping) ?? isTyping
    }
}

extension ZoomSegment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try c.decodeIfPresent(Double.self, forKey: .start) ?? 0,
            end: try c.decodeIfPresent(Double.self, forKey: .end) ?? 0,
            scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        )
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        easeIn = try c.decodeIfPresent(Double.self, forKey: .easeIn) ?? easeIn
        easeOut = try c.decodeIfPresent(Double.self, forKey: .easeOut) ?? easeOut
        mode = try c.decodeIfPresent(ZoomMode.self, forKey: .mode) ?? mode
        anchor = try c.decodeIfPresent(NPoint.self, forKey: .anchor) ?? anchor
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? isManual
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
    }
}

extension MaskRegion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try c.decodeIfPresent(Double.self, forKey: .start) ?? 0,
            end: try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        )
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        rect = try c.decodeIfPresent(NRect.self, forKey: .rect) ?? rect
        kind = try c.decodeIfPresent(MaskKind.self, forKey: .kind) ?? kind
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? blurRadius
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? cornerRadius
    }
}


extension TextOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try c.decodeIfPresent(Double.self, forKey: .start) ?? 0,
            end: try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        )
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        position = try c.decodeIfPresent(NPoint.self, forKey: .position) ?? position
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color) ?? color
        background = try c.decodeIfPresent(RGBAColor.self, forKey: .background) ?? background
        style = try c.decodeIfPresent(TextStyle.self, forKey: .style) ?? style
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? bold
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? fadeIn
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? fadeOut
    }
}

extension WatermarkSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        corner = try c.decodeIfPresent(WebcamCorner.self, forKey: .corner) ?? corner
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    }
}
