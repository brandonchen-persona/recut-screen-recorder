import SwiftUI

/// Timeline with five lanes: a ruler, the clips (with cuts, speed and volume),
/// the zoom segments, masks and highlights, and text callouts.
///
/// Clips are laid out in timeline time; zooms are stored in source time and
/// mapped through `Timeline`, so a cut carries its zooms with it.
struct TimelineView: View {
    @Binding var edit: EditModel
    @Binding var selection: UUID?
    @Binding var selectedClip: UUID?
    let events: [InputEvent]
    let currentTime: Double
    let onScrub: (Double) -> Void
    let onSplit: (Double) -> Void
    let onRemoveClip: (UUID) -> Void
    let onSetSpeed: (UUID, Double) -> Void
    let onSetVolume: (UUID, Double) -> Void
    @Binding var selectedMask: UUID?
    @Binding var selectedText: UUID?
    /// Peak envelope of the source audio, drawn inside the clips.
    var waveform: Waveform?

    @State private var zoomLevel: Double = 1
    /// Which clip is being trimmed, where its edges were when the drag began,
    /// and the scale it was drawn at.
    ///
    /// The lanes always fit the whole timeline to the available width, so
    /// trimming a clip changes seconds-per-point *while you are dragging*.
    /// Reading the live scale each event made the edge accelerate away from the
    /// pointer — a 62pt pull moved the edge 0.93s instead of 1.00s, and letting
    /// go somewhere the handle no longer was.
    @State private var trimState: (clip: UUID, span: DragSpan, scale: CGFloat)?

    private let rulerHeight: CGFloat = 26
    private let headWidth: CGFloat = 18
    private let clipHeight: CGFloat = 46
    private let zoomHeight: CGFloat = 42
    private let maskHeight: CGFloat = 30
    private let textHeight: CGFloat = 30
    private let gap: CGFloat = 6

    private var timeline: Timeline { Timeline(clips: edit.clips) }

