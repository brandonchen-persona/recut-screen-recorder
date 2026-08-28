import SwiftUI
import AVFoundation

struct EditorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                frameBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .layoutPriority(1)

                Divider()

                ZStack {
                    VideoPreview(player: state.player.player, still: state.still.image)
                        .background(Color.black)

                    if state.isCropping {
                        CropOverlay(
                            crop: $state.edit.frame.crop,
                            canvasAspect: state.canvasAspect,
                            contentAspect: state.fullSourceAspect,
                            padding: state.edit.background.padding
                        )
                    } else if let index = state.selectedMaskIndex {
                        MaskOverlay(
                            mask: $state.edit.masks[index],
                            canvasAspect: state.canvasAspect,
                            contentAspect: state.fullSourceAspect,
                            padding: state.edit.background.padding,
                            isActiveNow: state.selectedMaskIsActiveNow
                        )
                    } else if state.placingAnchor, let index = state.selectedSegmentIndex {
                        AnchorOverlay(
                            anchor: $state.edit.segments[index].anchor,
                            canvasAspect: state.canvasAspect,
                            contentAspect: state.fullSourceAspect,
                            padding: state.edit.background.padding,
                            scale: state.edit.segments[index].scale
                        )
                    }
                }
                // The preview is the only part that should give way when the
                // window gets short. Without a floor and a layout priority,
                // SwiftUI kept the player at its natural size and pushed the
                // bottom timeline lane off the edge of the window instead.
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .layoutPriority(0)

                transport
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .layoutPriority(1)

                Divider()

                TimelineView(
                    edit: $state.edit,
                    selection: $state.selection,
                    selectedClip: $state.selectedClip,
                    events: state.project?.events ?? [],
                    currentTime: state.player.currentTime,
                    onScrub: { t in
                        state.player.pause()
                        state.player.seek(to: t)
                        state.refreshPreview()
                    },
                    onSplit: { _ in state.splitAtPlayhead() },
                    onRemoveClip: { state.removeClip($0) },
                    onSetSpeed: { state.setSpeed($1, for: $0) },
                    onSetVolume: { state.setVolume($1, for: $0) },
                    selectedMask: $state.selectedMask,
                    selectedText: $state.selectedText,
                    waveform: state.waveform
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            InspectorView(state: state)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    state.closeProject()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
                .help("Back to the library")
            }

            ToolbarItemGroup(placement: .principal) {
                Text(state.project?.name ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.addZoomAtPlayhead()
                } label: {
                    Label("Add zoom", systemImage: "plus.magnifyingglass")
                }
                .help("Add a zoom at the playhead")

                Menu {
                    Button("Save frame as PNG…", systemImage: "photo") {
                        state.exportStill()
                    }
                    Button("Copy frame", systemImage: "doc.on.doc") {
                        state.exportStill(toClipboard: true)
                    }
                } label: {
                    Label("Frame", systemImage: "camera")
                }
                .menuIndicator(.hidden)
                .help("Save the frame under the playhead as an image")

                Button {
                    state.exportPanel()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(state.exporter.isExporting)
            }
        }
    }

    /// Aspect ratio and crop, which Screen Studio puts above the preview.
    private var frameBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $state.edit.frame.aspect) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio == .auto ? ratio.label : "\(ratio.label) \(ratio.detail)")
                        .tag(ratio)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
            .help("Output aspect ratio")

            Toggle("Always keep zoomed in", isOn: $state.edit.frame.alwaysZoomedIn)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .disabled(state.edit.frame.aspect == .auto)
                .opacity(state.edit.frame.aspect == .auto ? 0.4 : 1)
                .help("Fill the frame by cropping to the ratio and following the cursor, "
                      + "instead of letterboxing")

            Picker("", selection: $state.edit.frame.device) {
                ForEach(DeviceFrame.allCases) { device in
                    Text(device == .none ? "No frame" : device.label).tag(device)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
            .help("Draw a device bezel around the recording")

            Divider().frame(height: 16)

            Toggle(isOn: $state.isCropping) {
                Label("Crop", systemImage: "crop")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .keyboardShortcut("c", modifiers: [])

            if !state.edit.frame.crop.isFull {
                Button("Reset crop") { state.edit.frame.crop = .full }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            // A tall narrow recording in an Auto canvas just gets a thin
            // border. Point at the control that puts it on a wide background.
            if state.suggestsWideCanvas {
                Button {
                    state.edit.frame.aspect = .wide
                } label: {
                    Label("Put on a 16:9 background", systemImage: "rectangle.center.inset.filled")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("This recording is much taller than it is wide. A 16:9 canvas "
                      + "fills the space either side with the background.")
            }

            Spacer()

            Text(state.canvasDescription)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                state.player.step(by: -1.0 / 30.0)
                state.refreshPreview()
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel("Back one frame")
            .help("Back one frame (←)")

            Button {
                state.player.togglePlay()
            } label: {
                Image(systemName: state.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .frame(width: 26)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(state.player.isPlaying ? "Pause" : "Play")

            Button {
                state.player.step(by: 1.0 / 30.0)
                state.refreshPreview()
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("Forward one frame")
            .help("Forward one frame (→)")


            Text(TimeFormat.precise(state.player.currentTime))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("/")
                .foregroundStyle(.quaternary)

            Text(TimeFormat.precise(state.player.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("Length after cuts and speed changes")

            Spacer()

            Button {
                state.splitAtPlayhead()
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Split the clip at the playhead")

            Button {
                if let id = state.selectedClip { state.removeClip(id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.selectedClip == nil || state.edit.clips.count < 2)
            .help("Remove the selected clip")
        }
    }
}
