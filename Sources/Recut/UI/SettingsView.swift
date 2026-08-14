import SwiftUI
import AppKit

/// The ⌘, window. Recording defaults, where projects live, and how hard the
/// preview works.
struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            recording
                .tabItem { Label("Recording", systemImage: "record.circle") }
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            performance
                .tabItem { Label("Performance", systemImage: "speedometer") }
        }
        .frame(width: 440, height: 300)
    }

    private var recording: some View {
        Form {
            Toggle("Create zooms automatically", isOn: $state.createZoomsAutomatically)
            Text("When off, recordings arrive with no zooms and you place them by hand.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Draw the cursor", isOn: $state.drawCursor)
            Text("Hides the system pointer while recording so the editor can draw a smoothed "
                 + "one you can resize, restyle or remove. A pointer baked into the video "
                 + "can't be changed afterwards.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Record system audio", isOn: $state.captureAudio)

            Picker("Countdown", selection: $state.countdownSeconds) {
                Text("None").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }
        }
        .padding(20)
    }

    private var general: some View {
        Form {
            LabeledContent("Projects folder") {
                HStack {
                    Text(Project.libraryDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [Project.libraryDirectory]
                        )
                    }
                    .controlSize(.small)
                }
            }

            Text("Recordings are saved here automatically as `.recut` packages. "
                 + "Every edit is written back as you work — there's nothing to lose.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("This build") {
                Text(ScreenRecorder.codeSignatureID)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("Screen Recording permission is tied to this identifier, which changes "
                 + "whenever the app is rebuilt.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var performance: some View {
        Form {
            Picker("Preview", selection: $state.previewQuality) {
                ForEach(PreviewQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.radioGroup)

            Text(state.previewQuality.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            Text("Exports always render at full quality — this only affects how hard the "
                 + "editor works while you scrub.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
