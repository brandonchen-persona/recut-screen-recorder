import Foundation
import AVFoundation
import CoreGraphics
import AppKit

// Generates a synthetic .recut project — a fake "screen recording" plus a
// matching cursor track — so the editor, the compositor and the exporter can be
// exercised without needing screen recording permission or a real capture.

let width = 1920
let height = 1200
let fps = 30
let duration = 12.0

struct Keyframe {
    var t: Double
    var x: Double
    var y: Double
}

// Where the pointer goes, in normalized top-left coordinates.
let path: [Keyframe] = [
    Keyframe(t: 0.0, x: 0.50, y: 0.52),
    Keyframe(t: 1.2, x: 0.20, y: 0.30),
    Keyframe(t: 2.6, x: 0.21, y: 0.31),
    Keyframe(t: 4.1, x: 0.76, y: 0.62),
    Keyframe(t: 5.4, x: 0.75, y: 0.63),
    Keyframe(t: 6.8, x: 0.50, y: 0.50),
    Keyframe(t: 9.0, x: 0.51, y: 0.50),
    Keyframe(t: 10.1, x: 0.86, y: 0.16),
    Keyframe(t: 12.0, x: 0.86, y: 0.16),
]

let clickTimes: [Double] = [1.5, 4.5, 4.95, 10.4]
let scrollTimes: [Double] = stride(from: 7.2, through: 8.7, by: 0.15).map { $0 }

func cursor(at t: Double) -> CGPoint {
    guard let last = path.last else { return CGPoint(x: 0.5, y: 0.5) }
    if t <= path[0].t { return CGPoint(x: path[0].x, y: path[0].y) }
    if t >= last.t { return CGPoint(x: last.x, y: last.y) }
    for i in 0..<(path.count - 1) {
        let a = path[i], b = path[i + 1]
        if t >= a.t && t <= b.t {
            let raw = (t - a.t) / max(0.0001, b.t - a.t)
            // Ease so the synthetic pointer doesn't move like a robot.
            let u = raw * raw * (3 - 2 * raw)
            return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        }
    }
    return CGPoint(x: last.x, y: last.y)
}

// MARK: - Frame drawing

let colorSpace = CGColorSpaceCreateDeviceRGB()

func drawFrame(_ ctx: CGContext, t: Double) {
    let w = CGFloat(width), h = CGFloat(height)

    ctx.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // Faint grid so the magnification is obvious at a glance.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
    ctx.setLineWidth(1)
    for x in stride(from: 0, through: w, by: 40) {
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h))
    }
    for y in stride(from: 0, through: h, by: 40) {
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
    }
    ctx.strokePath()

    // Sidebar.
    ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w * 0.16, height: h))
    for i in 0..<8 {
        let y = h - 120 - CGFloat(i) * 62
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
        ctx.fill(CGRect(x: 24, y: y, width: w * 0.16 - 60, height: 26))
    }

    // Content cards.
    let cards: [CGRect] = [
        CGRect(x: w * 0.19, y: h * 0.55, width: w * 0.36, height: h * 0.3),
        CGRect(x: w * 0.58, y: h * 0.55, width: w * 0.36, height: h * 0.3),
        CGRect(x: w * 0.19, y: h * 0.12, width: w * 0.75, height: h * 0.34),
    ]
    for (i, card) in cards.enumerated() {
        ctx.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.4, green: 0.62, blue: 0.95, alpha: 0.9))
        ctx.fill(CGRect(x: card.minX + 22, y: card.maxY - 46, width: 120 + CGFloat(i) * 40, height: 16))
        for line in 0..<4 {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
            ctx.fill(CGRect(
                x: card.minX + 22,
                y: card.maxY - 84 - CGFloat(line) * 26,
                width: card.width * (0.8 - CGFloat(line) * 0.13),
                height: 10
            ))
        }
    }

    // Buttons that light up when the script clicks them.
    let targets: [(CGPoint, Double)] = [
        (CGPoint(x: 0.20, y: 0.30), 1.5),
        (CGPoint(x: 0.76, y: 0.62), 4.5),
        (CGPoint(x: 0.86, y: 0.16), 10.4),
    ]
    for (p, clickAt) in targets {
        let center = CGPoint(x: p.x * w, y: (1 - p.y) * h)
        let rect = CGRect(x: center.x - 78, y: center.y - 21, width: 156, height: 42)
        let hot = abs(t - clickAt) < 0.18
        ctx.setFillColor(hot
            ? CGColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
            : CGColor(red: 0.28, green: 0.45, blue: 0.85, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fill(CGRect(x: rect.minX + 30, y: rect.midY - 5, width: 96, height: 10))
    }

    // Running clock, so scrubbing is verifiable frame by frame.
    let text = String(format: "t = %05.2fs", t)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.75),
    ]
    let line = NSAttributedString(string: text, attributes: attrs)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    line.draw(at: NSPoint(x: w * 0.19, y: h - 70))
    NSGraphicsContext.restoreGraphicsState()

    // Pointer.
    let c = cursor(at: t)
    let cp = CGPoint(x: c.x * w, y: (1 - c.y) * h)
    let arrow = CGMutablePath()
    arrow.move(to: cp)
    arrow.addLine(to: CGPoint(x: cp.x, y: cp.y - 30))
    arrow.addLine(to: CGPoint(x: cp.x + 8, y: cp.y - 22))
    arrow.addLine(to: CGPoint(x: cp.x + 14, y: cp.y - 33))
    arrow.addLine(to: CGPoint(x: cp.x + 20, y: cp.y - 30))
    arrow.addLine(to: CGPoint(x: cp.x + 13, y: cp.y - 19))
    arrow.addLine(to: CGPoint(x: cp.x + 22, y: cp.y - 18))
    arrow.closeSubpath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(arrow)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
    ctx.setLineWidth(1.5)
    ctx.addPath(arrow)
    ctx.strokePath()

    if let nearest = clickTimes.min(by: { abs($0 - t) < abs($1 - t) }), abs(t - nearest) < 0.35 {
        let age = abs(t - nearest) / 0.35
        ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 1 - age))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(
            x: cp.x - 10 - 34 * age, y: cp.y - 10 - 34 * age,
            width: 20 + 68 * age, height: 20 + 68 * age
        ))
    }
}

