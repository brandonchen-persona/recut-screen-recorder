import SwiftUI

/// ⌘K palette. Keyboard access to everything the toolbars and inspector do,
/// without hunting for the control.
struct CommandMenuView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var commands: [Command] { Command.all(for: state) }

    private var matches: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { $0.matches(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(matches.first(atIndex: highlighted)) }
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        Button { run(command) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: command.icon)
                                    .frame(width: 18)
                                    .foregroundStyle(.secondary)
                                Text(command.title)
                                    .font(.system(size: 13))
                                Spacer()
                                if let shortcut = command.shortcut {
                                    Text(shortcut)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(
                                index == highlighted
                                    ? Color.accentColor.opacity(0.18) : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if matches.isEmpty {
                        Text("Nothing matches “\(query)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 22)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 460)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, matches.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
    }

    private func run(_ command: Command?) {
        guard let command else { return }
        dismiss()
        // Let the sheet finish dismissing before anything modal appears.
        DispatchQueue.main.async { command.action() }
    }
}

private extension Array {
    func first(atIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : first
    }
}

struct Command: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var shortcut: String?
    var keywords: [String] = []
    let action: () -> Void

    func matches(_ query: String) -> Bool {
        let haystack = ([title] + keywords).joined(separator: " ").lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    @MainActor
    static func all(for state: AppState) -> [Command] {
        var commands: [Command] = [
            Command(title: "Start recording", icon: "record.circle", shortcut: "⇧⌘R",
                    keywords: ["capture", "new"]) {
                Task { await state.startRecording() }
            },
            Command(title: "Import video…", icon: "square.and.arrow.down", shortcut: "⇧⌘I",
                    keywords: ["open", "movie"]) { state.importVideoPanel() },
            Command(title: "Open project…", icon: "folder", shortcut: "⌘O") {
                state.openProjectPanel()
            },
        ]

        guard state.project != nil else { return commands }

        commands += [
            Command(title: "Undo", icon: "arrow.uturn.backward", shortcut: "⌘Z",
                    keywords: ["revert", "back"]) { state.undo() },
            Command(title: "Redo", icon: "arrow.uturn.forward", shortcut: "⇧⌘Z") {
                state.redo()
            },
            Command(title: "Export…", icon: "square.and.arrow.up", shortcut: "⌘E",
                    keywords: ["save", "render", "mp4", "gif"]) { state.exportPanel() },
            Command(title: "Save project", icon: "tray.and.arrow.down", shortcut: "⌘S") {
                state.saveNow()
            },
            Command(title: "Add zoom at playhead", icon: "plus.magnifyingglass",
                    keywords: ["magnify"]) { state.addZoomAtPlayhead() },
            Command(title: "Regenerate zooms", icon: "arrow.clockwise",
                    keywords: ["auto"]) { state.regenerateAutoZoom() },
            Command(title: "Cut at playhead", icon: "scissors", shortcut: "⌘B",
                    keywords: ["split", "trim"]) { state.splitAtPlayhead() },
            Command(title: "Add mask or highlight", icon: "rectangle.dashed",
                    keywords: ["blur", "hide", "cover"]) { state.addMaskAtPlayhead() },
            Command(title: "Save frame as PNG", icon: "photo",
                    keywords: ["still", "screenshot", "image"]) { state.exportStill() },
            Command(title: "Copy frame to clipboard", icon: "doc.on.doc",
                    keywords: ["still", "image"]) { state.exportStill(toClipboard: true) },
            Command(title: "Add text callout", icon: "textformat",
                    keywords: ["caption", "label", "title"]) { state.addTextAtPlayhead() },
            Command(title: "Toggle crop", icon: "crop", shortcut: "C") {
                state.isCropping.toggle()
            },
            Command(title: "Play / pause", icon: "playpause", shortcut: "Space") {
                state.player.togglePlay()
            },
            Command(title: "Back to library", icon: "chevron.left") { state.closeProject() },
        ]

        for ratio in AspectRatio.allCases {
            commands.append(Command(
                title: "Aspect ratio: \(ratio.label) \(ratio.detail)",
                icon: "aspectratio",
                keywords: ["ratio", "size", ratio.detail]
            ) { state.edit.frame.aspect = ratio })
        }

        for kind in BackgroundKind.allCases {
            commands.append(Command(
                title: "Background: \(kind.label)",
                icon: "square.on.square",
                keywords: ["backdrop"]
            ) { state.edit.background.kind = kind })
        }

        for mode in CursorMode.allCases {
            commands.append(Command(
                title: "Cursor: \(mode.label)",
                icon: "cursorarrow",
                keywords: ["pointer", "mouse"]
            ) { state.edit.cursor.mode = mode })
        }

        return commands
    }
}
