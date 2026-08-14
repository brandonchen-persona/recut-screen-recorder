import Foundation
import AVFoundation
import CoreImage
import AppKit
import ScreenCaptureKit

/// Headless entry points. `--render` is a genuine batch-export path; `--frames`
/// exists to eyeball the compositor without launching the UI.
enum CLI {

    static func run(_ args: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        switch args.first {
        case "--render":
            render(Array(args.dropFirst()))
        case "--frames":
            frames(Array(args.dropFirst()))
        case "--typing":
            typing(Array(args.dropFirst()))
        case "--test":
            exit(TestSuites.run())
        case "--bench":
            bench(Array(args.dropFirst()))
        case "--waveform":
            waveform(Array(args.dropFirst()))
        case "--windows":
            listWindows()
        default:
            print("""
            Recut

              Recut                                     open the app
              Recut --render <project.recut> <out.mp4> [width] [fps]
              Recut --frames <project.recut> <outDir> <t1,t2,…> [width]
              Recut --typing <project.recut> [--apply [speed]]
              Recut --waveform <project.recut>          summarise the audio envelope
              Recut --test                              run the engine test suite
            """)
            exit(args.first == "--help" ? 0 : 1)
        }
    }

    // MARK: - Batch export

    private static func render(_ args: [String]) {
        guard args.count >= 2 else { fail("Usage: --render <project.recut> <out.mp4> [width] [fps]") }
        let projectURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[1])
        let width = args.count > 2 ? Int(args[2]) ?? 1920 : 1920
        let fps = args.count > 3 ? Int(args[3]) ?? 60 : 60

        let done = DispatchSemaphore(value: 0)
        var failure: Error?

        Task { @MainActor in
            do {
                let project = try Project.load(projectURL)
                var settings = ExportSettings()
                settings.width = width
                settings.fps = fps
                settings.format = ExportSettings.Format(
                    rawValue: outURL.pathExtension.lowercased()
                ) ?? .mp4

                if let failure = project.editLoadFailure {
                    print("!! edit.json could not be read — rendering with defaults: \(failure)")
                }
                print("Rendering \(project.name): \(project.edit.clips.count) clip(s), "
                      + "\(project.edit.segments.count) zoom(s), "
                      + String(format: "%.2fs", project.edit.outputDuration))
                let exporter = Exporter()
                try await exporter.export(
                    project: project, edit: project.edit, settings: settings, to: outURL
                )
                print("Wrote \(outURL.path)")
            } catch {
                failure = error
            }
            done.signal()
        }

