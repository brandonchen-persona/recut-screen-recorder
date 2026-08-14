import SwiftUI

struct InspectorView: View {
    @ObservedObject var state: AppState
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                lookSection
                Divider()
                zoomSection
                Divider()
                autoZoomSection
                Divider()
                cursorSection
                if state.player.media?.hasWebcam == true {
                    Divider()
                    webcamSection
                }
                Divider()
                typingSection
                Divider()
                maskSection
                Divider()
                textSection
                Divider()
                watermarkSection
                Divider()
                backgroundSection
                Divider()
                exportSection
            }
            .padding(16)
        }
        .frame(width: 300)
        .background(.background)
        .alert("Save this look as a preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                state.savePreset(named: presetName)
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Presets cover background, cursor, camera, aspect ratio and zoom feel.")
        }
    }

    // MARK: Look

    @ViewBuilder
    private var lookSection: some View {
        SectionHeader("Look", systemImage: "paintpalette")

        Text("Background, cursor, camera, aspect and zoom feel — the parts that "
             + "should match across a set of clips.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if !state.looks.presets.isEmpty {
            Menu {
                ForEach(state.looks.presets) { preset in
                    Button(preset.name) { state.applyPreset(preset) }
                }
                Divider()
                ForEach(state.looks.presets) { preset in
                    Button("Delete “\(preset.name)”", role: .destructive) {
                        state.looks.removePreset(preset.id)
                    }
                }
            } label: {
                Label("Apply a preset", systemImage: "square.on.square")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
        }

        HStack(spacing: 6) {
            Button("Save preset…", systemImage: "plus") { isNamingPreset = true }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Use for new") { state.saveLookAsHouseStyle() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("New recordings and imports start with this look")
        }

        if state.looks.houseStyle != nil {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("New recordings inherit a saved look.")
                Button("Reset") { state.looks.clearHouseStyle() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        } else {
            Text("New recordings currently start from the built-in defaults.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Selected zoom

    /// Any change made here counts as hand-editing, so the segment survives the
    /// next "Regenerate zooms".
    private func segmentBinding(_ index: Int) -> Binding<ZoomSegment> {
        Binding(
            get: {
                guard state.edit.segments.indices.contains(index) else {
                    return ZoomSegment(start: 0, end: 1, scale: 1)
                }
                return state.edit.segments[index]
            },
            set: { newValue in
                guard state.edit.segments.indices.contains(index) else { return }
                var updated = newValue
                updated.isManual = true
                state.edit.segments[index] = updated
            }
        )
    }

    @ViewBuilder
    private var zoomSection: some View {
        SectionHeader("Zoom", systemImage: "plus.magnifyingglass")

        if let index = state.selectedSegmentIndex {
            let binding = segmentBinding(index)

            LabeledSlider(
                title: "Magnification",
                value: binding.scale,
                range: 1...5,
                format: { String(format: "%.2f×", $0) }
            )

            HStack(spacing: 6) {
                ForEach([1.25, 1.5, 2.0, 3.0, 5.0], id: \.self) { preset in
                    Button(String(format: preset < 2 ? "%.2f×" : "%.0f×", preset)) {
                        binding.wrappedValue.scale = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            LabeledSlider(
                title: "Ease in",
                value: binding.easeIn,
                range: 0.05...2.5,
                format: { String(format: "%.2fs", $0) }
            )
            LabeledSlider(
                title: "Ease out",
                value: binding.easeOut,
                range: 0.05...2.5,
                format: { String(format: "%.2fs", $0) }
            )

            HStack {
                Text("From")
                Spacer()
                Text(TimeFormat.precise(binding.wrappedValue.start))
                Text("→")
                Text(TimeFormat.precise(binding.wrappedValue.end))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)

            Picker("", selection: binding.mode) {
                ForEach(ZoomMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Zoom mode")

            Text(binding.wrappedValue.mode == .auto
                 ? "Points at the clicks recorded inside this zoom."
                 : binding.wrappedValue.mode == .manual
                   ? "Drag the purple dot on the preview to aim it."
                   : "Tracks the pointer for the whole zoom.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if binding.wrappedValue.mode == .manual {
                Toggle(isOn: $state.placingAnchor) {
                    Label("Place the target on the preview", systemImage: "scope")
                }
                .toggleStyle(.button)
                .controlSize(.small)

                LabeledSlider(
                    title: "Anchor X",
                    value: binding.anchor.x,
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                LabeledSlider(
                    title: "Anchor Y",
                    value: binding.anchor.y,
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }

            HStack {
                Button("Delete", systemImage: "trash") {
                    state.deleteSelectedSegment()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Add zoom", systemImage: "plus") {
                    state.addZoomAtPlayhead()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Text("Select a zoom on the timeline to change how far it goes and where it points.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Add zoom at playhead", systemImage: "plus") {
                state.addZoomAtPlayhead()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Auto zoom

    @ViewBuilder
    private var autoZoomSection: some View {
        SectionHeader("Auto-zoom", systemImage: "wand.and.stars")

        Toggle("Follow clicks and scrolls", isOn: $state.edit.autoZoom.enabled)
            .font(.system(size: 12))

        Toggle("Keep the cursor in frame", isOn: $state.edit.autoZoom.keepCursorInFrame)
            .font(.system(size: 12))
        Text("While zoomed in, pan just enough to stop the pointer leaving the frame.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Toggle("New zooms track the cursor", isOn: $state.edit.autoZoom.followCursor)
            .font(.system(size: 12))
            .disabled(!state.edit.autoZoom.enabled)

        Group {
            LabeledSlider(
                title: "Click zoom",
                value: $state.edit.autoZoom.clickScale,
                range: 1...5,
                format: { String(format: "%.2f×", $0) }
            )
            LabeledSlider(
                title: "Scroll zoom",
                value: $state.edit.autoZoom.scrollScale,
                range: 1...5,
                format: { String(format: "%.2f×", $0) }
            )
            LabeledSlider(
                title: "Lead-in",
                value: $state.edit.autoZoom.leadIn,
                range: 0.1...2,
                format: { String(format: "%.2fs", $0) }
            )
            LabeledSlider(
                title: "Hold after",
                value: $state.edit.autoZoom.hold,
                range: 0...3,
                format: { String(format: "%.2fs", $0) }
            )
            LabeledSlider(
                title: "Grouping",
                value: $state.edit.autoZoom.clusterGap,
                range: 0.4...5,
                format: { String(format: "%.1fs", $0) }
            )
        }
        .disabled(!state.edit.autoZoom.enabled)
        .opacity(state.edit.autoZoom.enabled ? 1 : 0.4)

        Button("Regenerate zooms", systemImage: "arrow.clockwise") {
            state.regenerateAutoZoom()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(state.project?.events.isEmpty ?? true)

        if state.project?.events.isEmpty ?? true {
            Text("This clip has no recorded cursor track, so zooms have to be placed by hand.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Regenerating replaces automatic zooms and keeps the ones you placed or edited.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cursor

    @ViewBuilder
    private var cursorSection: some View {
        SectionHeader("Cursor", systemImage: "cursorarrow")

        Picker("", selection: $state.edit.cursor.mode) {
            ForEach(CursorMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Cursor mode")

        if state.edit.cursor.mode == .synthetic {
            if state.project?.meta.cursorIsSynthetic != true {
                Text("This recording has the system pointer baked in, so you'll see two. "
                     + "Turn on \"Draw the cursor\" before recording to use this.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledSlider(
                title: "Size",
                value: $state.edit.cursor.size,
                range: 0.4...3,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Smoothing",
                value: $state.edit.cursor.smoothing,
                range: 0.01...0.6,
                format: { String(format: "%.02fs", $0) }
            )
            Toggle("Click highlight", isOn: $state.edit.cursor.clickHighlight)
                .font(.system(size: 12))
            Toggle("Hide when idle", isOn: $state.edit.cursor.hideWhenIdle)
                .font(.system(size: 12))
            if state.edit.cursor.hideWhenIdle {
                LabeledSlider(
                    title: "Idle after",
                    value: $state.edit.cursor.idleDelay,
                    range: 0.5...8,
                    format: { String(format: "%.1fs", $0) }
                )
            }
            Toggle("Return to start for a clean loop", isOn: $state.edit.cursor.loopToStart)
                .font(.system(size: 12))
        } else if state.edit.cursor.mode == .hidden {
            Text("Only applies to recordings made with \"Draw the cursor\" on — a pointer "
                 + "baked into the video can't be removed afterwards.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Typing and shortcuts

    @ViewBuilder
    private var typingSection: some View {
        SectionHeader("Typing & shortcuts", systemImage: "keyboard")

        if state.hasKeyEvents {
            LabeledSlider(
                title: "Typing speed",
                value: $state.edit.typing.speed,
                range: 1...8,
                format: { String(format: "%.1f×", $0) }
            )

            HStack {
                Button("Find typing", systemImage: "wand.and.stars") {
                    state.findTypingSegments()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Apply to all") {
                    state.applySpeedToAllTypingClips()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.typingClipCount == 0)
            }

            if state.typingClipCount > 0 {
                Text("\(state.typingClipCount) typing "
                     + (state.typingClipCount == 1 ? "clip" : "clips") + " on the timeline.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Show shortcuts on screen", isOn: $state.edit.shortcuts.show)
                .font(.system(size: 12))

            if state.edit.shortcuts.show {
                Toggle("Include single keys", isOn: $state.edit.shortcuts.includeSingleKeys)
                    .font(.system(size: 12))
                LabeledSlider(
                    title: "Label size",
                    value: $state.edit.shortcuts.size,
                    range: 0.5...2,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                LabeledSlider(
                    title: "Stay on screen",
                    value: $state.edit.shortcuts.duration,
                    range: 0.5...4,
                    format: { String(format: "%.1fs", $0) }
                )
            }
        } else {
            Text("This recording has no key presses. Recut can speed up typing and caption "
                 + "your shortcuts, but reading the keyboard needs Accessibility permission — "
                 + "it's the only feature that does.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.captureKeystrokes {
                Label(
                    KeyTracker.isTrusted
                        ? "Enabled for the next recording."
                        : "Waiting for Accessibility permission.",
                    systemImage: KeyTracker.isTrusted ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.system(size: 10))
                .foregroundStyle(KeyTracker.isTrusted ? Color.secondary : Color.orange)

                if !KeyTracker.isTrusted {
                    Button("Open Accessibility settings") {
                        KeyTracker.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button("Record key presses…", systemImage: "keyboard") {
                    state.enableKeystrokeCapture()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: Webcam

    @ViewBuilder
    private var webcamSection: some View {
        SectionHeader("Webcam", systemImage: "video")

        Toggle("Show the camera", isOn: $state.edit.webcam.enabled)
            .font(.system(size: 12))

        Group {
            Picker("", selection: $state.edit.webcam.shape) {
                ForEach(WebcamShape.allCases) { shape in Text(shape.label).tag(shape) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Camera shape")

            Picker("", selection: $state.edit.webcam.corner) {
                ForEach(WebcamCorner.allCases) { corner in Text(corner.label).tag(corner) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Camera corner")

            LabeledSlider(
                title: "Size",
                value: $state.edit.webcam.size,
                range: 0.08...0.5,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Margin",
                value: $state.edit.webcam.margin,
                range: 0...0.12,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Shadow",
                value: $state.edit.webcam.shadowOpacity,
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            Toggle("Mirror", isOn: $state.edit.webcam.mirrored)
                .font(.system(size: 12))
        }
        .disabled(!state.edit.webcam.enabled)
        .opacity(state.edit.webcam.enabled ? 1 : 0.4)
    }

    // MARK: Masks and highlights

    @ViewBuilder
    private var maskSection: some View {
        SectionHeader("Masks & highlights", systemImage: "rectangle.dashed")

        if let index = state.selectedMaskIndex {
            let binding = $state.edit.masks[index]

            Picker("", selection: binding.kind) {
                ForEach(MaskKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Mask kind")

            Text(binding.wrappedValue.kind == .highlight
                 ? "Dims everything outside the rectangle."
                 : "Covers the rectangle to hide what's under it.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if binding.wrappedValue.kind == .blur {
                LabeledSlider(
                    title: "Blur",
                    value: binding.blurRadius,
                    range: 5...120,
                    format: { String(format: "%.0f", $0) }
                )
            }
            LabeledSlider(
                title: "Opacity",
                value: binding.opacity,
                range: 0.1...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Width",
                value: binding.rect.width,
                range: 0.05...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Height",
                value: binding.rect.height,
                range: 0.05...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "X",
                value: binding.rect.x,
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Y",
                value: binding.rect.y,
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )

            Button("Delete", systemImage: "trash", role: .destructive) {
                state.deleteSelectedMask()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Text("Click the mask lane on the timeline to cover something up, or to draw "
                 + "attention to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Add at playhead", systemImage: "plus") {
                state.addMaskAtPlayhead()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Text callouts

    @ViewBuilder
    private var textSection: some View {
        SectionHeader("Text", systemImage: "textformat")

        if let index = state.selectedTextIndex {
            let binding = $state.edit.texts[index]

            TextField("Text", text: binding.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .lineLimit(1...3)

            Picker("", selection: binding.style) {
                ForEach(TextStyle.allCases) { style in Text(style.label).tag(style) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Text style")

            Toggle("Bold", isOn: binding.bold)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            LabeledSlider(
                title: "Size",
                value: binding.size,
                range: 0.4...3,
                format: { String(format: "%.2f×", $0) }
            )
            ColorRow(title: "Text colour", color: binding.color)
            if binding.wrappedValue.style != .plain {
                ColorRow(title: "Chip colour", color: binding.background)
                LabeledSlider(
                    title: "Chip opacity",
                    value: binding.background.a,
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }
            LabeledSlider(
                title: "X",
                value: binding.position.x,
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Y",
                value: binding.position.y,
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Fade in",
                value: binding.fadeIn,
                range: 0...1.5,
                format: { String(format: "%.2fs", $0) }
            )
            LabeledSlider(
                title: "Fade out",
                value: binding.fadeOut,
                range: 0...1.5,
                format: { String(format: "%.2fs", $0) }
            )

            Button("Delete", systemImage: "trash", role: .destructive) {
                state.deleteSelectedText()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Text("Click the text lane on the timeline to label a feature, or to caption a step.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Add at playhead", systemImage: "plus") {
                state.addTextAtPlayhead()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Watermark

    @ViewBuilder
    private var watermarkSection: some View {
        SectionHeader("Logo", systemImage: "seal")

        Toggle("Show a logo", isOn: $state.edit.watermark.enabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11))

        if state.edit.watermark.enabled {
            Button("Choose image…", systemImage: "photo") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    state.edit.watermark.imagePath = url.path
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let path = state.edit.watermark.imagePath {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Transparent PNG works best.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Picker("Corner", selection: $state.edit.watermark.corner) {
                ForEach(WebcamCorner.allCases) { corner in Text(corner.label).tag(corner) }
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))

            LabeledSlider(
                title: "Size",
                value: $state.edit.watermark.size,
                range: 0.02...0.3,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Margin",
                value: $state.edit.watermark.margin,
                range: 0...0.12,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            LabeledSlider(
                title: "Opacity",
                value: $state.edit.watermark.opacity,
                range: 0.1...1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )

            Text("Saved with your look, so every recording carries it.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Background

    @ViewBuilder
    private var backgroundSection: some View {
        SectionHeader("Background", systemImage: "square.on.square")

        Picker("", selection: $state.edit.background.kind) {
            ForEach(BackgroundKind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Background kind")

        switch state.edit.background.kind {
        case .blur:
            LabeledSlider(
                title: "Blur",
                value: $state.edit.background.blurRadius,
                range: 5...220,
                format: { String(format: "%.0f", $0) }
            )
            LabeledSlider(
                title: "Dim",
                value: $state.edit.background.dim,
                range: 0...0.8,
                format: { String(format: "%.0f%%", $0 * 125) }
            )
            LabeledSlider(
                title: "Saturation",
                value: $state.edit.background.saturation,
                range: 0...2,
                format: { String(format: "%.2f", $0) }
            )
        case .color:
            ColorRow(title: "Color", color: $state.edit.background.color)
        case .gradient:
            ColorRow(title: "Top", color: $state.edit.background.gradientTop)
            ColorRow(title: "Bottom", color: $state.edit.background.gradientBottom)
        case .wallpaper:
            Picker("", selection: $state.edit.background.wallpaper) {
                ForEach(Wallpaper.allCases) { w in Text(w.label).tag(w) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Wallpaper")
        case .image:
            Button("Choose image…", systemImage: "photo") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    state.edit.background.imagePath = url.path
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let path = state.edit.background.imagePath {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .none:
            EmptyView()
        }

        LabeledSlider(
            title: "Padding",
            value: $state.edit.background.padding,
            range: 0...0.2,
            format: { String(format: "%.0f%%", $0 * 100) }
        )
        LabeledSlider(
            title: "Corner radius",
            value: $state.edit.background.cornerRadius,
            range: 0...0.06,
            format: { String(format: "%.0f", $0 * 1000) }
        )
        LabeledSlider(
            title: "Shadow",
            value: $state.edit.background.shadowOpacity,
            range: 0...1,
            format: { String(format: "%.0f%%", $0 * 100) }
        )
        LabeledSlider(
            title: "Shadow spread",
            value: $state.edit.background.shadowRadius,
            range: 0...0.08,
            format: { String(format: "%.0f", $0 * 1000) }
        )
    }

    // MARK: Export

    @ViewBuilder
    private var exportSection: some View {
        SectionHeader("Export", systemImage: "square.and.arrow.up")

        Text("\(state.exportSettings.format.label) · \(state.canvasDescription) · "
             + "\(state.exportSettings.fps) fps · \(state.exportSettings.quality.label)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if state.exporter.isExporting {
            ProgressView(value: state.exporter.progress)
                .progressViewStyle(.linear)
            Text("Exporting… \(Int(state.exporter.progress * 100))%")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Button("Export…", systemImage: "square.and.arrow.up") {
                state.exportPanel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(state.project == nil)
        }
    }
}

// MARK: - Bits

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

private struct ColorRow: View {
    let title: String
    @Binding var color: RGBAColor

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: 1) },
                // Alpha is edited by its own slider where it matters; picking a
                // hue must not silently make a translucent chip opaque.
                set: { newValue in
                    let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                    color = RGBAColor(
                        Double(ns.redComponent),
                        Double(ns.greenComponent),
                        Double(ns.blueComponent),
                        color.a
                    )
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel(title)
        }
    }
}