    var body: some View {
        let timeline = self.timeline
        let duration = max(0.01, timeline.duration)

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    onSplit(currentTime)
                } label: {
                    Text("Cut at playhead").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("b", modifiers: .command)

                Spacer()

                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Slider(value: $zoomLevel, in: 1...12)
                    .controlSize(.mini)
                    .frame(width: 110)
                    .accessibilityLabel("Timeline zoom")
                    .help("Zoom the timeline")
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            // The available width has to be measured *outside* the scroll view:
            // a GeometryReader inside one is offered an unbounded width and
            // collapses to zero.
            GeometryReader { outer in
                let w = max(1, outer.size.width * zoomLevel)
                let scale = w / duration

                ScrollView(.horizontal, showsIndicators: zoomLevel > 1.001) {
                    VStack(alignment: .leading, spacing: gap) {
                        ruler(width: w, scale: scale, duration: duration)
                        clipLane(width: w, scale: scale, timeline: timeline)
                        zoomLane(width: w, scale: scale, timeline: timeline)
                        maskLane(width: w, scale: scale, timeline: timeline)
                        textLane(width: w, scale: scale, timeline: timeline)
                    }
                    .frame(width: w, alignment: .leading)
                    .coordinateSpace(name: Self.laneSpace)
                    .overlay(alignment: .topLeading) {
                        playhead(scale: scale, width: w)
                    }
                }
                .scrollDisabled(zoomLevel <= 1.001)
            }
            .frame(height: laneStackHeight)
        }
    }

    private var laneStackHeight: CGFloat {
        rulerHeight + clipHeight + zoomHeight + maskHeight + textHeight + gap * 4
    }

    // MARK: Lanes

    private func ruler(width: CGFloat, scale: CGFloat, duration: Double) -> some View {
        let step = Self.tickStep(for: duration, width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear)
            ForEach(Array(stride(from: 0.0, through: max(duration, 0.001), by: step)), id: \.self) { t in
                let x = CGFloat(t) * scale
                // Clamping the last label back inside the edge shoved it on
                // top of its neighbour. If it doesn't fit, don't draw it — the
                // tick still marks the time.
                if Self.labelFits(at: x, width: width) {
                    Text(TimeFormat.clock(t))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: x + 4, y: 1)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 1, height: 6)
                    .offset(x: x, y: rulerHeight - 6)
            }
        }
        .frame(height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(scrubGesture(scale: scale, duration: duration))
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }

    private func clipLane(width: CGFloat, scale: CGFloat, timeline: Timeline) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .frame(width: width, height: clipHeight)

            ForEach(Array(timeline.entries.enumerated()), id: \.element.clipID) { index, entry in
                let x = CGFloat(entry.outputStart) * scale
                let w = max(3, CGFloat(entry.outputDuration) * scale)
                clipBlock(entry: entry, index: index, x: x, w: w, scale: scale)
            }

            eventTicks(scale: scale, timeline: timeline)
        }
        .frame(height: clipHeight)
        .contentShape(Rectangle())
        .gesture(scrubGesture(scale: scale, duration: timeline.duration))
    }

    private func clipBlock(
        entry: Timeline.Entry, index: Int, x: CGFloat, w: CGFloat, scale: CGFloat
    ) -> some View {
        let isSelected = selectedClip == entry.clipID
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(isSelected ? 0.55 : 0.34),
                             Color.accentColor.opacity(isSelected ? 0.38 : 0.2)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.white.opacity(0.85)
                                                 : Color.white.opacity(0.14),
                                      lineWidth: isSelected ? 1.5 : 1)
                )

            if let waveform, !waveform.isEmpty {
                WaveformShape(waveform: waveform, entry: entry, width: w)
                    .fill(Color.white.opacity(0.42))
                    // Scaled by the clip's volume, so a muted clip reads as
                    // muted from the shape alone.
                    .scaleEffect(y: max(0.02, entry.volume), anchor: .center)
                    .frame(width: w, height: clipHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .allowsHitTesting(false)
            }

            if w > 62 {
                HStack(spacing: 4) {
                    if abs(entry.speed - 1) > 0.001 {
                        Label(String(format: "%.2g×", entry.speed), systemImage: "hare")
                            .labelStyle(.titleAndIcon)
                    }
                    if entry.volume < 0.999 {
                        Image(systemName: entry.volume < 0.001 ? "speaker.slash" : "speaker.wave.1")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.leading, 6)
                .padding(.top, 4)
                .allowsHitTesting(false)
            }

            // Trim handles on the outer edges of the timeline. Both work from
            // the clip's edges as they were when the drag began, so the handle
            // tracks the pointer instead of accumulating per-event deltas.
            HStack(spacing: 0) {
                TrimHandle(
                    height: clipHeight,
                    onDrag: { dx in
                        guard let i = clipIndex(entry.clipID),
                              let base = trimBase(for: entry.clipID, scale: scale),
                              base.scale > 0 else { return }
                        let delta = Double(dx / base.scale) * entry.speed
                        edit.clips[i].sourceStart = min(max(0, base.span.start + delta),
                                                        base.span.end - 0.15)
                    },
                    onEnd: { trimState = nil }
                )
                Spacer(minLength: 0)
                TrimHandle(
                    height: clipHeight,
                    onDrag: { dx in
                        guard let i = clipIndex(entry.clipID),
                              let base = trimBase(for: entry.clipID, scale: scale),
                              base.scale > 0 else { return }
                        let delta = Double(dx / base.scale) * entry.speed
                        edit.clips[i].sourceEnd = max(base.span.start + 0.15,
                                                      base.span.end + delta)
                    },
                    onEnd: { trimState = nil }
                )
            }
        }
        .frame(width: w, height: clipHeight)
        .offset(x: x)
        .onTapGesture { selectedClip = entry.clipID }
        .contextMenu {
            Button("Cut here") { onSplit(currentTime) }
            Button("Remove", role: .destructive) { onRemoveClip(entry.clipID) }
                .disabled(edit.clips.count < 2)
            Divider()
            Menu("Speed") {
                ForEach(Clip.speedChoices, id: \.self) { s in
                    Button(String(format: "%.2g×", s)) { onSetSpeed(entry.clipID, s) }
                }
            }
            Menu("Set volume") {
                ForEach(Clip.volumeChoices, id: \.self) { v in
                    Button("\(Int(v * 100))%") { onSetVolume(entry.clipID, v) }
                }
            }
        }
    }

    private func eventTicks(scale: CGFloat, timeline: Timeline) -> some View {
        // Clicks are drawn taller than scrolls; this is the raw signal the
        // auto-zoom planner worked from.
        Canvas { context, size in
            for e in events where e.isTrigger {
                guard let t = timeline.outputTime(forSource: e.t) else { continue }
                let x = CGFloat(t) * scale
                guard x >= 0, x <= size.width else { continue }
                let isScroll = e.kind == .scroll
                let h: CGFloat = isScroll ? 6 : 11
                let rect = CGRect(x: x - 0.75, y: size.height - h - 4, width: 1.5, height: h)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.75),
                    with: .color(isScroll ? Color.primary.opacity(0.32)
                                          : Color.orange.opacity(0.85))
                )
            }
        }
        .frame(height: clipHeight)
        .allowsHitTesting(false)
    }

    private func zoomLane(width: CGFloat, scale: CGFloat, timeline: Timeline) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
                .frame(width: width, height: zoomHeight)
                .overlay(alignment: .leading) {
                    if edit.segments.isEmpty {
                        Text("Zooms — click to add")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 7)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                // Screen Studio adds a zoom by clicking an empty spot on the lane.
                .onTapGesture { location in
                    guard scale > 0 else { return }
                    addZoom(atOutput: Double(location.x / scale), timeline: timeline)
                }

            ForEach($edit.segments) { $segment in
                if let span = timeline.outputRanges(forSource: segment.start...segment.end).first {
                    SegmentBlock(
                        segment: $segment,
                        isSelected: selection == segment.id,
                        x: CGFloat(span.lowerBound) * scale,
                        w: max(6, CGFloat(span.upperBound - span.lowerBound) * scale),
                        height: zoomHeight,
                        secondsPerPoint: scale > 0 ? Double(1 / scale) : 0,
                        onSelect: { selection = segment.id },
                        onDelete: { edit.segments.removeAll { $0.id == segment.id } }
                    )
                }
            }
        }
        .frame(height: zoomHeight)
    }

    private func maskLane(width: CGFloat, scale: CGFloat, timeline: Timeline) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.04))
                .frame(width: width, height: maskHeight)
                .overlay(alignment: .leading) {
                    if edit.masks.isEmpty {
                        Text("Masks & highlights — click to add")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 7)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard scale > 0 else { return }
                    addMask(atOutput: Double(location.x / scale), timeline: timeline)
                }

            ForEach($edit.masks) { $mask in
                if let span = timeline.outputRanges(forSource: mask.start...mask.end).first {
                    MaskBlock(
                        mask: $mask,
                        isSelected: selectedMask == mask.id,
                        x: CGFloat(span.lowerBound) * scale,
                        w: max(6, CGFloat(span.upperBound - span.lowerBound) * scale),
                        height: maskHeight,
                        secondsPerPoint: scale > 0 ? Double(1 / scale) : 0,
                        onSelect: { selectedMask = mask.id },
                        onDelete: { edit.masks.removeAll { $0.id == mask.id } }
                    )
                }
            }
        }
        .frame(height: maskHeight)
    }

    private func textLane(width: CGFloat, scale: CGFloat, timeline: Timeline) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.04))
                .frame(width: width, height: textHeight)
                .overlay(alignment: .leading) {
                    if edit.texts.isEmpty {
                        Text("Text callouts — click to add")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 7)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard scale > 0 else { return }
                    addText(atOutput: Double(location.x / scale), timeline: timeline)
                }

            ForEach($edit.texts) { $overlay in
                if let span = timeline.outputRanges(forSource: overlay.start...overlay.end).first {
                    TextBlock(
                        overlay: $overlay,
                        isSelected: selectedText == overlay.id,
                        x: CGFloat(span.lowerBound) * scale,
                        w: max(6, CGFloat(span.upperBound - span.lowerBound) * scale),
                        height: textHeight,
                        secondsPerPoint: scale > 0 ? Double(1 / scale) : 0,
                        onSelect: { selectedText = overlay.id },
                        onDelete: { edit.texts.removeAll { $0.id == overlay.id } }
                    )
                }
            }
        }
        .frame(height: textHeight)
    }

    private func addText(atOutput t: Double, timeline: Timeline) {
        let source = timeline.sourceTime(at: t)
        let span = edit.sourceRange
        let start = max(span.lowerBound, source - 0.2)
        let end = min(span.upperBound, start + 3.0)
        guard end - start > 0.3 else { return }
        let overlay = TextOverlay(start: start, end: end)
        edit.texts.append(overlay)
        edit.texts.sort { $0.start < $1.start }
        selectedText = overlay.id
    }

    /// The values a trim is measured from, captured on the drag's first event
    /// and held until it ends.
    private func trimBase(
        for clipID: UUID, scale: CGFloat
    ) -> (span: DragSpan, scale: CGFloat)? {
        if let trimState, trimState.clip == clipID {
            return (trimState.span, trimState.scale)
        }
        guard let i = clipIndex(clipID) else { return nil }
        let span = DragSpan(start: edit.clips[i].sourceStart, end: edit.clips[i].sourceEnd)
        trimState = (clipID, span, scale)
        return (span, scale)
    }

    private func addMask(atOutput t: Double, timeline: Timeline) {
        let (start, end) = MaskRegion.defaultSpan(
            atOutput: t, timeline: timeline, bounds: edit.sourceRange
        )
        guard end - start > 0.3 else { return }
        let mask = MaskRegion(start: start, end: end)
        edit.masks.append(mask)
        edit.masks.sort { $0.start < $1.start }
        selectedMask = mask.id
    }

    /// The playhead: a thin line that stays out of the way, and a head in the
    /// ruler that's actually grabbable.
    ///
    /// The line itself deliberately takes no clicks — a full-height grab band
    /// would sit on top of the zoom blocks, mask blocks and trim handles and
    /// steal their drags. All the hit area lives in the ruler, where nothing
    /// else competes for it.
    private func playhead(scale: CGFloat, width: CGFloat) -> some View {
        let x = min(max(CGFloat(currentTime) * scale, 0), width)
        // Keep the head fully on screen at both ends; at the end of playback it
        // would otherwise hang half-off the right edge, which is exactly when
        // you want to grab it and drag back.
        let headX = min(max(x - headWidth / 2, 0), max(0, width - headWidth))

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2)
                .offset(x: x - 1)
                .allowsHitTesting(false)

            PlayheadHandle(width: headWidth, height: rulerHeight)
                .offset(x: headX)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.laneSpace))
                        .onChanged { value in
                            guard scale > 0 else { return }
                            onScrub(min(max(Double(value.location.x / scale), 0),
                                        max(0.01, Double(width / scale))))
                        }
                )
        }
    }

    static let laneSpace = "recut.timeline.lanes"

    // MARK: Interaction

    private func clipIndex(_ id: UUID) -> Int? {
        edit.clips.firstIndex { $0.id == id }
    }

    private func addZoom(atOutput t: Double, timeline: Timeline) {
        let source = timeline.sourceTime(at: t)
        let span = edit.sourceRange
        let start = max(span.lowerBound, source - 0.4)
        let end = min(span.upperBound, start + 2.6)
        guard end - start > 0.5 else { return }
        let segment = ZoomSegment(
            start: start, end: end,
            scale: edit.autoZoom.clickScale,
            easeIn: edit.autoZoom.leadIn,
            easeOut: edit.autoZoom.easeOut,
            mode: .manual,
            anchor: .center,
            isManual: true
        )
        edit.segments.append(segment)
        edit.segments.sort { $0.start < $1.start }
        selection = segment.id
    }

    private func scrubGesture(scale: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard scale > 0 else { return }
                onScrub(min(max(Double(value.location.x / scale), 0), duration))
            }
    }

    /// Width of a "00:00" label at 11pt, plus breathing room.
    static let labelWidth: CGFloat = 46

    /// Whether a label starting at `x` still fits before the right edge.
    static func labelFits(at x: CGFloat, width: CGFloat) -> Bool {
        x + labelWidth <= width
    }

    /// Picks a tick interval that leaves room for the label at every tick.
    /// A fixed number of ticks packs them tighter as the window narrows, and
    /// larger type made them overlap.
    static func tickStep(for duration: Double, width: CGFloat = 800) -> Double {
        let maxLabels = max(2.0, Double(width / labelWidth))
        let target = duration / maxLabels
        let choices: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return choices.first { $0 >= target } ?? 900
    }
}

