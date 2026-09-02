import Foundation
import CoreGraphics

/// Tests for the pure parts of the engine: the timeline mapping, the zoom
/// planner, the camera solver, the cursor path, typing detection, canvas
/// sizing, callout fades, audio metering, and project decoding.
///
/// Nothing here touches AVFoundation, Core Image or the file system, so the
/// whole suite runs in well under a second.
enum TestSuites {

    static func run() -> Int32 {
        let t = TestRunner()
        timeline(t)
        zoomPlanner(t)
        cameraSolver(t)
        cursorPath(t)
        typingDetector(t)
        canvasSizing(t)
        history(t)
        rulerTicks(t)
        areaGeometry(t)
        textOverlays(t)
        audio(t)
        masks(t)
        rectDrag(t)
        cursorRebase(t)
        projectDecoding(t)
        return t.finish()
    }

    // MARK: - Text callouts

    private static func textOverlays(_ t: TestRunner) {
        t.suite("TextOverlay fades") {
            t.test("outside its span the callout is invisible") {
                let overlay = TextOverlay(start: 2, end: 5)
                t.close(overlay.opacity(at: 1.99), 0, "before")
                t.close(overlay.opacity(at: 5.01), 0, "after")
            }

            t.test("it reaches full strength between the ramps") {
                let overlay = TextOverlay(start: 2, end: 5)
                t.close(overlay.opacity(at: 3.5), 1, "middle")
                t.expect(overlay.opacity(at: 2.1) < 1, "still ramping in")
                t.expect(overlay.opacity(at: 4.9) < 1, "already ramping out")
            }

            t.test("the ramp is monotonic in and out") {
                let overlay = TextOverlay(start: 0, end: 4, fadeIn: 1, fadeOut: 1)
                t.expect(overlay.opacity(at: 0.25) < overlay.opacity(at: 0.75),
                         "rises through the fade in")
                t.expect(overlay.opacity(at: 3.25) > overlay.opacity(at: 3.75),
                         "falls through the fade out")
            }

            // A callout dragged shorter than its own fades would otherwise
            // never reach full opacity, which reads as a flicker.
            t.test("a callout shorter than its fades still peaks at full") {
                let overlay = TextOverlay(start: 0, end: 0.4, fadeIn: 1, fadeOut: 1)
                t.close(overlay.opacity(at: 0.2), 1, "peak at the midpoint")
            }

            t.test("zero-length ramps snap on and off") {
                let overlay = TextOverlay(start: 1, end: 3, fadeIn: 0, fadeOut: 0)
                t.close(overlay.opacity(at: 1), 1, "on at the start")
                t.close(overlay.opacity(at: 3), 1, "on at the end")
                t.close(overlay.opacity(at: 3.001), 0, "off just past it")
            }

            t.test("negative fades are treated as none") {
                let overlay = TextOverlay(start: 0, end: 2, fadeIn: -1, fadeOut: -1)
                t.close(overlay.opacity(at: 0), 1, "no ramp in")
                t.close(overlay.opacity(at: 2), 1, "no ramp out")
            }
        }
    }

    // MARK: - Masks

