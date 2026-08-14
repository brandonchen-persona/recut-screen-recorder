import Foundation
import AVFoundation

/// A `.recut` package on disk:
///
///     Something.recut/
///       meta.json     – RecordingMeta
///       events.json   – [InputEvent] captured while recording
///       edit.json     – EditModel (trim, zooms, background)
///       video.mov     – the capture, unless the media lives elsewhere
///
/// Keeping the raw capture untouched means every edit stays non-destructive.
final class Project {
    let url: URL
    var meta: RecordingMeta
    var events: [InputEvent]
    var edit: EditModel
    /// Set when edit.json existed but couldn't be read, so the UI can say so
    /// instead of quietly presenting a project reset to its defaults.
    var editLoadFailure: String?

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Whether the recording this project points at is still on disk.
    ///
    /// An imported video isn't copied into the package, so it can be moved or
    /// deleted from under a project. AVFoundation's own error for that case is
    /// "The operation could not be completed", which tells nobody anything.
    var videoFileExists: Bool {
        FileManager.default.fileExists(atPath: videoURL.path)
    }

    /// The error to show when it isn't.
    var missingVideoError: RecutError {
        .message("""
            The recording this project points at is missing:

            \(videoURL.path)

            If it was moved, put it back — the project keeps the path rather \
            than a copy.
            """)
    }

    var videoURL: URL {
        meta.videoFile.hasPrefix("/")
            ? URL(fileURLWithPath: meta.videoFile)
            : url.appendingPathComponent(meta.videoFile)
    }

    init(url: URL, meta: RecordingMeta, events: [InputEvent], edit: EditModel) {
        self.url = url
        self.meta = meta
        self.events = events
        self.edit = edit
    }

    // MARK: Locations

    static var libraryDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Recut", isDirectory: true)
    }

    static func newProjectURL(named name: String) -> URL {
        let dir = libraryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var candidate = dir.appendingPathComponent("\(name).recut", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n).recut", isDirectory: true)
            n += 1
        }
        return candidate
    }

    // MARK: Load / save

    static func load(_ url: URL) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let meta = try decoder.decode(
            RecordingMeta.self,
            from: Data(contentsOf: url.appendingPathComponent("meta.json"))
        )

        var events: [InputEvent] = []
        if let data = try? Data(contentsOf: url.appendingPathComponent("events.json")) {
            events = (try? decoder.decode([InputEvent].self, from: data)) ?? []
        }

        var edit = EditModel()
        var editLoadFailure: String?
        let editURL = url.appendingPathComponent("edit.json")
        let storedEdit: EditModel? = {
            guard let data = try? Data(contentsOf: editURL) else { return nil }
            do {
                return try decoder.decode(EditModel.self, from: data)
            } catch {
                // Losing an edit silently is far worse than showing an error —
                // this is how a decoding regression stayed hidden once already.
                editLoadFailure = "\(error)"
                return nil
            }
        }()

        if let storedEdit {
            edit = storedEdit
        } else {
            edit.clips = [Clip(sourceStart: 0, sourceEnd: meta.duration)]
            edit.segments = ZoomPlanner.plan(
                events: events,
                settings: edit.autoZoom,
                range: 0...max(0.01, meta.duration)
            )
        }
        if edit.clips.isEmpty {
            edit.clips = [Clip(sourceStart: 0, sourceEnd: max(0.01, meta.duration))]
        }
        if meta.cursorIsSynthetic == true, edit.cursor.mode == .recorded {
            edit.cursor.mode = .synthetic
        }
        let project = Project(url: url, meta: meta, events: events, edit: edit)
        project.editLoadFailure = editLoadFailure
        return project
    }

    func save() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try encoder.encode(meta).write(to: url.appendingPathComponent("meta.json"), options: .atomic)
        try encoder.encode(edit).write(to: url.appendingPathComponent("edit.json"), options: .atomic)
        // Events never change after capture, so only write them if missing.
        let eventsURL = url.appendingPathComponent("events.json")
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            try encoder.encode(events).write(to: eventsURL, options: .atomic)
        }
    }

    /// Wraps an existing movie file in a project without copying the media.
    static func importing(videoURL: URL) async throws -> Project {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecutError.message("That file has no video track.")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)
        let fps = try await Int(track.load(.nominalFrameRate).rounded())

        let meta = RecordingMeta(
            width: Int(abs(displaySize.width).rounded()),
            height: Int(abs(displaySize.height).rounded()),
            duration: duration,
            fps: max(1, fps),
            createdAt: Date(),
            videoFile: videoURL.path,
            displayName: videoURL.deletingPathExtension().lastPathComponent
        )

        var edit = EditModel()
        edit.clips = [Clip(sourceStart: 0, sourceEnd: duration)]

        let projectURL = newProjectURL(named: videoURL.deletingPathExtension().lastPathComponent)
        let project = Project(url: projectURL, meta: meta, events: [], edit: edit)
        try project.save()
        return project
    }
}

enum RecutError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