        // The export hops through the main actor, so pump the run loop.
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let failure { fail(failure.localizedDescription) }
        exit(0)
    }

    // MARK: - Still frames

    private static func frames(_ args: [String]) {
        guard args.count >= 3 else { fail("Usage: --frames <project.recut> <outDir> <t1,t2,…> [width]") }
        let projectURL = URL(fileURLWithPath: args[0])
        let outDir = URL(fileURLWithPath: args[1])
        let times = args[2].split(separator: ",").compactMap { Double($0) }
        let width = args.count > 3 ? Int(args[3]) ?? 1280 : 1280

        do {
            let project = try Project.load(projectURL)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let asset = AVURLAsset(url: project.videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let renderer = FrameRenderer()
            let context = CIContext()
            let canvasSize = CompositionBuilder.canvasSize(
                forWidth: width, source: project.meta.size, frame: project.edit.frame
            )
            let canvas = CGRect(origin: .zero, size: canvasSize)

            var snapshot = RenderSnapshot()
            snapshot.timeline = Timeline(clips: project.edit.clips)
            snapshot.segments = project.edit.segments
            snapshot.background = project.edit.background
            snapshot.frame = project.edit.frame
            snapshot.cursorSettings = project.edit.cursor
            snapshot.masks = project.edit.masks
            snapshot.webcam = project.edit.webcam
            snapshot.shortcuts = project.edit.shortcuts
            snapshot.texts = project.edit.texts
            snapshot.watermark = project.edit.watermark
            snapshot.keepCursorInFrame = project.edit.autoZoom.keepCursorInFrame
            snapshot.keyEvents = project.events.filter { $0.kind == .key }
            snapshot.cursor = CursorPath(
                events: project.events,
                duration: project.meta.duration,
                settings: project.edit.cursor
            )

            print("\(project.edit.segments.count) zoom segment(s):")
            for s in project.edit.segments {
                print(String(format: "  %.2f→%.2fs  %.2f×  anchor (%.2f, %.2f)  %@",
                             s.start, s.end, s.scale, s.anchor.x, s.anchor.y, s.mode.label))
            }

            for t in times {
                let cgImage = try generator.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                )
                let camera = CameraSolver.camera(
                    at: t, segments: project.edit.segments, cursor: snapshot.cursor,
                    keepCursorInFrame: snapshot.keepCursorInFrame
                )
                let image = renderer.render(
                    source: CIImage(cgImage: cgImage),
                    canvas: canvas,
                    sourceTime: t,
                    snapshot: snapshot
                )
                guard let out = context.createCGImage(image, from: canvas) else { continue }
                let url = outDir.appendingPathComponent(String(format: "frame_%06.2f.png", t))
                let rep = NSBitmapImageRep(cgImage: out)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                try data.write(to: url)
                print(String(format: "t=%.2f  scale %.2f×  center (%.2f, %.2f)  →  %@",
                             t, camera.scale, camera.center.x, camera.center.y,
                             url.lastPathComponent))
            }
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    // MARK: - Typing

    /// Reports the typing runs the detector finds, and optionally cuts them
    /// into their own sped-up clips.
    private static func typing(_ args: [String]) {
        guard let path = args.first else { fail("Usage: --typing <project.recut> [--apply [speed]]") }
        let apply = args.contains("--apply")
        let speed = args.last.flatMap(Double.init) ?? 2.0

        do {
            let project = try Project.load(URL(fileURLWithPath: path))
            let keys = project.events.filter { $0.kind == .key }
            print("\(keys.count) key press(es) recorded")

            let ranges = TypingDetector.detect(
                events: project.events, range: project.edit.sourceRange
            )
            guard !ranges.isEmpty else {
                print("No typing runs found.")
                exit(0)
            }
            for range in ranges {
                print(String(format: "  typing %.2f→%.2fs (%.2fs)",
                             range.lowerBound, range.upperBound,
                             range.upperBound - range.lowerBound))
            }

            if apply {
                project.edit.clips = TypingDetector.apply(
                    ranges: ranges, to: project.edit.clips, speed: speed
                )
                try project.save()
                let typingClips = project.edit.clips.filter(\.isTyping).count
                print(String(format: "Applied %.1f× to %d clip(s); timeline is now %.2fs",
                             speed, typingClips, project.edit.outputDuration))
            }
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    // MARK: - Benchmark

    /// Times the compositor while a setting is swept, the way dragging a slider
    /// does. Decoding happens once up front so the numbers are the renderer's.
    private static func bench(_ args: [String]) {
        guard let path = args.first else { fail("Usage: --bench <project.recut> [width] [frames]") }
        let width = args.count > 1 ? Int(args[1]) ?? 1280 : 1280
        let frames = args.count > 2 ? Int(args[2]) ?? 60 : 60

        do {
            let project = try Project.load(URL(fileURLWithPath: path))
            let asset = AVURLAsset(url: project.videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let source = CIImage(cgImage: try generator.copyCGImage(
                at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil
            ))

            let renderer = FrameRenderer()
            let context = CIContext(options: [.cacheIntermediates: false])
            let canvasSize = CompositionBuilder.canvasSize(
                forWidth: width, source: project.meta.size, frame: project.edit.frame
            )
            let canvas = CGRect(origin: .zero, size: canvasSize)

            var snapshot = RenderSnapshot()
            snapshot.timeline = Timeline(clips: project.edit.clips)
            snapshot.segments = project.edit.segments
            snapshot.background = project.edit.background
            snapshot.frame = project.edit.frame
            snapshot.cursorSettings = project.edit.cursor
            snapshot.cursor = CursorPath(
                events: project.events, duration: project.meta.duration,
                settings: project.edit.cursor
            )

            func time(_ label: String, _ body: (Int) -> Void) {
                // One pass to warm the caches and the Metal pipeline.
                body(0)
                let start = CACurrentMediaTime()
                for i in 0..<frames { body(i) }
                let ms = (CACurrentMediaTime() - start) / Double(frames) * 1000
                print(String(format: "  %-22s %6.2f ms/frame   %5.1f fps", (label as NSString).utf8String!, ms, 1000 / ms))
            }

            print("Compositor at \(Int(canvasSize.width))×\(Int(canvasSize.height)), \(frames) frames")

            time("steady (no change)") { _ in
                let image = renderer.render(
                    source: source, canvas: canvas, sourceTime: 1, snapshot: snapshot
                )
                _ = context.createCGImage(image, from: canvas)
            }

            // Sweeping padding resizes the screen layer every frame, which is
            // what a slider drag does.
            time("padding sweep") { i in
                var s = snapshot
                s.background.padding = 0.02 + 0.14 * Double(i % 30) / 30
                let image = renderer.render(
                    source: source, canvas: canvas, sourceTime: 1, snapshot: s
                )
                _ = context.createCGImage(image, from: canvas)
            }

            time("blur radius sweep") { i in
                var s = snapshot
                s.background.blurRadius = 20 + 180 * Double(i % 30) / 30
                let image = renderer.render(
                    source: source, canvas: canvas, sourceTime: 1, snapshot: s
                )
                _ = context.createCGImage(image, from: canvas)
            }

            // Moving the playhead needs a fresh source frame; moving a slider
            // does not. This is the cost of the former.
            let decodeGenerator = AVAssetImageGenerator(asset: asset)
            decodeGenerator.appliesPreferredTrackTransform = true
            decodeGenerator.requestedTimeToleranceBefore = .zero
            decodeGenerator.requestedTimeToleranceAfter = .zero
            time("still decode (scrub)") { i in
                let t = 1 + Double(i % 20) * 0.35
                _ = try? decodeGenerator.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                )
            }

            // What the editor used to do when a slider moved: nudge the player
            // and let AVFoundation redraw the paused frame.
            benchPreviewSeek(project: project, width: width, frames: min(frames, 20))
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    private static func benchPreviewSeek(project: Project, width: Int, frames: Int) {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { done.signal() }
            let controller = PlayerController()
            let state = RenderState()
            guard (try? await controller.load(url: project.videoURL)) != nil else { return }
            state.update {
                $0.timeline = Timeline(clips: project.edit.clips)
                $0.segments = project.edit.segments
                $0.background = project.edit.background
            }
            try? controller.rebuild(
                clips: project.edit.clips, frame: project.edit.frame,
                state: state, quality: .performance
            )
            guard let item = controller.player.currentItem else { return }
            while item.status != .readyToPlay {
                if item.status == .failed { return }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }

            let start = CACurrentMediaTime()
            for i in 0..<frames {
                // Same call refresh() makes: exact seek, half-millisecond jitter.
                let t = 4.0 + (i % 2 == 0 ? 0.0005 : 0)
                await controller.player.seek(
                    to: CMTime(seconds: t, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
            let ms = (CACurrentMediaTime() - start) / Double(frames) * 1000
            print(String(format: "  %-22s %6.2f ms/seek    %5.1f fps",
                         ("preview refresh seek" as NSString).utf8String!, ms, 1000 / ms))
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Dumps every window ScreenCaptureKit reports, so the picker's filtering
    /// can be checked against reality rather than guessed at.
    /// Prints the audio envelope of a project, to check the waveform lane is
    /// being fed real data rather than a flat line.
    private static func waveform(_ args: [String]) {
        guard let path = args.first else {
            print("usage: Recut --waveform <project.recut>")
            exit(2)
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let project = try Project.load(URL(fileURLWithPath: path))
                let wave = try await WaveformExtractor.extract(from: project.videoURL)
                if wave.isEmpty {
                    print("no audio track")
                    exit(1)
                }
                print(String(format: "%d buckets at %.1f/s  (%.2fs)",
                             wave.peaks.count, wave.rate, wave.duration))
                let seconds = Int(wave.duration.rounded(.down))
                for second in 0..<max(1, seconds) {
                    let peak = wave.peak(from: Double(second), to: Double(second + 1))
                    print(String(format: "  %2ds  %.3f  %@", second, peak,
                                 String(repeating: "█", count: Int(peak * 40))))
                }
                let loudest = wave.peaks.max() ?? 0
                print(String(format: "peak %.3f", loudest))
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func listWindows() {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            ) else {
                print("Could not read shareable content — is Screen Recording granted?")
                return
            }
            print("\(content.windows.count) window(s) reported\n")
            print("layer  onScr  size       app                    title")
            for w in content.windows.sorted(by: { $0.windowLayer < $1.windowLayer }) {
                let app = w.owningApplication?.applicationName ?? "—"
                let size = "\(Int(w.frame.width))x\(Int(w.frame.height))"
                print(String(format: "%-6d %-7@ %-9@ %-22@ %@",
                             w.windowLayer,
                             (w.isOnScreen ? "yes" : "no") as NSString,
                             size as NSString,
                             app as NSString,
                             (w.title ?? "—") as NSString))
            }

            let offered = (try? await ScreenRecorder.shareableWindows()) ?? []
            print("\n\(offered.count) offered by the picker:")
            for w in offered {
                print("  \(w.owningApplication?.applicationName ?? "—") — \(w.title ?? "—")")
            }
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