// MARK: - Trim handle

private struct TrimHandle: View {
    let height: CGFloat
    /// Called with the drag's *total* offset from where it started.
    ///
    /// Deliberately carries no "has it begun" state of its own. Trimming
    /// rebuilds the clip rows underneath, which resets `@State` inside them —
    /// a begin callback fired from here re-based the drag part-way through and
    /// the edge shot off at roughly two and a half times the pointer. The
    /// caller keeps the starting values instead, in state that survives.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 9, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: height * 0.4)
            )
            .contentShape(Rectangle().inset(by: -5))
            // Global space: this handle is inside a block whose width and
            // offset change as it is dragged, so a reading taken in the
            // handle's own space moves with the handle and fights the pointer.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

/// The visible grab bar at each end of a span block.
///
/// The hit areas were always there, but nothing on screen said so — a zoom,
/// blur or callout looked like a fixed tile rather than something you drag out
/// to cover more of the take. Same shape as the clip trim handle, so the two
/// read as the same gesture.
private struct SpanGrip: View {
    let height: CGFloat
    let isSelected: Bool
    /// Hidden on a block too narrow to hold two grips and still show a middle.
    let isVisible: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.white.opacity(isVisible ? (isSelected ? 0.5 : 0.28) : 0))
            .frame(width: 7, height: max(6, height - 8))
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(isVisible ? (isSelected ? 1 : 0.8) : 0))
                    .frame(width: 2, height: max(4, height * 0.42))
            )
            .padding(.horizontal, 1)
    }
}

