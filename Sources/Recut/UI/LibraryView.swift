import SwiftUI
import ScreenCaptureKit

struct LibraryView: View {
    @ObservedObject var state: AppState
    @State private var recents: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.red)
                    Text("Recut")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Record your screen. Zooms follow your cursor automatically.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if state.permissionDenied {
                    permissionCard
                } else if state.captureError != nil {
                    captureErrorCard
                } else {
                    recordCard
                }

                HStack(spacing: 10) {
                    Button("Import video…", systemImage: "square.and.arrow.down") {
                        state.importVideoPanel()
                    }
                    .buttonStyle(.bordered)

                    Button("Open project…", systemImage: "folder") {
                        state.openProjectPanel()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 46)
            .padding(.horizontal, 40)

            if !recents.isEmpty {
                Divider().padding(.top, 26)
                recentsList
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if let url = Main.launchProject {
                Main.consumeLaunchProject()
                if let project = try? Project.load(url) {
                    await state.open(project)
                    return
                }
            }
            await state.refreshDisplays()
            recents = state.recentProjects()
        }
    }

    private var recordCard: some View {
        VStack(spacing: 14) {
            Picker("", selection: $state.sourceKind) {
                Label("Display", systemImage: "display").tag(CaptureSource.display)
                Label("Window", systemImage: "macwindow").tag(CaptureSource.window)
                Label("Area", systemImage: "crop").tag(CaptureSource.area)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            switch state.sourceKind {
            case .display:
                if state.displays.count > 1 {
                    Picker("Display", selection: $state.selectedDisplayID) {
                        ForEach(state.displays, id: \.displayID) { display in
                            Text(displayLabel(display)).tag(Optional(display.displayID))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                } else if let only = state.displays.first {
                    Text(displayLabel(only))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case .window:
                if state.windows.isEmpty {
                    Text("No windows available to record.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Window", selection: $state.selectedWindowID) {
                        ForEach(state.windows, id: \.windowID) { window in
                            Text(windowLabel(window)).tag(Optional(window.windowID))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                    Text("For an app in full screen, record the Display instead.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

            case .area:
                HStack(spacing: 8) {
                    Button("Choose area…", systemImage: "viewfinder") {
                        Task { await state.chooseArea() }
                    }
                    .help("Drag a region on any display")
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let area = state.selectedArea {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(area.width)) × \(Int(area.height)) at "
                                 + "\(Int(area.minX)), \(Int(area.minY))")
                                .font(.system(size: 10, design: .monospaced))
                            if let name = state.areaScreenName {
                                Text("on \(name)")
                                    .font(.system(size: 10))
                            }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text("No area chosen yet")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Toggle("Dim the rest of the screen while recording",
                       isOn: $state.dimOutsideArea)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Shows you the capture bounds. It's only on your screen — "
                          + "the dimming never appears in the recording.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Record system audio", isOn: $state.captureAudio)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                Toggle("Draw the cursor", isOn: $state.drawCursor)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Hides the system pointer while recording so the editor can draw a "
                          + "smoothed one you can resize, hide or restyle afterwards")

                Toggle("Create zooms automatically", isOn: $state.createZoomsAutomatically)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Picker("", selection: $state.selectedMicrophoneID) {
                        Text("No microphone").tag(String?.none)
                        ForEach(state.microphones, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Microphone")

                    LevelMeter(level: state.microphoneLevel,
                               isActive: state.selectedMicrophoneID != nil)
                        .help(state.selectedMicrophoneID == nil
                              ? "No microphone selected"
                              : "Speak to check the microphone is live")
                }

                HStack(spacing: 6) {
                    Image(systemName: "video")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Picker("", selection: $state.selectedCameraID) {
                        Text("No webcam").tag(String?.none)
                        ForEach(state.cameras, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $state.countdownSeconds) {
                        Text("No countdown").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Webcam")
                }
            }

            Button {
                Task { await state.startRecording() }
            } label: {
                Label("Start recording", systemImage: "record.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 190, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(state.displays.isEmpty)
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text("Recut needs Screen Recording permission")
                .font(.system(size: 13, weight: .medium))

            Text("""
            If the toggle already looks enabled in Settings, it was granted to an \
            earlier build. Recut isn't signed with a certificate, so macOS ties the \
            permission to the exact binary — every rebuild needs a fresh grant.
            """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Clear the stale grant, then use Request access:")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("tccutil reset ScreenCapture com.recut.app")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        "tccutil reset ScreenCapture com.recut.app", forType: .string
                    )
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy the command")
                .help("Copy")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))

            HStack {
                Button("Request access") {
                    Task { await state.requestScreenRecordingPermission() }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Settings") { ScreenRecorder.openScreenRecordingSettings() }
                    .buttonStyle(.bordered)

                Button("Check again") { Task { await state.refreshDisplays() } }
                    .buttonStyle(.bordered)
            }

            Text("This build: \(ScreenRecorder.codeSignatureID)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(maxWidth: 440)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var captureErrorCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Screen Recording is allowed, but capture failed")
                .font(.system(size: 13, weight: .medium))
            Text(state.captureError ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await state.refreshDisplays() } }
                .buttonStyle(.bordered)
        }
        .padding(22)
        .frame(maxWidth: 440)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recentsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ForEach(recents, id: \.self) { url in
                    Button {
                        Task {
                            do {
                                let project = try Project.load(url)
                                await state.open(project)
                            } catch {
                                state.errorMessage = "Couldn't open that project."
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 40)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func displayLabel(_ display: SCDisplay) -> String {
        let name = ScreenRecorder.nsScreen(for: display)?.localizedName ?? "Display"
        return "\(name) — \(display.width) × \(display.height)"
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Window"
        guard let title = window.title, !title.isEmpty else { return app }
        return "\(app) — \(title)"
    }
}
