import SwiftUI
import AppKit

/// Export settings modal, matching Screen Studio's flow: choose format, size,
/// frame rate and quality, then either write a file or put it on the clipboard.
struct ExportSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(state.canvasDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            if state.exporter.isExporting {
                progressBody
            } else {
                settingsBody
            }
        }
        .frame(width: 460)
    }

    // MARK: Settings

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("Format") {
                Picker("", selection: $state.exportSettings.format) {
                    ForEach(ExportSettings.Format.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .labelsHidden()
            }
            if state.exportSettings.format == .gif {
                note("GIFs have no audio, are capped at 20 fps, and get large fast — "
                     + "best kept under a minute.")
            }

            row("Size") {
                Picker("", selection: $state.exportSettings.width) {
                    ForEach(ExportSettings.widthChoices, id: \.self) { width in
                        Text("\(width)p wide").tag(width)
                    }
                }
                .labelsHidden()
            }
            if state.exportSettings.width >= 3840 {
                note("4K takes about four times as long to export as 1080p.")
            }

            row("Frame rate") {
                Picker("", selection: $state.exportSettings.fps) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden()
            }

            row("Quality") {
                Picker("", selection: $state.exportSettings.quality) {
                    ForEach(ExportSettings.Quality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .labelsHidden()
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy to Clipboard", systemImage: "doc.on.clipboard") {
                    state.export(toClipboard: true)
                }
                .buttonStyle(.bordered)
                Button("Export to File…", systemImage: "square.and.arrow.down") {
                    state.export(toClipboard: false)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: Progress

    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: state.exporter.progress)
                .progressViewStyle(.linear)

            HStack {
                Text("Exporting… \(Int(state.exporter.progress * 100))%")
                    .font(.system(size: 12))
                Spacer()
                if let url = state.pendingExportURL {
                    Button {
                        state.showExportPath.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show where the file is being saved")
                    .help("Where it's being saved")

                    if state.showExportPath {
                        Text(url.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(20)
    }

    // MARK: Bits

    private func row<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content()
                .frame(maxWidth: 220, alignment: .leading)
            Spacer()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 90)
    }
}