/// The start and end a span drag is measured from.
///
/// Captured once when the gesture begins. Applying the gesture's *cumulative*
/// translation to a fixed base is what keeps an edge under the pointer: adding
/// per-event deltas to the live value compounds rounding, and any re-render
/// that clears the stored previous position turns into a visible jump.
private struct DragSpan {
    var start: Double
    var end: Double
}

// MARK: - Zoom segment block

private struct SegmentBlock: View {
    @Binding var segment: ZoomSegment
    let isSelected: Bool
    let x: CGFloat
    let w: CGFloat
    let height: CGFloat
    /// Source seconds per point, for converting drags back to source time.
    let secondsPerPoint: Double
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var dragBase: DragSpan?

    private let minDuration = 0.3

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.purple.opacity(segment.isEnabled ? (isSelected ? 0.68 : 0.45) : 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.white.opacity(0.9)
                                                 : Color.white.opacity(0.18),
                                      lineWidth: isSelected ? 1.5 : 1)
                )

            if w > 58 {
                HStack(spacing: 3) {
                    Image(systemName: segment.mode == .manual ? "hand.point.up.left"
                                                              : "cursorarrow.click")
                        .font(.system(size: 10))
                    Text(String(format: "%.1f×", segment.scale))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(segment.isEnabled ? 1 : 0.5))
                .padding(.leading, 12)
                .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                edgeHandle(isLeading: true)
                Spacer(minLength: 0)
                edgeHandle(isLeading: false)
            }
        }
        .frame(width: w, height: height)
        .offset(x: x)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let base = begin()
                    let delta = Double(value.translation.width) * secondsPerPoint
                    let duration = base.end - base.start
                    segment.start = max(0, base.start + delta)
                    segment.end = segment.start + duration
                }
                .onEnded { _ in dragBase = nil; segment.isManual = true }
        )
        .contextMenu {
            Button(segment.isEnabled ? "Disable" : "Enable") {
                segment.isEnabled.toggle()
                segment.isManual = true
            }
            Button("Remove", role: .destructive, action: onDelete)
        }
    }

    private func edgeHandle(isLeading: Bool) -> some View {
        SpanGrip(height: height, isSelected: isSelected, isVisible: w > 26)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let base = begin()
                        let delta = Double(value.translation.width) * secondsPerPoint
                        if isLeading {
                            segment.start = min(max(0, base.start + delta),
                                                base.end - minDuration)
                        } else {
                            segment.end = max(base.start + minDuration, base.end + delta)
                        }
                    }
                    .onEnded { _ in dragBase = nil; segment.isManual = true }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    /// Records where the segment was when the drag started, and selects it once
    /// rather than on every event.
    private func begin() -> DragSpan {
        if let dragBase { return dragBase }
        onSelect()
        let base = DragSpan(start: segment.start, end: segment.end)
        dragBase = base
        return base
    }
}

