import Foundation

/// The styling half of an edit — everything that should look the same across a
/// set of clips, separated from the parts that belong to one recording.
///
/// A launch is ten or twenty clips that have to read as a set. Before this,
/// every recording started from factory defaults and was restyled by hand, so
/// inconsistency wasn't a risk, it was the default outcome.
///
/// Deliberately excludes clips, zoom segments, masks, text and the crop: those
/// describe *this* recording's content, not the house style.
struct LookPreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var background: BackgroundSettings
    var cursor: CursorSettings
    var webcam: WebcamSettings
    var shortcuts: ShortcutSettings
    var aspect: AspectRatio
    var device: DeviceFrame
    /// The *feel* of auto-zoom — magnification and timing — not whether a
    /// particular recording ended up with zooms.
    var autoZoom: AutoZoomSettings
    var watermark: WatermarkSettings

    init(name: String, from edit: EditModel) {
        self.name = name
        background = edit.background
        cursor = edit.cursor
        webcam = edit.webcam
        shortcuts = edit.shortcuts
        aspect = edit.frame.aspect
        device = edit.frame.device
        autoZoom = edit.autoZoom
        watermark = edit.watermark
    }

    /// Applies the style, leaving the recording's own content alone.
    func apply(to edit: inout EditModel) {
        edit.background = background
        edit.cursor = cursor
        edit.webcam = webcam
        edit.shortcuts = shortcuts
        edit.frame.aspect = aspect
        edit.frame.device = device
        edit.watermark = watermark

        // Whether zooms were generated is a property of the recording; how they
        // should feel is part of the look.
        let wasEnabled = edit.autoZoom.enabled
        edit.autoZoom = autoZoom
        edit.autoZoom.enabled = wasEnabled
    }

    /// Tolerant decoding, for the same reason every other stored struct has it:
    /// adding a field must not orphan saved presets. See NOTES.md.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        background = try c.decodeIfPresent(BackgroundSettings.self, forKey: .background)
            ?? BackgroundSettings()
        cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? CursorSettings()
        webcam = try c.decodeIfPresent(WebcamSettings.self, forKey: .webcam) ?? WebcamSettings()
        shortcuts = try c.decodeIfPresent(ShortcutSettings.self, forKey: .shortcuts)
            ?? ShortcutSettings()
        aspect = try c.decodeIfPresent(AspectRatio.self, forKey: .aspect) ?? .auto
        device = try c.decodeIfPresent(DeviceFrame.self, forKey: .device) ?? .none
        autoZoom = try c.decodeIfPresent(AutoZoomSettings.self, forKey: .autoZoom)
            ?? AutoZoomSettings()
        watermark = try c.decodeIfPresent(WatermarkSettings.self, forKey: .watermark)
            ?? WatermarkSettings()
    }
}

/// Saved looks, plus the one new recordings inherit.
///
/// Lives beside the projects rather than in `UserDefaults` so a look can be
/// copied between machines, and so a corrupt entry can be deleted by hand.
@MainActor
final class LookLibrary: ObservableObject {

    @Published private(set) var presets: [LookPreset] = []
    /// Applied to every new recording and import. Nil means factory defaults.
    @Published private(set) var houseStyle: LookPreset?

    private let fileURL: URL

    private struct Stored: Codable {
        var presets: [LookPreset] = []
        var houseStyle: LookPreset?
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Recut", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("looks.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        presets = stored.presets
        houseStyle = stored.houseStyle
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = Stored(presets: presets, houseStyle: houseStyle)
        try? encoder.encode(stored).write(to: fileURL, options: .atomic)
    }

    /// Remembers the current look so the next recording opens looking the same.
    func setHouseStyle(from edit: EditModel) {
        houseStyle = LookPreset(name: "House style", from: edit)
        save()
    }

    func clearHouseStyle() {
        houseStyle = nil
        save()
    }

    @discardableResult
    func addPreset(named name: String, from edit: EditModel) -> LookPreset {
        var preset = LookPreset(name: name, from: edit)
        // Re-saving under an existing name replaces it, which is what someone
        // means by "update my preset".
        if let index = presets.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            preset.id = presets[index].id
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        return preset
    }

    func removePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    /// The look a brand-new recording should start from.
    func applyHouseStyle(to edit: inout EditModel) {
        houseStyle?.apply(to: &edit)
    }
}