    private static func masks(_ t: TestRunner) {
        t.suite("MaskRegion.defaultSpan") {
            // A blur usually covers something on screen for the whole shot, so
            // a new one takes the clip rather than an arbitrary few seconds.
            t.test("a new mask covers the clip it lands in") {
                let timeline = Timeline(clips: [
                    Clip(sourceStart: 0, sourceEnd: 4),
                    Clip(sourceStart: 10, sourceEnd: 16),
                ])
                let span = MaskRegion.defaultSpan(
                    atOutput: 5, timeline: timeline, bounds: 0...16
                )
                t.close(span.start, 10, "start of the second clip")
                t.close(span.end, 16, "end of the second clip")
            }

            t.test("it stays inside the usable source range") {
                let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 20)])
                let span = MaskRegion.defaultSpan(
                    atOutput: 1, timeline: timeline, bounds: 2...9
                )
                t.close(span.start, 2, "clamped start")
                t.close(span.end, 9, "clamped end")
            }

            t.test("past the end of the timeline it falls back to a short span") {
                let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 4)])
                let span = MaskRegion.defaultSpan(
                    atOutput: 99, timeline: timeline, bounds: 0...4
                )
                t.expect(span.end > span.start, "still a usable span")
                t.expect(span.end <= 4.0001, "inside the source")
            }

            t.test("an empty timeline still produces something usable") {
                let span = MaskRegion.defaultSpan(
                    atOutput: 0, timeline: .empty, bounds: 0...10
                )
                t.close(span.start, 0, "start")
                t.close(span.end, 3, "three seconds")
            }
        }
    }

    // MARK: - Cursor track rebasing

    private static func cursorRebase(_ t: TestRunner) {
        t.suite("CursorTracker.rebase") {
            func click(_ time: Double) -> InputEvent {
                InputEvent(t: time, kind: .click, x: 0.5, y: 0.5)
            }

            // Tracking now starts before the stream does, so the first frame
            // arrives after t=0 on the tracker's own clock.
            t.test("events shift by the gap between tracking and the first frame") {
                let out = CursorTracker.rebase([click(2), click(5)],
                                               startTime: 100, timeOrigin: 101)
                t.equal(out.count, 2, "both kept")
                t.close(out[0].t, 1, "first click"); t.close(out[1].t, 4, "second click")
            }

            // A click a fraction before the first frame is a click on what that
            // frame shows — worth keeping, pulled forward to zero.
            t.test("a click just before the first frame is pulled to zero") {
                let out = CursorTracker.rebase([click(0.8)], startTime: 100, timeOrigin: 101)
                t.equal(out.count, 1, "kept")
                t.close(out[0].t, 0, "clamped to the start")
            }

            t.test("anything more than half a second early is dropped") {
                let out = CursorTracker.rebase([click(0.2), click(0.6), click(3)],
                                               startTime: 100, timeOrigin: 101)
                t.equal(out.count, 2, "the -0.8s one is gone")
                t.close(out[0].t, 0, "the -0.4s one survives at zero")
                t.close(out[1].t, 2, "and the late one keeps its offset")
            }

            t.test("tracking that starts after the first frame shifts events later") {
                let out = CursorTracker.rebase([click(1)], startTime: 101, timeOrigin: 100)
                t.equal(out.count, 1, "kept")
                t.close(out[0].t, 2, "pushed back by the gap")
            }

            t.test("no events in, none out") {
                t.equal(CursorTracker.rebase([], startTime: 0, timeOrigin: 0).count, 0, "empty")
            }

            t.test("order and kind survive the shift") {
                let events = [
                    InputEvent(t: 1, kind: .move, x: 0.1, y: 0.1),
                    InputEvent(t: 2, kind: .scroll, x: 0.2, y: 0.2),
                    InputEvent(t: 3, kind: .rightClick, x: 0.3, y: 0.3),
                ]
                let out = CursorTracker.rebase(events, startTime: 10, timeOrigin: 10)
                t.equal(out.count, 3, "all kept")
                t.equal(out[0].kind, .move, "move"); t.equal(out[1].kind, .scroll, "scroll")
                t.equal(out[2].kind, .rightClick, "right click")
                t.close(out[2].x, 0.3, "position untouched")
            }
        }
    }

    // MARK: - Dragging a rectangle

    private static func rectDrag(_ t: TestRunner) {
        t.suite("RectDrag.moved") {
            t.test("a plain move shifts without resizing") {
                let r = RectDrag.moved(NRect(0.2, 0.2, 0.3, 0.2), dx: 0.1, dy: -0.05)
                t.close(r.x, 0.3, "x"); t.close(r.y, 0.15, "y")
                t.close(r.width, 0.3, "width kept"); t.close(r.height, 0.2, "height kept")
            }

            // Dragged into a corner it should stop, not squash — the size is
            // what the user set and a move must not change it.
            t.test("it stops at the edges and keeps its size") {
                let low = RectDrag.moved(NRect(0.2, 0.2, 0.3, 0.2), dx: -9, dy: -9)
                t.close(low.x, 0, "pinned left"); t.close(low.y, 0, "pinned top")
                t.close(low.width, 0.3, "width kept"); t.close(low.height, 0.2, "height kept")

                let high = RectDrag.moved(NRect(0.2, 0.2, 0.3, 0.2), dx: 9, dy: 9)
                t.close(high.x, 0.7, "pinned right"); t.close(high.y, 0.8, "pinned bottom")
                t.close(high.width, 0.3, "width kept"); t.close(high.height, 0.2, "height kept")
            }

            t.test("a full-frame rectangle has nowhere to go") {
                let r = RectDrag.moved(NRect(0, 0, 1, 1), dx: 0.4, dy: 0.4)
                t.close(r.x, 0, "x"); t.close(r.y, 0, "y")
                t.close(r.width, 1, "width"); t.close(r.height, 1, "height")
            }
        }

        t.suite("RectDrag.resized") {
            t.test("a corner moves its own two edges only") {
                let r = RectDrag.resized(NRect(0.2, 0.2, 0.4, 0.4),
                                         corner: .topLeft, dx: 0.1, dy: 0.1)
                t.close(r.x, 0.3, "left moved"); t.close(r.y, 0.3, "top moved")
                t.close(r.width, 0.3, "right stayed"); t.close(r.height, 0.3, "bottom stayed")

                let br = RectDrag.resized(NRect(0.2, 0.2, 0.4, 0.4),
                                          corner: .bottomRight, dx: 0.1, dy: 0.1)
                t.close(br.x, 0.2, "left stayed"); t.close(br.y, 0.2, "top stayed")
                t.close(br.width, 0.5, "right moved"); t.close(br.height, 0.5, "bottom moved")
            }

            // The one that turns a blur into a hole: drag a corner past its
            // opposite and a naive implementation gives a negative size, which
            // renders as nothing at all.
            t.test("dragging a corner past its opposite never inverts the rect") {
                for corner in RectDrag.Corner.allCases {
                    let r = RectDrag.resized(NRect(0.3, 0.3, 0.3, 0.3),
                                             corner: corner, dx: -5, dy: -5)
                    t.expect(r.width > 0, "\(corner) width stayed positive: \(r.width)")
                    t.expect(r.height > 0, "\(corner) height stayed positive: \(r.height)")
                    let s = RectDrag.resized(NRect(0.3, 0.3, 0.3, 0.3),
                                             corner: corner, dx: 5, dy: 5)
                    t.expect(s.width > 0, "\(corner) width positive the other way")
                    t.expect(s.height > 0, "\(corner) height positive the other way")
                }
            }

            t.test("it never shrinks below the minimum side") {
                let r = RectDrag.resized(NRect(0.3, 0.3, 0.3, 0.3),
                                         corner: .bottomRight, dx: -5, dy: -5,
                                         minSide: 0.05)
                t.close(r.width, 0.05, "width floor"); t.close(r.height, 0.05, "height floor")
            }

            t.test("it stays inside the frame however far it is dragged") {
                for corner in RectDrag.Corner.allCases {
                    for (dx, dy) in [(9.0, 9.0), (-9.0, -9.0), (9.0, -9.0), (-9.0, 9.0)] {
                        let r = RectDrag.resized(NRect(0.4, 0.4, 0.2, 0.2),
                                                 corner: corner, dx: dx, dy: dy)
                        t.expect(r.x >= -0.0001 && r.y >= -0.0001,
                                 "\(corner) origin inside: \(r.x), \(r.y)")
                        t.expect(r.x + r.width <= 1.0001 && r.y + r.height <= 1.0001,
                                 "\(corner) far edge inside: \(r.x + r.width), \(r.y + r.height)")
                    }
                }
            }

            t.test("a nonsense minimum is clamped rather than trusted") {
                let r = RectDrag.resized(NRect(0.3, 0.3, 0.3, 0.3),
                                         corner: .topLeft, dx: 5, dy: 5, minSide: 9)
                t.expect(r.width > 0 && r.height > 0, "still a usable rectangle")
                t.expect(r.x + r.width <= 1.0001, "still inside the frame")
            }
        }
    }

    // MARK: - Audio

    private static func audio(_ t: TestRunner) {
        t.suite("Waveform") {
            let wave = Waveform(rate: 10, peaks: [0, 0.2, 0.9, 0.1, 0.5, 0.5, 0, 0, 0.3, 1.0])

            t.test("an empty envelope reads as silence") {
                t.close(Waveform.empty.peak(at: 0), 0, "peak")
                t.close(Waveform.empty.peak(from: 0, to: 10), 0, "range")
                t.expect(Waveform.empty.isEmpty, "isEmpty")
            }

            t.test("duration follows the bucket count") {
                t.close(wave.duration, 1.0, "ten buckets at 10/s")
            }

            t.test("a point lookup finds its bucket") {
                t.close(wave.peak(at: 0.25), 0.9, "third bucket")
                t.close(wave.peak(at: 0.95), 1.0, "last bucket")
            }

            t.test("outside the recording reads as silence") {
                t.close(wave.peak(at: -1), 0, "before")
                t.close(wave.peak(at: 5), 0, "after")
            }

            // A pixel column covering many buckets has to show the loudest of
            // them: averaging flattens speech into a grey smear.
            t.test("a range lookup takes the loudest bucket, not the mean") {
                t.close(wave.peak(from: 0, to: 0.4), 0.9, "loud burst wins")
                t.close(wave.peak(from: 0.6, to: 0.8), 0, "a silent span stays silent")
                t.close(wave.peak(from: 0, to: 1), 1.0, "whole envelope")
            }

            t.test("a range past the end is clamped, not out of bounds") {
                t.close(wave.peak(from: 0.8, to: 90), 1.0, "clamped to the last bucket")
                t.close(wave.peak(from: 40, to: 90), 0, "entirely past the end")
            }
        }

        t.suite("Microphone meter") {
            t.test("silence and full scale sit at the ends") {
                t.close(MicrophoneRecorder.meterLevel(dBFS: -160), 0, "silence")
                t.close(MicrophoneRecorder.meterLevel(dBFS: -54), 0, "at the floor")
                t.close(MicrophoneRecorder.meterLevel(dBFS: 0), 1, "full scale")
            }

            t.test("it rises with level") {
                let quiet = MicrophoneRecorder.meterLevel(dBFS: -40)
                let speech = MicrophoneRecorder.meterLevel(dBFS: -20)
                let loud = MicrophoneRecorder.meterLevel(dBFS: -6)
                t.expect(quiet < speech && speech < loud, "monotonic")
                t.expect(quiet > 0, "quiet still registers")
            }

            // The whole point of the meter is telling live from dead at a
            // glance, so ordinary speech has to light up a good part of it.
            t.test("speech lands in the middle of the bar, not the last sliver") {
                let speech = MicrophoneRecorder.meterLevel(dBFS: -24)
                t.expect(speech > 0.4 && speech < 0.85,
                         "speech at -24 dBFS reads \(speech), expected 0.4...0.85")
            }

            t.test("a nonsense reading is treated as silence") {
                t.close(MicrophoneRecorder.meterLevel(dBFS: .infinity * 0), 0, "nan")
                t.close(MicrophoneRecorder.meterLevel(dBFS: -.infinity), 0, "-inf")
            }
        }
    }

    // MARK: - Timeline

    private static func timeline(_ t: TestRunner) {
        t.suite("Timeline") {
            t.test("empty clip list has no duration") {
                let timeline = Timeline(clips: [])
                t.expect(timeline.isEmpty, "expected empty")
                t.close(timeline.duration, 0, "duration")
            }

            t.test("a single clip offsets source time by its start") {
                let timeline = Timeline(clips: [Clip(sourceStart: 2, sourceEnd: 6)])
                t.close(timeline.duration, 4, "duration")
                t.close(timeline.sourceTime(at: 0), 2, "start maps to sourceStart")
                t.close(timeline.sourceTime(at: 4), 6, "end maps to sourceEnd")
                t.close(timeline.sourceTime(at: 1.5), 3.5, "midpoint")
            }

            t.test("a cut removes its section from the mapping") {
                // 0–3 kept, 3–6 cut out, 6–12 kept.
                let timeline = Timeline(clips: [
                    Clip(sourceStart: 0, sourceEnd: 3),
                    Clip(sourceStart: 6, sourceEnd: 12),
                ])
                t.close(timeline.duration, 9, "duration is 3 + 6")
                t.close(timeline.sourceTime(at: 2), 2, "before the cut")
                t.close(timeline.sourceTime(at: 3.5), 6.5, "after the cut skips ahead")
                t.expect(timeline.outputTime(forSource: 4.5) == nil,
                         "a removed moment has no output time")
                t.close(timeline.outputTime(forSource: 7) ?? -1, 4, "source 7 is at output 4")
            }

            t.test("speed scales output duration and source mapping") {
                var clip = Clip(sourceStart: 0, sourceEnd: 8)
                clip.speed = 2
                let timeline = Timeline(clips: [clip])
                t.close(timeline.duration, 4, "8s at 2x is 4s")
                t.close(timeline.sourceTime(at: 1), 2, "output 1s is source 2s")
                t.close(timeline.outputTime(forSource: 6) ?? -1, 3, "source 6s is output 3s")
            }

            t.test("nearest output time snaps out of a removed gap") {
                let timeline = Timeline(clips: [
                    Clip(sourceStart: 0, sourceEnd: 3),
                    Clip(sourceStart: 6, sourceEnd: 12),
                ])
                t.close(timeline.nearestOutputTime(forSource: 4.5), 3,
                        "lands at the start of the next surviving clip")
                t.close(timeline.nearestOutputTime(forSource: -5), 0, "before everything")
                t.close(timeline.nearestOutputTime(forSource: 99), 9, "after everything")
            }

            t.test("a source range spanning a cut yields one span per clip") {
                let timeline = Timeline(clips: [
                    Clip(sourceStart: 0, sourceEnd: 3),
                    Clip(sourceStart: 6, sourceEnd: 12),
                ])
                let spans = timeline.outputRanges(forSource: 2...7)
                t.equal(spans.count, 2, "two spans")
                guard spans.count == 2 else { return }
                t.close(spans[0].lowerBound, 2, "first span start")
                t.close(spans[0].upperBound, 3, "first span end")
                t.close(spans[1].lowerBound, 3, "second span start")
                t.close(spans[1].upperBound, 4, "second span end")
            }

            t.test("zero-length clips are dropped") {
                let timeline = Timeline(clips: [
                    Clip(sourceStart: 0, sourceEnd: 2),
                    Clip(sourceStart: 5, sourceEnd: 5),
                ])
                t.equal(timeline.entries.count, 1, "only the real clip survives")
            }
        }
    }

    // MARK: - Zoom planner

    private static func zoomPlanner(_ t: TestRunner) {
        func click(_ time: Double, _ x: Double, _ y: Double) -> InputEvent {
            InputEvent(t: time, kind: .click, x: x, y: y)
        }

        t.suite("ZoomPlanner") {
            t.test("no zooms when auto-zoom is off") {
                var settings = AutoZoomSettings()
                settings.enabled = false
                let plan = ZoomPlanner.plan(
                    events: [click(5, 0.5, 0.5)], settings: settings, range: 0...12
                )
                t.equal(plan.count, 0, "segments")
            }

            t.test("no zooms without any triggers") {
                let moves = [InputEvent(t: 1, kind: .move, x: 0.5, y: 0.5)]
                let plan = ZoomPlanner.plan(
                    events: moves, settings: AutoZoomSettings(), range: 0...12
                )
                t.equal(plan.count, 0, "segments")
            }

            t.test("a click zooms in before it lands and holds after") {
                let settings = AutoZoomSettings()
                let plan = ZoomPlanner.plan(
                    events: [click(5, 0.3, 0.4)], settings: settings, range: 0...12
                )
                t.equal(plan.count, 1, "one segment")
                guard let segment = plan.first else { return }
                t.close(segment.start, 5 - settings.leadIn, "starts a lead-in early")
                t.close(segment.end, 5 + settings.hold + settings.easeOut, "holds then eases out")
                t.close(segment.scale, settings.clickScale, "click magnification")
                t.close(segment.anchor.x, 0.3, "anchor x")
                t.close(segment.anchor.y, 0.4, "anchor y")
            }

            t.test("clicks close in time and place become one zoom") {
                let plan = ZoomPlanner.plan(
                    events: [click(5, 0.30, 0.40), click(5.5, 0.32, 0.42)],
                    settings: AutoZoomSettings(), range: 0...12
                )
                t.equal(plan.count, 1, "merged into one segment")
            }

            t.test("clicks far apart in space stay separate and overlap for a pan") {
                // Same moment, opposite corners: averaging the anchors would
                // point the camera at nothing, so these must not merge.
                let plan = ZoomPlanner.plan(
                    events: [click(5, 0.1, 0.1), click(5.5, 0.9, 0.9)],
                    settings: AutoZoomSettings(), range: 0...12
                )
                t.equal(plan.count, 2, "two segments")
                guard plan.count == 2 else { return }
                t.greater(plan[0].end - plan[1].start, 0,
                          "they overlap so the camera pans instead of dipping out")
                t.close(plan[0].end - plan[1].start, plan[1].easeIn,
                        "the overlap is exactly one ramp", tolerance: 1e-6)
                t.close(plan[0].anchor.x, 0.1, "first anchor keeps its own position")
                t.close(plan[1].anchor.x, 0.9, "second anchor keeps its own position")
            }

            t.test("a scroll-only burst uses the gentler magnification") {
                let scrolls = (0..<6).map {
                    InputEvent(t: 4 + Double($0) * 0.2, kind: .scroll, x: 0.5, y: 0.5)
                }
                let settings = AutoZoomSettings()
                let plan = ZoomPlanner.plan(events: scrolls, settings: settings, range: 0...12)
                t.equal(plan.count, 1, "one segment")
                t.close(plan.first?.scale ?? 0, settings.scrollScale, "scroll magnification")
            }

            t.test("segments stay inside the given range") {
                let plan = ZoomPlanner.plan(
                    events: [click(0.1, 0.5, 0.5)], settings: AutoZoomSettings(), range: 0...12
                )
                guard let segment = plan.first else { return t.expect(false, "expected a segment") }
                t.greater(segment.start, -0.0001, "never starts before the range")
                t.less(segment.end, 12.0001, "never ends after the range")
            }

            t.test("regenerating keeps hand-edited segments") {
                var edit = EditModel()
                edit.clips = [Clip(sourceStart: 0, sourceEnd: 12)]
                var manual = ZoomSegment(start: 9, end: 11, scale: 3)
                manual.isManual = true
                edit.segments = [manual]

                ZoomPlanner.regenerate(
                    in: &edit, events: [click(2, 0.2, 0.2)], duration: 12
                )
                t.expect(edit.segments.contains { $0.id == manual.id },
                         "the hand-made segment survived")
                t.greater(Double(edit.segments.count), 1, "and an automatic one was added")
            }
        }
    }

    // MARK: - Camera solver

    private static func cameraSolver(_ t: TestRunner) {
        t.suite("CameraSolver") {
            t.test("the easing curve is smooth and symmetric") {
                t.close(CameraSolver.ease(0), 0, "ease(0)")
                t.close(CameraSolver.ease(1), 1, "ease(1)")
                t.close(CameraSolver.ease(0.5), 0.5, "ease(0.5)")
                // f(1-u) == 1-f(u) is what makes two aligned ramps sum to one.
                for u in stride(from: 0.0, through: 1.0, by: 0.1) {
                    t.close(CameraSolver.ease(1 - u), 1 - CameraSolver.ease(u),
                            String(format: "symmetry at %.1f", u))
                }
                t.close(CameraSolver.ease(-3), 0, "clamped below")
                t.close(CameraSolver.ease(5), 1, "clamped above")
            }

            t.test("weight ramps up, plateaus, and ramps down") {
                let segment = ZoomSegment(
                    start: 0, end: 10, scale: 2, easeIn: 1, easeOut: 1
                )
                t.close(CameraSolver.weight(of: segment, at: -1), 0, "before")
                t.close(CameraSolver.weight(of: segment, at: 11), 0, "after")
                t.close(CameraSolver.weight(of: segment, at: 0.5), 0.5, "mid ramp-in")
                t.close(CameraSolver.weight(of: segment, at: 5), 1, "plateau")
                t.close(CameraSolver.weight(of: segment, at: 9.5), 0.5, "mid ramp-out")
            }

            t.test("ramps longer than the segment are scaled to fit") {
                let segment = ZoomSegment(start: 0, end: 1, scale: 2, easeIn: 3, easeOut: 1)
                let (inRamp, outRamp) = segment.effectiveRamps
                t.close(inRamp + outRamp, 1, "ramps fill exactly the duration")
                t.close(inRamp / outRamp, 3, "and keep their proportions")
            }

            t.test("a disabled segment is ignored") {
                var segment = ZoomSegment(start: 0, end: 10, scale: 3)
                segment.isEnabled = false
                let camera = CameraSolver.camera(at: 5, segments: [segment], cursor: .empty)
                t.close(camera.scale, 1, "no magnification")
            }

            t.test("overlapping zooms hold magnification and pan between anchors") {
                // seg1's ease-out lines up with seg2's ease-in, which is what the
                // planner arranges. The camera should stay at 2x throughout and
                // slide from one anchor to the other.
                let seg1 = ZoomSegment(
                    start: 0, end: 4, scale: 2, easeIn: 1, easeOut: 1,
                    mode: .manual, anchor: NPoint(0.2, 0.2)
                )
                let seg2 = ZoomSegment(
                    start: 3, end: 7, scale: 2, easeIn: 1, easeOut: 1,
                    mode: .manual, anchor: NPoint(0.8, 0.8)
                )
                let mid = CameraSolver.camera(at: 3.5, segments: [seg1, seg2], cursor: .empty)
                t.close(mid.scale, 2, "no dip at the crossover")
                t.close(mid.center.x, 0.5, "anchor is halfway across")
                t.close(mid.center.y, 0.5, "anchor is halfway down")

                for time in stride(from: 3.0, through: 4.0, by: 0.1) {
                    let camera = CameraSolver.camera(
                        at: time, segments: [seg1, seg2], cursor: .empty
                    )
                    t.greater(camera.scale, 1.99,
                              String(format: "stays zoomed at %.1f", time))
                }
            }

            t.test("a gap between zooms does return to full frame") {
                let seg1 = ZoomSegment(start: 0, end: 3, scale: 2)
                let seg2 = ZoomSegment(start: 5, end: 8, scale: 2)
                let camera = CameraSolver.camera(at: 4, segments: [seg1, seg2], cursor: .empty)
                t.close(camera.scale, 1, "fully zoomed out between them")
            }

            t.test("the pointer is kept in frame while zoomed") {
                // At 2x the visible half-extent is 0.25 of the frame, and the
                // dead zone is 62% of that — so the camera holds still until
                // the pointer is more than 0.155 away, then follows.
                let center = NPoint(0.5, 0.5)
                let near = CameraSolver.containing(
                    cursor: NPoint(0.58, 0.5), center: center, scale: 2
                )
                t.close(near.x, 0.5, "stays put while the pointer is close")

                let far = CameraSolver.containing(
                    cursor: NPoint(0.9, 0.5), center: center, scale: 2
                )
                t.close(far.x, 0.9 - 0.25 * 0.62, "pans just enough to keep it in view")
                t.close(far.y, 0.5, "and leaves the other axis alone")

                let up = CameraSolver.containing(
                    cursor: NPoint(0.5, 0.05), center: center, scale: 2
                )
                t.close(up.y, 0.05 + 0.25 * 0.62, "follows upward too")

                t.close(CameraSolver.containing(
                    cursor: NPoint(0.9, 0.9), center: center, scale: 1
                ).x, 0.5, "does nothing when not zoomed")
            }

            t.test("a fixed-anchor zoom follows a pointer that walks away") {
                let segment = ZoomSegment(
                    start: 0, end: 10, scale: 3, easeIn: 1, easeOut: 1,
                    mode: .manual, anchor: NPoint(0.2, 0.2)
                )
                let path = CursorPath(
                    events: (0...120).map {
                        InputEvent(t: Double($0) / 60, kind: .move, x: 0.9, y: 0.9)
                    },
                    duration: 10
                )
                let parked = CameraSolver.camera(
                    at: 5, segments: [segment], cursor: path, keepCursorInFrame: false
                )
                t.close(parked.center.x, 0.2, "without the option it stays on the anchor")

                let following = CameraSolver.camera(
                    at: 5, segments: [segment], cursor: path, keepCursorInFrame: true
                )
                t.greater(following.center.x, parked.center.x,
                          "with it, the camera moves toward the pointer")
                t.less(abs(following.center.x - 0.9), 0.5 / 3,
                       "and the pointer ends up inside the visible rect")
            }

            t.test("the visible rect stays inside the frame") {
                let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
                let camera = Camera(scale: 2, center: NPoint(0.99, 0.99))
                let rect = CameraSolver.visibleRect(camera: camera, bounds: bounds)
                t.close(rect.width, 500, "half width")
                t.close(rect.height, 250, "half height")
                t.greater(rect.minX, -0.0001, "not off the left")
                t.less(rect.maxX, 1000.0001, "not off the right")
                t.less(rect.maxY, 500.0001, "not off the top")
            }

            t.test("an aspect request narrows the visible rect") {
                let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
                let rect = CameraSolver.visibleRect(
                    camera: .identity, bounds: bounds, aspect: 9.0 / 16.0
                )
                t.close(rect.width / rect.height, 9.0 / 16.0, "matches the requested ratio",
                        tolerance: 1e-4)
                t.less(rect.width, bounds.width, "narrower than the source")
            }
        }
    }

    // MARK: - Cursor path

    private static func cursorPath(_ t: TestRunner) {
        func moves(_ points: [(Double, Double, Double)]) -> [InputEvent] {
            points.map { InputEvent(t: $0.0, kind: .move, x: $0.1, y: $0.2) }
        }

        t.suite("CursorPath") {
            t.test("an empty path sits in the middle") {
                let path = CursorPath(events: [], duration: 5)
                let p = path.position(at: 2)
                t.close(p.x, 0.5, "x")
                t.close(p.y, 0.5, "y")
            }

            t.test("a stationary pointer stays put through the filter") {
                let samples = stride(from: 0.0, through: 2.0, by: 1.0 / 60.0)
                    .map { ($0, 0.3, 0.7) }
                let path = CursorPath(events: moves(Array(samples)), duration: 2)
                let p = path.position(at: 1)
                t.close(p.x, 0.3, "x", tolerance: 1e-3)
                t.close(p.y, 0.7, "y", tolerance: 1e-3)
            }

            t.test("smoothing damps a sudden jump") {
                // Half a second at one spot, then an instant jump.
                var samples: [(Double, Double, Double)] = []
                for i in 0..<60 { samples.append((Double(i) / 60, 0.2, 0.5)) }
                for i in 60..<120 { samples.append((Double(i) / 60, 0.8, 0.5)) }
                let path = CursorPath(events: moves(samples), duration: 2)
                let atJump = path.position(at: 1.0)
                t.greater(atJump.x, 0.2, "has started moving")
                t.less(atJump.x, 0.8, "but hasn't teleported")
            }

            t.test("idle amount rises once the pointer parks") {
                let samples = stride(from: 0.0, through: 3.0, by: 1.0 / 60.0)
                    .map { ($0, 0.4, 0.4) }
                let path = CursorPath(events: moves(Array(samples)), duration: 3)
                t.close(path.idleAmount(at: 0.1, delay: 1.0), 0, "not idle yet")
                t.greater(path.idleAmount(at: 2.5, delay: 1.0), 0.9, "idle after the delay")
            }

            t.test("the click pulse peaks on the click and fades out") {
                let events = [
                    InputEvent(t: 1, kind: .move, x: 0.5, y: 0.5),
                    InputEvent(t: 2, kind: .click, x: 0.5, y: 0.5),
                ]
                let path = CursorPath(events: events, duration: 4)
                t.close(path.clickPulse(at: 2.0), 1, "full strength at the click")
                t.close(path.clickPulse(at: 1.5), 0, "nothing beforehand")
                t.close(path.clickPulse(at: 3.0), 0, "faded by then")
                t.greater(path.clickPulse(at: 2.1), 0, "still visible just after")
            }

            t.test("loop-to-start brings the pointer home") {
                var samples: [(Double, Double, Double)] = []
                for i in 0...180 {
                    let u = Double(i) / 180
                    samples.append((Double(i) / 60, 0.1 + 0.8 * u, 0.5))
                }
                let events = moves(samples)

                var looping = CursorSettings()
                looping.loopToStart = true
                let looped = CursorPath(events: events, duration: 3, settings: looping)
                let plain = CursorPath(events: events, duration: 3, settings: CursorSettings())

                let start = plain.position(at: 0)
                let loopedEnd = looped.position(at: 3)
                let plainEnd = plain.position(at: 3)
                t.less(abs(loopedEnd.x - start.x), abs(plainEnd.x - start.x),
                       "ends up nearer where it began")
            }
        }
    }

    // MARK: - Typing detector

    private static func typingDetector(_ t: TestRunner) {
        func typed(_ text: String, from start: Double, every step: Double = 0.12) -> [InputEvent] {
            text.enumerated().map { index, character in
                InputEvent(
                    t: start + Double(index) * step, kind: .key, x: 0.5, y: 0.5,
                    label: character == " " ? "␣" : String(character).uppercased()
                )
            }
        }

        t.suite("TypingDetector") {
            t.test("finds a run of plain typing") {
                let events = typed("hello there friend", from: 2)
                let ranges = TypingDetector.detect(events: events, range: 0...12)
                t.equal(ranges.count, 1, "one run")
                guard let range = ranges.first else { return }
                t.less(range.lowerBound, 2.0, "padded a little before the first key")
                t.greater(range.upperBound, 2 + 17 * 0.12, "and after the last")
            }

            t.test("ignores command shortcuts") {
                let events = [
                    InputEvent(t: 1, kind: .key, x: 0.5, y: 0.5, label: "⌘S"),
                    InputEvent(t: 1.3, kind: .key, x: 0.5, y: 0.5, label: "⌘C"),
                    InputEvent(t: 1.6, kind: .key, x: 0.5, y: 0.5, label: "⌘V"),
                    InputEvent(t: 1.9, kind: .key, x: 0.5, y: 0.5, label: "⌥⌘I"),
                    InputEvent(t: 2.2, kind: .key, x: 0.5, y: 0.5, label: "⌃A"),
                    InputEvent(t: 2.5, kind: .key, x: 0.5, y: 0.5, label: "⌘Z"),
                ]
                t.equal(TypingDetector.detect(events: events, range: 0...12).count, 0,
                        "driving the app isn't typing")
            }

            t.test("ignores a handful of stray keys") {
                let events = typed("abc", from: 3)
                t.equal(TypingDetector.detect(events: events, range: 0...12).count, 0,
                        "too few keystrokes")
            }

            t.test("the minimum duration is honoured either side of the threshold") {
                // Keep fixtures clear of the threshold. Two identical runs at
                // different offsets landed on opposite sides of a 1.2s minimum
                // through float rounding alone, which is exactly the kind of
                // coin-flip a test should never depend on.
                var settings = TypingDetector.Settings()
                settings.minDuration = 1.0
                settings.minKeystrokes = 4

                let tooShort = (0..<5).map {
                    InputEvent(t: 1 + Double($0) * 0.1, kind: .key, x: 0.5, y: 0.5, label: "A")
                }
                t.equal(TypingDetector.detect(events: tooShort, range: 0...10, settings: settings).count,
                        0, "0.4s of typing is below the minimum")

                let longEnough = (0..<20).map {
                    InputEvent(t: 1 + Double($0) * 0.1, kind: .key, x: 0.5, y: 0.5, label: "A")
                }
                t.equal(TypingDetector.detect(events: longEnough, range: 0...10, settings: settings).count,
                        1, "1.9s of typing is above it")
            }

            t.test("a long pause splits one run into two") {
                let events = typed("hello there friend", from: 1) + typed("goodbye to you now", from: 8)
                t.equal(TypingDetector.detect(events: events, range: 0...20).count, 2, "two runs")
            }

            t.test("splitting a clip at an interior time makes two") {
                let clips = [Clip(sourceStart: 0, sourceEnd: 10)]
                let split = TypingDetector.split(clips, at: 4)
                t.equal(split.count, 2, "two clips")
                guard split.count == 2 else { return }
                t.close(split[0].sourceEnd, 4, "left ends at the cut")
                t.close(split[1].sourceStart, 4, "right starts at the cut")
                t.expect(split[0].id != split[1].id, "the halves get distinct ids")
            }

            t.test("splitting outside a clip changes nothing") {
                let clips = [Clip(sourceStart: 0, sourceEnd: 10)]
                t.equal(TypingDetector.split(clips, at: 50).count, 1, "no split past the end")
                t.equal(TypingDetector.split(clips, at: 0.01).count, 1, "no split at the very edge")
            }

            t.test("applying marks the typing clips and speeds only those") {
                let clips = [Clip(sourceStart: 0, sourceEnd: 12)]
                let result = TypingDetector.apply(ranges: [3...7], to: clips, speed: 2)
                t.equal(result.count, 3, "before, during, after")
                let typing = result.filter(\.isTyping)
                t.equal(typing.count, 1, "one typing clip")
                t.close(typing.first?.speed ?? 0, 2, "sped up")
                t.close(typing.first?.sourceStart ?? -1, 3, "starts at the run")
                t.close(typing.first?.sourceEnd ?? -1, 7, "ends at the run")

                let untouched = result.filter { !$0.isTyping }
                t.expect(untouched.allSatisfy { $0.speed == 1 }, "the rest keep their speed")

                // 5s of typing at 2x plus 7s untouched.
                let total = result.reduce(0) { $0 + $1.outputDuration }
                t.close(total, 3 + 5 + 4.0 / 2, "timeline length after speeding up")
            }
        }
    }

    // MARK: - Canvas sizing

    private static func canvasSizing(_ t: TestRunner) {
        t.suite("CompositionBuilder.canvasSize") {
            let source = CGSize(width: 1920, height: 1200)

            t.test("auto keeps the source ratio") {
                let size = CompositionBuilder.canvasSize(
                    forWidth: 640, source: source, frame: FrameSettings()
                )
                t.close(size.width, 640, "width")
                t.close(size.height, 400, "height")
            }

            t.test("a vertical ratio makes a tall canvas") {
                var frame = FrameSettings()
                frame.aspect = .vertical
                let size = CompositionBuilder.canvasSize(
                    forWidth: 640, source: source, frame: frame
                )
                t.close(size.width, 640, "width")
                t.close(size.height, 1138, "height rounds to even")
            }

            t.test("cropping changes the auto ratio") {
                var frame = FrameSettings()
                frame.crop = NRect(0.2, 0.1, 0.6, 0.55)
                let size = CompositionBuilder.canvasSize(
                    forWidth: 640, source: source, frame: frame
                )
                // 1152 × 660 → 1.745; 640 / 1.745 ≈ 366.
                t.close(size.height, 366, "height follows the cropped ratio")
            }

            t.test("preview width isn't collapsed by a narrow recording") {
                // A portrait strip in a 16:9 frame used to clamp the canvas to
                // the source width and render a 308x174 postage stamp.
                let strip = CGSize(width: 308, height: 2400)
                t.equal(CompositionBuilder.previewWidth(quality: 1280, source: strip), 1280,
                        "a tall narrow source still gets a full-size canvas")

                var frame = FrameSettings()
                frame.aspect = .wide
                let canvas = CompositionBuilder.canvasSize(
                    forWidth: CompositionBuilder.previewWidth(quality: 1280, source: strip),
                    source: strip, frame: frame
                )
                t.close(canvas.width, 1280, "canvas width")
                t.close(canvas.height, 720, "canvas height")
            }

            t.test("preview width still respects what the source can supply") {
                t.equal(
                    CompositionBuilder.previewWidth(
                        quality: 2560, source: CGSize(width: 1280, height: 800)
                    ),
                    1280, "never renders beyond the source's longest side"
                )
                t.equal(
                    CompositionBuilder.previewWidth(
                        quality: 1280, source: CGSize(width: 3840, height: 2160)
                    ),
                    1280, "and never beyond the quality setting"
                )
                t.equal(
                    CompositionBuilder.previewWidth(
                        quality: 1280, source: CGSize(width: 40, height: 60)
                    ),
                    320, "with a floor so a tiny source is still legible"
                )
            }

            t.test("an extreme aspect is capped instead of exploding") {
                // A portrait strip on an Auto canvas asked for 1920 wide used
                // to produce 1920 x 15000.
                let strip = CGSize(width: 154, height: 1200)
                let size = CompositionBuilder.canvasSize(
                    forWidth: 1920, source: strip, frame: FrameSettings()
                )
                t.less(max(size.width, size.height),
                       CompositionBuilder.maxCanvasSide + 1, "longest side is capped")
                t.close(size.width / size.height, 154.0 / 1200.0,
                        "and the aspect ratio is preserved", tolerance: 0.01)
            }

            t.test("dimensions are always even for the encoder") {
                for width in [641, 853, 1001, 1279] {
                    for aspect in AspectRatio.allCases {
                        var frame = FrameSettings()
                        frame.aspect = aspect
                        let size = CompositionBuilder.canvasSize(
                            forWidth: width, source: source, frame: frame
                        )
                        t.close(size.width.truncatingRemainder(dividingBy: 2), 0,
                                "even width for \(width)/\(aspect.rawValue)")
                        t.close(size.height.truncatingRemainder(dividingBy: 2), 0,
                                "even height for \(width)/\(aspect.rawValue)")
                    }
                }
            }
        }
    }

    // MARK: - Undo history

    private static func history(_ t: TestRunner) {
        t.suite("History") {
            t.test("nothing to undo or redo at the start") {
                let h = History<Int>()
                t.expect(!h.canUndo, "canUndo")
                t.expect(!h.canRedo, "canRedo")
            }

            t.test("undo walks back and redo walks forward") {
                var h = History<Int>()
                h.record(1)          // before editing to 2
                h.record(2)          // before editing to 3
                t.equal(h.undo(current: 3), 2, "first undo")
                t.equal(h.undo(current: 2), 1, "second undo")
                t.expect(!h.canUndo, "exhausted")
                t.equal(h.undo(current: 1), nil, "undoing past the start is a no-op")
                t.equal(h.redo(current: 1), 2, "first redo")
                t.equal(h.redo(current: 2), 3, "second redo")
                t.equal(h.redo(current: 3), nil, "redoing past the end is a no-op")
            }

            t.test("editing after an undo discards the redo branch") {
                // Otherwise redo would jump onto a history that no longer
                // exists, which is how an editor loses someone's work.
                var h = History<Int>()
                h.record(1)
                h.record(2)
                _ = h.undo(current: 3)
                t.expect(h.canRedo, "redo is available right after undoing")
                h.record(2)
                t.expect(!h.canRedo, "and gone once something new is recorded")
            }

            t.test("the depth limit drops the oldest step, not the newest") {
                var h = History<Int>(limit: 3)
                for value in 1...5 { h.record(value) }
                t.equal(h.undo(current: 6), 5, "newest survives")
                t.equal(h.undo(current: 5), 4, "…")
                t.equal(h.undo(current: 4), 3, "down to the limit")
                t.expect(!h.canUndo, "and the oldest two were dropped")
            }

            t.test("clearing removes both directions") {
                var h = History<Int>()
                h.record(1)
                _ = h.undo(current: 2)
                h.clear()
                t.expect(!h.canUndo && !h.canRedo, "empty after clear")
            }
        }
    }

    // MARK: - Timeline ruler

    private static func rulerTicks(_ t: TestRunner) {
        t.suite("Timeline ruler") {
            t.test("ticks leave room for their labels") {
                // Every tick carries a "00:00" label, so the gap between them
                // has to stay at least one label wide however narrow the window.
                for width in [320.0, 600.0, 900.0, 1600.0] {
                    for duration in [5.0, 12.0, 60.0, 600.0, 3600.0] {
                        let step = TimelineView.tickStep(for: duration, width: CGFloat(width))
                        let gap = width * (step / duration)
                        t.greater(gap, Double(TimelineView.labelWidth) - 0.001,
                                  "\(Int(width))pt / \(Int(duration))s leaves \(Int(gap))pt")
                    }
                }
            }

            t.test("a label that would overhang the edge is dropped, not squashed") {
                let width: CGFloat = 600
                t.expect(TimelineView.labelFits(at: 0, width: width), "the first one fits")
                t.expect(TimelineView.labelFits(at: width - TimelineView.labelWidth, width: width),
                         "one ending exactly at the edge fits")
                t.expect(!TimelineView.labelFits(at: width - 4, width: width),
                         "one at the very end does not")
                t.expect(!TimelineView.labelFits(at: width, width: width),
                         "and neither does one at the final tick")
            }

            t.test("a narrow window uses coarser ticks than a wide one") {
                let narrow = TimelineView.tickStep(for: 600, width: 320)
                let wide = TimelineView.tickStep(for: 600, width: 1600)
                t.greater(narrow, wide - 0.001, "narrower means fewer, wider-spaced ticks")
            }
        }
    }

    // MARK: - Area geometry

    private static func areaGeometry(_ t: TestRunner) {
        t.suite("AreaGeometry") {
            let screenHeight: CGFloat = 1000

            t.test("a view rect flips to a top-left source rect") {
                // Dragged 200pt up from the bottom, 150 tall: the top of that
                // box is 650 down from the top of a 1000pt screen.
                let source = AreaGeometry.sourceRect(
                    fromView: CGRect(x: 300, y: 200, width: 400, height: 150),
                    screenHeight: screenHeight
                )
                t.close(source.minX, 300, "x is unchanged")
                t.close(source.minY, 650, "y is measured from the top")
                t.close(source.width, 400, "width")
                t.close(source.height, 150, "height")
            }

            t.test("a selection at the very top maps to y = 0") {
                let source = AreaGeometry.sourceRect(
                    fromView: CGRect(x: 0, y: 900, width: 100, height: 100),
                    screenHeight: screenHeight
                )
                t.close(source.minY, 0, "flush with the top of the display")
            }

            t.test("the flip round-trips") {
                let original = CGRect(x: 120, y: 340, width: 500, height: 260)
                let source = AreaGeometry.sourceRect(
                    fromView: original, screenHeight: screenHeight
                )
                let back = AreaGeometry.viewRect(
                    fromSource: source, screenHeight: screenHeight
                )
                t.close(back.minX, original.minX, "x survives")
                t.close(back.minY, original.minY, "y survives")
                t.close(back.width, original.width, "width survives")
                t.close(back.height, original.height, "height survives")
            }

            t.test("a full-screen selection covers the display") {
                let source = AreaGeometry.sourceRect(
                    fromView: CGRect(x: 0, y: 0, width: 1600, height: screenHeight),
                    screenHeight: screenHeight
                )
                t.close(source.minY, 0, "starts at the top")
                t.close(source.height, screenHeight, "and is the full height")
            }
        }
    }

    // MARK: - Project decoding

    private static func projectDecoding(_ t: TestRunner) {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        func decode(_ json: String) -> EditModel? {
            try? decoder.decode(EditModel.self, from: Data(json.utf8))
        }

        t.suite("EditModel decoding") {
            t.test("an empty object decodes to defaults") {
                guard let edit = decode("{}") else {
                    return t.expect(false, "failed to decode {}")
                }
                t.equal(edit.frame.aspect, .auto, "aspect")
                t.equal(edit.clips.count, 0, "no clips")
            }

            t.test("the old trim format becomes a single clip") {
                guard let edit = decode(#"{"trimStart": 2, "trimEnd": 9}"#) else {
                    return t.expect(false, "failed to decode the legacy format")
                }
                t.equal(edit.clips.count, 1, "one clip")
                t.close(edit.clips.first?.sourceStart ?? -1, 2, "start")
                t.close(edit.clips.first?.sourceEnd ?? -1, 9, "end")
            }

            // The regression that prompted this suite: adding a field to a
            // stored struct made every older project fail to decode, and the
            // failure was being swallowed, so edits silently reverted.
            t.test("a project written before a field existed still loads") {
                let json = """
                {
                  "clips": [{"sourceStart": 0, "sourceEnd": 12, "speed": 2, "volume": 0.5}],
                  "frame": {"aspect": "vertical", "alwaysZoomedIn": true},
                  "background": {"kind": "gradient", "padding": 0.09},
                  "cursor": {"mode": "synthetic", "size": 1.5},
                  "segments": [{"start": 1, "end": 4, "scale": 3}]
                }
                """
                guard let edit = decode(json) else {
                    return t.expect(false, "a project missing newer keys failed to decode")
                }
                t.equal(edit.frame.aspect, .vertical, "aspect survived")
                t.expect(edit.frame.alwaysZoomedIn, "alwaysZoomedIn survived")
                t.equal(edit.frame.device, .none, "the new field took its default")
                t.equal(edit.background.kind, .gradient, "background kind survived")
                t.close(edit.background.padding, 0.09, "padding survived")
                t.close(edit.background.cornerRadius, BackgroundSettings().cornerRadius,
                        "an absent field kept its default")
                t.equal(edit.cursor.mode, .synthetic, "cursor mode survived")
                t.close(edit.cursor.size, 1.5, "cursor size survived")
                t.equal(edit.clips.count, 1, "clip survived")
                t.close(edit.clips.first?.speed ?? 0, 2, "clip speed survived")
                t.close(edit.clips.first?.volume ?? 0, 0.5, "clip volume survived")
                t.expect(!(edit.clips.first?.isTyping ?? true), "absent flag defaults to false")
                t.equal(edit.segments.count, 1, "zoom survived")
                t.equal(edit.segments.first?.mode, .auto, "absent zoom mode defaults")
                t.expect(edit.segments.first?.isEnabled ?? false, "absent enabled flag defaults on")
                t.equal(edit.webcam.shape, WebcamSettings().shape, "whole absent struct defaults")
                t.expect(!edit.shortcuts.show, "absent shortcut settings default")
            }

            t.test("a full round trip preserves everything") {
                var edit = EditModel()
                edit.clips = [Clip(sourceStart: 1, sourceEnd: 5)]
                edit.frame.aspect = .square
                edit.frame.device = .phone
                edit.frame.crop = NRect(0.1, 0.2, 0.5, 0.6)
                edit.background.kind = .wallpaper
                edit.background.wallpaper = .ember
                edit.cursor.mode = .hidden
                edit.webcam.corner = .topRight
                edit.shortcuts.show = true
                edit.typing.speed = 3
                edit.masks = [MaskRegion(start: 1, end: 2)]
                edit.segments = [ZoomSegment(start: 0, end: 2, scale: 4)]
                edit.texts = [TextOverlay(start: 1, end: 3, text: "Ship it", style: .card)]
                edit.watermark.enabled = true
                edit.watermark.corner = .bottomLeft

                guard let data = try? encoder.encode(edit),
                      let back = try? decoder.decode(EditModel.self, from: data) else {
                    return t.expect(false, "round trip failed")
                }
                t.equal(back.frame.aspect, .square, "aspect")
                t.equal(back.frame.device, .phone, "device")
                t.close(back.frame.crop.width, 0.5, "crop width")
                t.equal(back.background.wallpaper, .ember, "wallpaper")
                t.equal(back.cursor.mode, .hidden, "cursor mode")
                t.equal(back.webcam.corner, .topRight, "webcam corner")
                t.expect(back.shortcuts.show, "shortcuts")
                t.close(back.typing.speed, 3, "typing speed")
                t.equal(back.masks.count, 1, "masks")
                t.close(back.segments.first?.scale ?? 0, 4, "zoom scale")
                t.equal(back.texts.first?.text ?? "", "Ship it", "callout text")
                t.equal(back.texts.first?.style ?? .plain, .card, "callout style")
                t.expect(back.watermark.enabled, "watermark")
                t.equal(back.watermark.corner, .bottomLeft, "watermark corner")
            }

            t.test("an unknown enum value is a real failure, not a silent default") {
                // Tolerant decoding must not paper over genuinely bad data.
                t.expect(decode(#"{"frame": {"aspect": "hexagonal"}}"#) == nil,
                         "a bogus value should throw rather than decode")
            }
        }
    }
}