// MARK: - Mask block

private struct MaskBlock: View {
    @Binding var mask: MaskRegion
    let isSelected: Bool
    let x: CGFloat
    let w: CGFloat
    let height: CGFloat
    let secondsPerPoint: Double
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var dragBase: DragSpan?

    private let minDuration = 0.2

    private var tint: Color {
        mask.kind == .highlight ? .yellow : .teal
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(isSelected ? 0.7 : 0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.white.opacity(0.9)
                                                 : Color.white.opacity(0.18),
                                      lineWidth: isSelected ? 1.5 : 1)
                )

            if w > 58 {
                Label(mask.kind.label, systemImage: mask.kind == .highlight
                      ? "flashlight.on.fill" : "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                edgeHandle(isLeading: true)
                Spacer(minLength: 0)
                edgeHandle(isLeading: false)
            }
        }
        .frame(width: w, height: height)
        .offset(x: x)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let base = begin()
                    let delta = Double(value.translation.width) * secondsPerPoint
                    let duration = base.end - base.start
                    mask.start = max(0, base.start + delta)
                    mask.end = mask.start + duration
                }
                .onEnded { _ in dragBase = nil }
        )
        .contextMenu {
            Button("Remove", role: .destructive, action: onDelete)
        }
    }

    private func edgeHandle(isLeading: Bool) -> some View {
        SpanGrip(height: height, isSelected: isSelected, isVisible: w > 26)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let base = begin()
                        let delta = Double(value.translation.width) * secondsPerPoint
                        if isLeading {
                            mask.start = min(max(0, base.start + delta),
                                           base.end - minDuration)
                        } else {
                            mask.end = max(base.start + minDuration, base.end + delta)
                        }
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    /// Captures the span the drag is measured from, and selects the block once
    /// instead of on every event.
    private func begin() -> DragSpan {
        if let dragBase { return dragBase }
        onSelect()
        let base = DragSpan(start: mask.start, end: mask.end)
        dragBase = base
        return base
    }
}


