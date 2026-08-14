import Foundation
import AppKit

/// Records key presses during a recording, for typing detection and the
/// on-screen shortcut labels.
///
/// This is the only part of Recut that needs **Accessibility** permission —
/// `NSEvent` global monitors deliver mouse events to any app, but withhold key
/// events unless the process is trusted. Everything else works without it, so
/// this stays opt-in rather than being requested at launch.
enum KeyTracker {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "grant Accessibility" prompt. macOS only presents it
    /// once per app; afterwards it silently returns the current state, which is
    /// why the UI also offers a direct link to Settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Renders an event the way a keyboard shortcut is normally written.
    /// Returns nil for keys not worth showing, like a lone modifier.
    static func label(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }

        let named: [UInt16: String] = [
            36: "⏎", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            116: "⇞", 121: "⇟", 115: "↖", 119: "↘", 117: "⌦",
        ]
        if let name = named[event.keyCode] {
            return prefix + name
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        let key = characters.uppercased()
        // Control characters slip through charactersIgnoringModifiers sometimes.
        guard key.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { return nil }
        return prefix + key
    }

    /// True when the press looks like typing prose rather than driving the app.
    static func isTyping(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        // Space, delete and return are all part of writing.
        if [49, 51, 36].contains(event.keyCode) { return true }
        guard let characters = event.charactersIgnoringModifiers else { return false }
        return characters.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    }
}
