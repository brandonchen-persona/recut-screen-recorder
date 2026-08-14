import SwiftUI
import AppKit

struct RecutApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 1080, minHeight: 700)
                .onDisappear { state.saveNow() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { state.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo)
                Button("Redo") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Start Recording") {
                    Task { await state.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isRecording)

                Button("Stop Recording") {
                    Task { await state.stopRecording() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!state.isRecording)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open Project…") { state.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import Video…") { state.importVideoPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                Menu("Open Recent") {
                    ForEach(state.recentProjects(), id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            state.openRecent(url)
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { state.saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.project == nil)
                Button("Save As…") { state.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                    .disabled(state.project == nil)
                Divider()
                Button("Export Video…") { state.exportPanel() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(state.project == nil)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { state.player.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(state.project == nil)
                Divider()
                Button("Back One Second") {
                    state.scrub(to: state.player.currentTime - 1)
                }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(state.project == nil)
                Button("Forward One Second") {
                    state.scrub(to: state.player.currentTime + 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(state.project == nil)
                Divider()
                Button("Go to Start") { state.scrub(to: 0) }
                    .keyboardShortcut(.home, modifiers: [])
                    .disabled(state.project == nil)
                Button("Go to End") { state.scrub(to: state.player.duration) }
                    .keyboardShortcut(.end, modifiers: [])
                    .disabled(state.project == nil)
            }
            CommandMenu("Commands") {
                Button("Command Menu") { state.showCommandMenu = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView(state: state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set while the main window is deliberately hidden — during a recording,
    /// and while the area selector is up.
    ///
    /// Recut has a single window, and AppKit terminates an app whose last
    /// window goes away when `applicationShouldTerminateAfterLastWindowClosed`
    /// is true. Ordering that window out to get it off the screen therefore
    /// quit the app the instant recording started, with no crash report,
    /// because it wasn't a crash.
    nonisolated(unsafe) static var keepAliveWithoutWindows = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.keepAliveWithoutWindows
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.project != nil {
                EditorView(state: state)
            } else {
                LibraryView(state: state)
            }
        }
        .overlay {
            if let message = state.busyMessage {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(message).font(.system(size: 12))
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottom) {
            if let status = state.statusMessage {
                Text(status)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation { state.statusMessage = nil }
                    }
            }
        }
        .animation(.snappy, value: state.statusMessage)
        .sheet(isPresented: $state.showExportSheet) {
            ExportSheet(state: state)
        }
        .sheet(isPresented: $state.showCommandMenu) {
            CommandMenuView(state: state)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}