// MARK: - Waveform

/// The peak envelope of one clip, mirrored about the middle of the lane.
///
/// Drawn per pixel column and asking the envelope for the *loudest* bucket in
/// that column's span: at a zoomed-out scale one column covers many buckets,
/// and averaging them turns speech into a flat grey band.
private struct WaveformShape: Shape {
    let waveform: Waveform
    let entry: Timeline.Entry
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1, entry.outputDuration > 0 else { return path }

        let columns = max(1, Int(rect.width.rounded()))
        let middle = rect.midY
        let half = rect.height * 0.42
        let step = (entry.sourceEnd - entry.sourceStart) / Double(columns)

        for column in 0..<columns {
            let source = entry.sourceStart + Double(column) * step
            let peak = waveform.peak(from: source, to: source + step)
            guard peak > 0.004 else { continue }
            let h = max(0.5, CGFloat(peak) * half)
            let x = rect.minX + CGFloat(column)
            path.addRect(CGRect(x: x, y: middle - h, width: 1, height: h * 2))
        }
        return path
    }
}

// MARK: - Text block

private struct TextBlock: View {
    @Binding var overlay: TextOverlay
    let isSelected: Bool
    let x: CGFloat
    let w: CGFloat
    let height: CGFloat
    let secondsPerPoint: Double
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var dragBase: DragSpan?

