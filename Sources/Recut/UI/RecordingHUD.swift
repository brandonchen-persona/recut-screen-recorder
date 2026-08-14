import AppKit
import SwiftUI

/// Small floating controller shown while recording.
///
/// It sits above everything and follows you across Spaces. It never shows up in
/// the capture because the content filter excludes this whole application.
@MainActor
final class RecordingHUD {

    private var panel: NSPanel?
    private let recorder: ScreenRecorder
    private let onStop: () -> Void
    private let onCancel: () -> Void
    private let onRestart: () -> Void

    init(
        recorder: ScreenRecorder,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) {
        self.recorder = recorder
        self.onStop = onStop
        self.onCancel = onCancel
        self.onRestart = onRestart
    }

    func show() {
        let content = RecordingHUDView(
            recorder: recorder,
            onStop: onStop,
            onCancel: onCancel,
            onRestart: onRestart
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 296, height: 56)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let x = screen.frame.midX - hosting.frame.width / 2
            let y = screen.frame.minY + 64
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RecordingHUDView: View {
    @ObservedObject var recorder: ScreenRecorder
    var onStop: () -> Void
    var onCancel: () -> Void
    var onRestart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recorder.isPaused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .opacity(recorder.isRecording ? 1 : 0.3)

            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 54, alignment: .leading)

            if recorder.hasMicrophone {
                LevelMeter(level: recorder.micLevel, segments: 8, height: 14)
                    .help("Microphone level")
            }

            Spacer(minLength: 0)

            Button(action: onStop) {
                Label("Finish", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)

            Button { recorder.togglePause() } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
            .help(recorder.isPaused ? "Resume" : "Pause")

            Button(action: onRestart) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Start over")
            .help("Discard what's recorded and start again")

            Button(action: onCancel) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Discard recording")
            .help("Delete this recording")
        }
        .padding(.horizontal, 14)
        .frame(width: 336, height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func precise(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.00" }
        let total = Int(seconds)
        let hundredths = Int((seconds - Double(total)) * 100)
        return String(format: "%02d:%02d.%02d", total / 60, total % 60, hundredths)
    }
}