// MARK: - Encode

let projectURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/SampleRecording.recut")

try? FileManager.default.removeItem(at: projectURL)
try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

let videoURL = projectURL.appendingPathComponent("video.mov")
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
)
writer.add(input)

// A second video track standing in for a webcam, so the picture-in-picture
// path can be exercised without a real camera.
// Optional "WxH" second argument, so an odd-shaped virtual camera can be
// simulated — an ultra-wide one is what exposed the stretching bug.
let camSpec = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "640x480"
let camParts = camSpec.split(separator: "x").compactMap { Int($0) }
let camWidth = camParts.count == 2 ? camParts[0] : 640
let camHeight = camParts.count == 2 ? camParts[1] : 480
let camInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: camWidth,
    AVVideoHeightKey: camHeight,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
])
camInput.expectsMediaDataInRealTime = false
let camAdaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: camInput,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: camWidth,
        kCVPixelBufferHeightKey as String: camHeight,
    ]
)
writer.add(camInput)

func drawWebcamFrame(_ ctx: CGContext, t: Double) {
    let w = CGFloat(camWidth), h = CGFloat(camHeight)
    ctx.setFillColor(CGColor(red: 0.18, green: 0.22, blue: 0.30, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // A "person": shoulders and a head that drifts a little.
    let sway = CGFloat(sin(t * 0.9)) * 14
    ctx.setFillColor(CGColor(red: 0.90, green: 0.74, blue: 0.62, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w / 2 - 78 + sway, y: h * 0.34, width: 156, height: 186))
    ctx.setFillColor(CGColor(red: 0.24, green: 0.42, blue: 0.68, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w / 2 - 190 + sway * 0.5, y: -160, width: 380, height: 330))
    ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w / 2 - 44 + sway, y: h * 0.60, width: 20, height: 24))
    ctx.fillEllipse(in: CGRect(x: w / 2 + 24 + sway, y: h * 0.60, width: 20, height: 24))

    // Text so left/right is obvious once mirroring is on.
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let line = NSAttributedString(string: "CAM", attributes: attrs)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    line.draw(at: NSPoint(x: 18, y: h - 44))
    NSGraphicsContext.restoreGraphicsState()
}
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let totalFrames = Int(duration * Double(fps))

// Both tracks are fed from one loop. Writing every screen frame first and the
// camera frames afterwards deadlocks: AVAssetWriter stops accepting data for
// one input while another lags far behind, so they have to be interleaved.
func renderPixelBuffer(
    pool: CVPixelBufferPool?, width: Int, height: Int, draw: (CGContext) -> Void
) -> CVPixelBuffer? {
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let pixelBuffer = buffer else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: width, height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
        draw(ctx)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

var screenFrame = 0
var camFrame = 0

while screenFrame < totalFrames || camFrame < totalFrames {
    var progressed = false

    if screenFrame < totalFrames, input.isReadyForMoreMediaData {
        let t = Double(screenFrame) / Double(fps)
        if let buffer = renderPixelBuffer(
            pool: adaptor.pixelBufferPool, width: width, height: height,
            draw: { drawFrame($0, t: t) }
        ) {
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(screenFrame),
                                             timescale: CMTimeScale(fps))
            )
        }
        screenFrame += 1
        progressed = true
    }

    if camFrame < totalFrames, camInput.isReadyForMoreMediaData {
        let t = Double(camFrame) / Double(fps)
        if let buffer = renderPixelBuffer(
            pool: camAdaptor.pixelBufferPool, width: camWidth, height: camHeight,
            draw: { drawWebcamFrame($0, t: t) }
        ) {
            camAdaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(camFrame),
                                             timescale: CMTimeScale(fps))
            )
        }
        camFrame += 1
        progressed = true
    }

    if !progressed { usleep(2000) }
}

input.markAsFinished()
camInput.markAsFinished()

let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()

if let error = writer.error {
    FileHandle.standardError.write("Failed to write sample video: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Sidecar files

struct SampleEvent: Encodable {
    var t: Double
    var kind: String
    var x: Double
    var y: Double
}

var events: [SampleEvent] = []
for i in 0...Int(duration * 60) {
    let t = Double(i) / 60.0
    let p = cursor(at: t)
    events.append(SampleEvent(t: t, kind: "move", x: p.x, y: p.y))
}
for t in clickTimes {
    let p = cursor(at: t)
    events.append(SampleEvent(t: t, kind: "click", x: p.x, y: p.y))
}
for t in scrollTimes {
    let p = cursor(at: t)
    events.append(SampleEvent(t: t, kind: "scroll", x: p.x, y: p.y))
}
events.sort { $0.t < $1.t }

struct SampleMeta: Encodable {
    var width: Int
    var height: Int
    var duration: Double
    var fps: Int
    var createdAt: Date
    var videoFile: String
    var displayName: String?
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

try encoder.encode(events).write(to: projectURL.appendingPathComponent("events.json"))
try encoder.encode(SampleMeta(
    width: width, height: height, duration: duration, fps: fps,
    createdAt: Date(), videoFile: "video.mov", displayName: "Synthetic Display"
)).write(to: projectURL.appendingPathComponent("meta.json"))

print("Wrote \(projectURL.path)")