    private let minDuration = 0.2

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.purple.opacity(isSelected ? 0.7 : 0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.white.opacity(0.9)
                                                 : Color.white.opacity(0.18),
                                      lineWidth: isSelected ? 1.5 : 1)
                )

            if w > 42 {
                // The words themselves, so a block is identifiable without
                // selecting it — several callouts in a row otherwise look alike.
                Label(overlay.text, systemImage: "textformat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 11)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                edgeHandle(isLeading: true)
                Spacer(minLength: 0)
                edgeHandle(isLeading: false)
            }
        }
        .frame(width: w, height: height)
        .offset(x: x)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let base = begin()
                    let delta = Double(value.translation.width) * secondsPerPoint
                    let duration = base.end - base.start
                    overlay.start = max(0, base.start + delta)
                    overlay.end = overlay.start + duration
                }
                .onEnded { _ in dragBase = nil }
        )
        .contextMenu {
            Button("Remove", role: .destructive, action: onDelete)
        }
    }

    private func edgeHandle(isLeading: Bool) -> some View {
        SpanGrip(height: height, isSelected: isSelected, isVisible: w > 26)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let base = begin()
                        let delta = Double(value.translation.width) * secondsPerPoint
                        if isLeading {
                            overlay.start = min(max(0, base.start + delta),
                                           base.end - minDuration)
                        } else {
                            overlay.end = max(base.start + minDuration, base.end + delta)
                        }
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    /// Captures the span the drag is measured from, and selects the block once
    /// instead of on every event.
    private func begin() -> DragSpan {
        if let dragBase { return dragBase }
        onSelect()
        let base = DragSpan(start: overlay.start, end: overlay.end)
        dragBase = base
        return base
    }
}


// MARK: - Playhead handle

/// A tall enough target to grab without aiming. The visible head is 18pt wide;
/// the hit area is padded well beyond that, since a 2pt line is far below the
/// size a pointer can reliably catch.
private struct PlayheadHandle: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Path { path in
            let shoulder = height * 0.62
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: width, y: 0))
            path.addLine(to: CGPoint(x: width, y: shoulder))
            path.addLine(to: CGPoint(x: width / 2, y: height))
            path.addLine(to: CGPoint(x: 0, y: shoulder))
            path.closeSubpath()
        }
        .fill(Color.red)
        .overlay(
            // Two grip lines, the usual sign that something can be dragged.
            HStack(spacing: 2) {
                Capsule().frame(width: 1.5)
                Capsule().frame(width: 1.5)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: height * 0.34)
            .offset(y: -height * 0.12)
        )
        .frame(width: width, height: height)
        .contentShape(Rectangle().inset(by: -8))
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help("Drag to scrub")
    }
}
