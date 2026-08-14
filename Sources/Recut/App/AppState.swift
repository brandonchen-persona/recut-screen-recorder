import Foundation
import SwiftUI
import Combine
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

@MainActor
final class AppState: ObservableObject {

    @Published var project: Project?
    @Published var edit = EditModel() { didSet { editChanged(previous: oldValue) } }
    @Published var selection: UUID?
    @Published var errorMessage: String?
    @Published var busyMessage: String?
    @Published var statusMessage: String?
    @Published var showExportSheet = false
    @Published var showCommandMenu = false
    @Published var pendingExportURL: URL?
    @Published var showExportPath = false
    @Published var exportSettings = ExportSettings()
    @Published var selectedClip: UUID?
    @Published var isCropping = false { didSet { previewModeChanged() } }
    @Published var selectedMask: UUID?
    @Published var selectedText: UUID?
    /// True while the purple anchor dot for a manual zoom is on the preview.
    @Published var placingAnchor = false { didSet { previewModeChanged() } }
    @Published var previewQuality: PreviewQuality = .performance {
        didSet { rebuildComposition() }
    }
    /// Screen Studio's Settings → Recording → "Create zooms automatically".
    @Published var createZoomsAutomatically = UserDefaults.standard
        .object(forKey: "createZoomsAutomatically") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(createZoomsAutomatically, forKey: "createZoomsAutomatically")
        }
    }

    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var sourceKind: CaptureSource = .display
    /// Chosen area, in display points with a top-left origin.
    @Published var selectedArea: CGRect?
    /// Which display that area was drawn on, for the record card.
    @Published var areaScreenName: String?
    @Published var microphones: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String? {
        didSet { updateMicrophoneMonitor() }
    }
    /// Live input level, 0...1: from the idle monitor before a take, from the
    /// recorder during one.
    @Published var microphoneLevel: Double = 0
    /// Peak envelope of the open project's audio, for the clip lane. Nil until
    /// it has been read, and stays nil for a silent recording.
    @Published var waveform: Waveform?
    @Published var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String?
    @Published var countdownSeconds = 3
    /// Dim the rest of the screen while recording an area, so the capture
    /// bounds are visible. Never appears in the output — the content filter
    /// excludes this app.
    @Published var dimOutsideArea = UserDefaults.standard
        .object(forKey: "dimOutsideArea") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dimOutsideArea, forKey: "dimOutsideArea") }
    }
    @Published var captureAudio = true
    /// Records key presses, for typing detection and shortcut labels. Needs
    /// Accessibility permission, so it stays off unless explicitly enabled.
    @Published var captureKeystrokes = UserDefaults.standard
        .object(forKey: "captureKeystrokes") as? Bool ?? false {
        didSet { UserDefaults.standard.set(captureKeystrokes, forKey: "captureKeystrokes") }
    }
    /// Hide the OS pointer while capturing so the editor can draw its own.
    @Published var drawCursor = UserDefaults.standard
        .object(forKey: "drawCursor") as? Bool ?? true {
        didSet { UserDefaults.standard.set(drawCursor, forKey: "drawCursor") }
    }
    @Published var permissionDenied = false
    @Published var captureError: String?

    let recorder = ScreenRecorder()
    /// Listens to the chosen microphone while idle, purely to drive the meter.
    private let microphoneMonitor = MicrophoneRecorder()
    let player = PlayerController()
    let exporter = Exporter()
    let renderState = RenderState()
    let still = StillPreview()
    let looks = LookLibrary()

    private var hud: RecordingHUD?
    /// Held across a recording: `NSApp.mainWindow` goes nil once it's hidden.
    private var hiddenWindow: NSWindow?
    private var lastStructure: StructureKey?
    private var lastCursorSmoothing: Double = -1
    private var lastLoopToStart = false
    private var saveTask: Task<Void, Never>?

    // MARK: Undo
    //
    // `edit` changes on every tick of a slider, so snapshotting each change
    // would mean one ⌘Z per pixel of drag. Instead the state from *before* a
    // burst of edits is held back and only committed once the edits go quiet,
    // which groups a drag into the single step a person thinks they made.
    private var history = History<EditModel>(limit: 60)
    private var pendingUndoBaseline: EditModel?
    private var undoCommitTask: Task<Void, Never>?
    private var isApplyingHistory = false
    private let undoQuietPeriod: Duration = .milliseconds(450)
    private var cancellables: Set<AnyCancellable> = []

    var isRecording: Bool { recorder.isRecording }

    init() {
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        exporter.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        player.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        still.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        looks.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A stream that dies mid-recording — display disconnected, disk full —
        // used to set lastError and tell nobody, so the take just vanished.
        recorder.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self else { return }
                hud?.close()
                hud = nil
                webcamPreview.close()
                areaHighlight.close()
                restoreWindow()
                errorMessage = "The recording stopped unexpectedly.\n\n\(message)"
            }
            .store(in: &cancellables)

        recorder.$micLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self, self.isRecording else { return }
                self.microphoneLevel = level
            }
            .store(in: &cancellables)

        recorder.$isPaused
            .removeDuplicates()
            .sink { [weak self] paused in self?.areaHighlight.setPaused(paused) }
            .store(in: &cancellables)

        // The still covers the player while paused and gets out of the way as
        // soon as playback starts.
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                if playing { still.hide() } else { refreshPreview() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Edit plumbing

    private func editChanged(previous: EditModel) {
        if !isApplyingHistory { recordForUndo(previous: previous) }

        renderState.update {
            $0.timeline = Timeline(clips: edit.clips)
            $0.segments = edit.segments
            $0.background = edit.background
            $0.frame = edit.frame
            $0.cursorSettings = edit.cursor
            $0.masks = edit.masks
            $0.webcam = edit.webcam
            $0.shortcuts = edit.shortcuts
            $0.texts = edit.texts
            $0.watermark = edit.watermark
            $0.keepCursorInFrame = edit.autoZoom.keepCursorInFrame
        }

        // Only the clip list and the output shape need the AV composition
        // rebuilt; everything else the compositor reads live.
        let structure = StructureKey(clips: edit.clips, frame: edit.frame)
        if structure != lastStructure {
            lastStructure = structure
            rebuildComposition()
        }
        if edit.cursor.smoothing != lastCursorSmoothing || edit.cursor.loopToStart != lastLoopToStart {
            lastCursorSmoothing = edit.cursor.smoothing
            lastLoopToStart = edit.cursor.loopToStart
            rebuildCursorPath()
        }
        refreshPreview()
        scheduleSave()
    }

    // MARK: - Looks

    func saveLookAsHouseStyle() {
        looks.setHouseStyle(from: edit)
        statusMessage = "New recordings will use this look."
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        looks.addPreset(named: trimmed, from: edit)
        statusMessage = "Saved “\(trimmed)”."
    }

    func applyPreset(_ preset: LookPreset) {
        var updated = edit
        preset.apply(to: &updated)
        edit = updated
        statusMessage = "Applied “\(preset.name)”."
    }

    // MARK: - Undo

    var canUndo: Bool { history.canUndo || pendingUndoBaseline != nil }
    var canRedo: Bool { history.canRedo }

    private func recordForUndo(previous: EditModel) {
        if pendingUndoBaseline == nil { pendingUndoBaseline = previous }
        undoCommitTask?.cancel()
        undoCommitTask = Task { [weak self] in
            try? await Task.sleep(for: self?.undoQuietPeriod ?? .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.commitUndoStep()
        }
    }

    /// Closes the current group so the next edit starts a new one.
    private func commitUndoStep() {
        undoCommitTask?.cancel()
        undoCommitTask = nil
        guard let baseline = pendingUndoBaseline else { return }
        pendingUndoBaseline = nil
        history.record(baseline)
        objectWillChange.send()
    }

    func undo() {
        // A drag still inside its quiet period should be undoable right away
        // rather than waiting for the timer.
        commitUndoStep()
        guard let restored = history.undo(current: edit) else { return }
        applyHistory(restored)
        statusMessage = "Undid the last change."
    }

    func redo() {
        guard let restored = history.redo(current: edit) else { return }
        applyHistory(restored)
        statusMessage = "Redid the change."
    }

    private func applyHistory(_ model: EditModel) {
        isApplyingHistory = true
        edit = model
        isApplyingHistory = false
        // Selections can point at things that no longer exist.
        if let selection, !edit.segments.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if let selectedMask, !edit.masks.contains(where: { $0.id == selectedMask }) {
            self.selectedMask = nil
        }
        if let selectedClip, !edit.clips.contains(where: { $0.id == selectedClip }) {
            self.selectedClip = nil
        }
        if let selectedText, !edit.texts.contains(where: { $0.id == selectedText }) {
            self.selectedText = nil
        }
    }

    private func clearHistory() {
        undoCommitTask?.cancel()
        undoCommitTask = nil
        pendingUndoBaseline = nil
        history.clear()
    }

    /// Moves the playhead and redraws, pausing first so the seek sticks.
    func scrub(to time: Double) {
        player.pause()
        player.seek(to: time)
        refreshPreview()
    }

    /// Redraws the paused frame. While playing, the compositor is already
    /// producing frames and there is nothing to do.
    func refreshPreview() {
        guard !player.isPlaying, project != nil else { return }
        let timeline = Timeline(clips: edit.clips)
        still.update(
            sourceTime: timeline.sourceTime(at: player.currentTime),
            snapshot: renderState.snapshot,
            // Same rule as the player composition, so the paused still and
            // the playing video are never different sizes.
            canvasSize: CompositionBuilder.canvasSize(
                forWidth: CompositionBuilder.previewWidth(
                    quality: previewQuality.previewWidth, source: sourceSize
                ),
                source: sourceSize,
                frame: edit.frame
            )
        )
    }

    /// Cheap equality check for "does the AV composition need rebuilding".
    private struct StructureKey: Equatable {
        var clips: [Clip]
        var aspect: AspectRatio
        var crop: NRect

        init(clips: [Clip], frame: FrameSettings) {
            self.clips = clips
            self.aspect = frame.aspect
            self.crop = frame.crop
        }
    }

    private func rebuildComposition() {
        guard project != nil, !edit.clips.isEmpty else { return }
        do {
            try player.rebuild(
                clips: edit.clips, frame: edit.frame,
                state: renderState, quality: previewQuality
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The crop tool and the manual-zoom anchor both need to see the whole
    /// frame, unzoomed, so the overlay lines up with the pixels.
    private func previewModeChanged() {
        let full = isCropping || placingAnchor
        renderState.update { $0.previewFullFrame = full }
        player.pause()
        refreshPreview()
    }

    private func rebuildCursorPath() {
        guard let project else { return }
        let path = CursorPath(
            events: project.events, duration: project.meta.duration, settings: edit.cursor
        )
        renderState.update { $0.cursor = path }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let project else { return }
        project.edit = edit
        try? project.save()
    }

    // MARK: - Geometry the preview overlays need

    /// Source size, before cropping.
    var sourceSize: CGSize {
        player.media?.sourceSize ?? project?.meta.size ?? CGSize(width: 16, height: 9)
    }

    /// width / height of the whole source frame, ignoring the crop.
    var fullSourceAspect: Double {
        let s = sourceSize
        return max(1, s.width) / max(1, s.height)
    }

    /// width / height of the region the crop keeps.
    var croppedSourceAspect: Double {
        let s = sourceSize
        let w = max(1, s.width * edit.frame.crop.width)
        let h = max(1, s.height * edit.frame.crop.height)
        return w / h
    }

    /// width / height of the exported canvas.
    var canvasAspect: Double {
        edit.frame.aspect.value ?? croppedSourceAspect
    }

    /// True for a recording noticeably taller than it is wide while the canvas
    /// is still following the source — an area strip that would otherwise
    /// export as a sliver.
    var suggestsWideCanvas: Bool {
        edit.frame.aspect == .auto && croppedSourceAspect < 0.8
    }

    var canvasDescription: String {
        let size = CompositionBuilder.canvasSize(
            forWidth: exportSettings.width, source: sourceSize, frame: edit.frame
        )
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    var selectedSegmentIndex: Int? {
        guard let selection else { return nil }
        return edit.segments.firstIndex { $0.id == selection }
    }

    // MARK: - Recording

    func refreshDisplays() async {
        captureError = nil

        guard ScreenRecorder.hasScreenRecordingPermission else {
            displays = []
            permissionDenied = true
            return
        }

        do {
            let found = try await ScreenRecorder.shareableDisplays()
            displays = found
            windows = (try? await ScreenRecorder.shareableWindows()) ?? []
            microphones = MicrophoneRecorder.availableDevices()
            cameras = WebcamRecorder.availableDevices()
            permissionDenied = false
            if selectedDisplayID == nil || !found.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = found.first?.displayID
            }
            if selectedWindowID == nil || !windows.contains(where: { $0.windowID == selectedWindowID }) {
                selectedWindowID = windows.first?.windowID
            }
        } catch {
            // TCC says yes but capture still failed — a real error, not a
            // permission problem. Say so rather than sending the user back to
            // Settings for a toggle that's already on.
            displays = []
            permissionDenied = false
            captureError = error.localizedDescription
        }
    }

    func requestScreenRecordingPermission() async {
        ScreenRecorder.requestScreenRecordingPermission()
        await refreshDisplays()
    }

    /// Puts together the target from whatever the library card has selected.
    private func currentTarget() -> RecordingTarget? {
        let display = displays.first { $0.displayID == selectedDisplayID } ?? displays.first
        switch sourceKind {
        case .display:
            return display.map { .display($0) }
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID })
            else { return nil }
            return .window(window)
        case .area:
            guard let display, let area = selectedArea else { return nil }
            return .area(display, area)
        }
    }

    /// Opens the drag-out overlay on every display and remembers both the
    /// region and the display it was drawn on.
    func chooseArea() async {
        await refreshDisplays()
        guard !displays.isEmpty else {
            errorMessage = "No display available."
            return
        }
        hideMainWindow()
        let choice = await ScreenOverlay.selectArea()
        restoreWindow()

        guard let choice else { return }
        guard let display = display(for: choice.screen) else {
            errorMessage = "That display isn't available for recording."
            return
        }
        selectedArea = choice.rect
        // The area belongs to the display it was drawn on, not to whatever the
        // Display tab happened to have selected.
        selectedDisplayID = display.displayID
        areaScreenName = choice.screen.localizedName
    }

    private func display(for screen: NSScreen) -> SCDisplay? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return displays.first { $0.displayID == number.uint32Value }
    }

    // MARK: - Waveform

    private var waveformTask: Task<Void, Never>?

    /// Reads the envelope off the main thread, from the cache when there is one.
    private func loadWaveform(for project: Project) {
        waveformTask?.cancel()
        if let cached = WaveformExtractor.load(for: project) {
            waveform = cached.isEmpty ? nil : cached
            return
        }
        let url = project.videoURL
        waveformTask = Task { [weak self] in
            let extracted = try? await WaveformExtractor.extract(from: url)
            guard !Task.isCancelled, let self, let extracted else { return }
            await MainActor.run {
                // Only if the same project is still open — opening two in quick
                // succession must not paint the first one's audio on the second.
                guard self.project?.url == project.url else { return }
                self.waveform = extracted.isEmpty ? nil : extracted
            }
            if !extracted.isEmpty { WaveformExtractor.save(extracted, for: project) }
        }
    }

    // MARK: - Microphone monitoring

    /// Runs the meter whenever the record card is on screen and a mic is chosen.
    ///
    /// Discovering a dead microphone belongs before the take, not in the edit.
    func updateMicrophoneMonitor() {
        microphoneMonitor.stop()
        microphoneLevel = 0

        guard project == nil, !isRecording, let device = selectedMicrophone else { return }
        guard MicrophoneRecorder.permissionGranted else {
            // Ask once, on the click that chose a microphone — the point where
            // a permission sheet makes sense to the user.
            Task { @MainActor in
                if await MicrophoneRecorder.requestPermission() { updateMicrophoneMonitor() }
            }
            return
        }

        microphoneMonitor.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                self.microphoneLevel = level
            }
        }
        try? microphoneMonitor.start(device: device)
    }

    func stopMicrophoneMonitor() {
        microphoneMonitor.stop()
        microphoneLevel = 0
    }

    private var selectedMicrophone: AVCaptureDevice? {
        guard let selectedMicrophoneID else { return nil }
        return microphones.first { $0.uniqueID == selectedMicrophoneID }
    }

    private var selectedCamera: AVCaptureDevice? {
        guard let selectedCameraID else { return nil }
        return cameras.first { $0.uniqueID == selectedCameraID }
    }

    func startRecording() async {
        // The recorder wants the device to itself; the meter carries on from
        // the recorder's own buffers.
        stopMicrophoneMonitor()
        await refreshDisplays()
        guard let target = currentTarget() else {
            errorMessage = sourceKind == .area
                ? "Choose an area to record first."
                : "Nothing available to record."
            return
        }

        var mic = selectedMicrophone
        if mic != nil, !MicrophoneRecorder.permissionGranted {
            if await !MicrophoneRecorder.requestPermission() {
                mic = nil
                errorMessage = "Microphone access was declined, so the recording will be silent."
            }
        }

        var camera = selectedCamera
        if camera != nil, !WebcamRecorder.permissionGranted {
            if await !WebcamRecorder.requestPermission() {
                camera = nil
                errorMessage = "Camera access was declined, so no webcam will be recorded."
            }
        }

        do {
            closeProject()
            hideMainWindow()
            // Give the window server a moment to actually take it off screen.
            try await Task.sleep(nanoseconds: 350_000_000)

            if dimOutsideArea, case .area(let display, let rect) = target,
               let screen = ScreenRecorder.nsScreen(for: display) {
                areaHighlight.show(rect: rect, on: screen)
            }

            await ScreenOverlay.countdown(
                from: countdownSeconds,
                on: target.display.flatMap { ScreenRecorder.nsScreen(for: $0) }
            )

            try await recorder.start(
                target: target,
                captureAudio: captureAudio,
                microphoneDevice: mic,
                webcamDevice: camera,
                drawCursor: drawCursor,
                autoZoom: createZoomsAutomatically,
                captureKeys: captureKeystrokes
            )
            presentHUD()
            if camera != nil { webcamPreview.show(session: recorder.webcam.session) }
        } catch {
            areaHighlight.close()
            restoreWindow()
            errorMessage = error.localizedDescription
        }
    }

    /// Throws away what's been captured and immediately starts over.
    /// Asks before throwing footage away.
    ///
    /// Only once there's something to lose: a dialog over a two-second misfire
    /// is friction, one over a ten-minute walkthrough is the whole point.
    private func confirmDiscard(button: String) -> Bool {
        guard recorder.elapsed > 2 else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this recording?"
        alert.informativeText = """
            \(TimeFormat.clock(recorder.elapsed)) of recording will be deleted. \
            This can't be undone.
            """
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Keep recording")
        // The recorder keeps running behind the dialog on purpose: pausing
        // would silently cut a hole in a take the user has decided to keep.
        return alert.runModal() == .alertFirstButtonReturn
    }

    func restartRecording() async {
        guard confirmDiscard(button: "Discard and restart") else { return }
        hud?.close()
        hud = nil
        webcamPreview.close()
        areaHighlight.close()
        await recorder.cancel()
        await startRecording()
    }

    /// Takes the main window off screen. Must go through here rather than
    /// calling `orderOut` directly: Recut has one window, and losing it
    /// terminates the app unless the delegate is told to hold on.
    private func hideMainWindow() {
        AppDelegate.keepAliveWithoutWindows = true
        hiddenWindow = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        hiddenWindow?.orderOut(nil)
    }

    private func restoreWindow() {
        NSApp.activate(ignoringOtherApps: true)
        hiddenWindow?.makeKeyAndOrderFront(nil)
        hiddenWindow = nil
        AppDelegate.keepAliveWithoutWindows = false
    }

    func stopRecording() async {
        hud?.close()
        hud = nil
        webcamPreview.close()
        areaHighlight.close()
        busyMessage = "Finishing recording…"
        defer { busyMessage = nil }
        do {
            let project = try await recorder.stop()
            looks.applyHouseStyle(to: &project.edit)
            try? project.save()
            restoreWindow()
            await open(project)
        } catch {
            restoreWindow()
            errorMessage = error.localizedDescription
        }
    }

    func cancelRecording() async {
        guard confirmDiscard(button: "Discard") else { return }
        hud?.close()
        hud = nil
        webcamPreview.close()
        areaHighlight.close()
        await recorder.cancel()
        restoreWindow()
    }

    private let webcamPreview = WebcamPreviewPanel()
    private let areaHighlight = AreaHighlightPanel()

    private func presentHUD() {
        let hud = RecordingHUD(
            recorder: recorder,
            onStop: { [weak self] in Task { await self?.stopRecording() } },
            onCancel: { [weak self] in Task { await self?.cancelRecording() } },
            onRestart: { [weak self] in Task { await self?.restartRecording() } }
        )
        hud.show()
        self.hud = hud
    }

    // MARK: - Projects

    func open(_ project: Project) async {
        saveNow()
        stopMicrophoneMonitor()
        self.project = project
        self.selection = nil
        self.waveform = nil
        loadWaveform(for: project)

        do {
            guard project.videoFileExists else { throw project.missingVideoError }
            let media = try await player.load(url: project.videoURL)
            project.meta.duration = media.sourceDuration

            var loaded = project.edit
            if loaded.clips.isEmpty {
                loaded.clips = [Clip(sourceStart: 0, sourceEnd: media.sourceDuration)]
            }
            // Clamp anything the source can no longer support.
            loaded.clips = loaded.clips.map {
                var c = $0
                c.sourceEnd = min(c.sourceEnd, media.sourceDuration)
                c.sourceStart = min(c.sourceStart, max(0, c.sourceEnd - 0.05))
                return c
            }.filter { $0.sourceDuration > 0.02 }

            renderState.update {
                $0.cursor = CursorPath(
                    events: project.events, duration: media.sourceDuration, settings: loaded.cursor
                )
                $0.timeline = Timeline(clips: loaded.clips)
                $0.segments = loaded.segments
                $0.background = loaded.background
                $0.frame = loaded.frame
                $0.cursorSettings = loaded.cursor
                $0.masks = loaded.masks
                $0.webcam = loaded.webcam
                $0.shortcuts = loaded.shortcuts
                $0.texts = loaded.texts
                $0.watermark = loaded.watermark
                $0.keepCursorInFrame = loaded.autoZoom.keepCursorInFrame
                $0.keyEvents = project.events.filter { $0.kind == .key }
            }

            if let failure = project.editLoadFailure {
                errorMessage = "This project's edits couldn't be read, so it opened with "
                    + "default settings. Nothing has been overwritten yet.\n\n\(failure)"
            }

            clearHistory()
            lastStructure = nil
            lastCursorSmoothing = loaded.cursor.smoothing
            lastLoopToStart = loaded.cursor.loopToStart
            self.edit = loaded
            player.seek(to: 0)
            await still.load(project: project)
            refreshPreview()
        } catch {
            self.project = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Clips

    func splitAtPlayhead() {
        let t = player.currentTime
        let timeline = Timeline(clips: edit.clips)
        guard let entry = timeline.entry(atOutput: t) else { return }
        guard let index = edit.clips.firstIndex(where: { $0.id == entry.clipID }) else { return }

        let source = timeline.sourceTime(at: t)
        let clip = edit.clips[index]
        guard source > clip.sourceStart + 0.1, source < clip.sourceEnd - 0.1 else { return }

        var left = clip
        left.sourceEnd = source
        var right = clip
        right.id = UUID()
        right.sourceStart = source

        edit.clips.replaceSubrange(index...index, with: [left, right])
        selectedClip = right.id
    }

    func removeClip(_ id: UUID) {
        guard edit.clips.count > 1 else { return }
        edit.clips.removeAll { $0.id == id }
        if selectedClip == id { selectedClip = nil }
    }

    func setSpeed(_ speed: Double, for id: UUID) {
        guard let i = edit.clips.firstIndex(where: { $0.id == id }) else { return }
        edit.clips[i].speed = max(0.25, min(20, speed))
    }

    func setVolume(_ volume: Double, for id: UUID) {
        guard let i = edit.clips.firstIndex(where: { $0.id == id }) else { return }
        edit.clips[i].volume = max(0, min(2, volume))
    }

    func closeProject() {
        saveNow()
        // Back on the record card, so the meter is worth running again.
        defer { updateMicrophoneMonitor() }
        clearHistory()
        still.clear()
        player.unload()
        project = nil
        selection = nil
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Project.libraryDirectory
        panel.message = "Choose a .recut project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let project = try Project.load(url)
                await open(project)
            } catch {
                errorMessage = "Couldn't open that project: \(error.localizedDescription)"
            }
        }
    }

    func importVideoPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to edit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let project = try await Project.importing(videoURL: url)
                looks.applyHouseStyle(to: &project.edit)
                try? project.save()
                await open(project)
            } catch {
                errorMessage = "Couldn't import that video: \(error.localizedDescription)"
            }
        }
    }

    func openRecent(_ url: URL) {
        Task {
            do {
                let project = try Project.load(url)
                await open(project)
            } catch {
                errorMessage = "Couldn't open that project: \(error.localizedDescription)"
            }
        }
    }

    /// Copies the package somewhere else and continues editing there, so the
    /// original is left as it was.
    func saveAs() {
        guard let project else { return }
        saveNow()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).recut"
        panel.canCreateDirectories = true
        panel.message = "Save a copy of this project"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: project.url, to: destination)
            let copy = try Project.load(destination)
            Task { await open(copy) }
            statusMessage = "Saved to \(destination.lastPathComponent)."
        } catch {
            errorMessage = "Couldn't save a copy: \(error.localizedDescription)"
        }
    }

    func recentProjects() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Project.libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "recut" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
    }

    // MARK: - Zoom editing

    func regenerateAutoZoom() {
        guard let project else { return }
        var copy = edit
        ZoomPlanner.regenerate(in: &copy, events: project.events, duration: project.meta.duration)
        edit = copy
        selection = nil
    }

    func addZoomAtPlayhead() {
        let timeline = Timeline(clips: edit.clips)
        let source = timeline.sourceTime(at: player.currentTime)
        let span = edit.sourceRange
        let start = max(span.lowerBound, source - 0.4)
        let end = min(span.upperBound, start + 2.6)
        guard end - start > 0.5 else { return }

        // Point it at wherever the cursor was, which is usually what's wanted.
        let anchor = renderState.snapshot.cursor.position(at: source)

        let segment = ZoomSegment(
            start: start, end: end,
            scale: edit.autoZoom.clickScale,
            easeIn: edit.autoZoom.leadIn,
            easeOut: edit.autoZoom.easeOut,
            mode: .manual,
            anchor: anchor,
            isManual: true
        )
        edit.segments.append(segment)
        edit.segments.sort { $0.start < $1.start }
        selection = segment.id
    }

    // MARK: - Typing

    var hasKeyEvents: Bool {
        project?.events.contains { $0.kind == .key } ?? false
    }

    var typingClipCount: Int {
        edit.clips.filter(\.isTyping).count
    }

    /// Cuts every detected typing run into its own clip and speeds it up.
    func findTypingSegments() {
        guard let project else { return }
        let ranges = TypingDetector.detect(
            events: project.events, range: edit.sourceRange
        )
        guard !ranges.isEmpty else {
            statusMessage = hasKeyEvents
                ? "No typing long enough to be worth speeding up."
                : "This recording has no key presses to work from."
            return
        }
        edit.clips = TypingDetector.apply(
            ranges: ranges, to: edit.clips, speed: edit.typing.speed
        )
        statusMessage = "Sped up \(ranges.count) typing "
            + (ranges.count == 1 ? "segment." : "segments.")
    }

    /// Screen Studio's "apply to all typing parts".
    func applySpeedToAllTypingClips() {
        for i in edit.clips.indices where edit.clips[i].isTyping {
            edit.clips[i].speed = edit.typing.speed
        }
    }

    /// Turns key capture on, asking for Accessibility if it isn't granted yet.
    func enableKeystrokeCapture() {
        if KeyTracker.isTrusted {
            captureKeystrokes = true
            statusMessage = "Key presses will be recorded from the next recording."
        } else {
            KeyTracker.requestTrust()
            captureKeystrokes = true
            statusMessage = "Grant Recut Accessibility access, then start a recording."
        }
    }

    // MARK: - Text callouts

    var selectedTextIndex: Int? {
        guard let selectedText else { return nil }
        return edit.texts.firstIndex { $0.id == selectedText }
    }

    func addTextAtPlayhead() {
        let timeline = Timeline(clips: edit.clips)
        let source = timeline.sourceTime(at: player.currentTime)
        let span = edit.sourceRange
        let start = max(span.lowerBound, source)
        let end = min(span.upperBound, start + 3.0)
        guard end - start > 0.3 else { return }

        let overlay = TextOverlay(start: start, end: end)
        edit.texts.append(overlay)
        edit.texts.sort { $0.start < $1.start }
        selectedText = overlay.id
    }

    func deleteSelectedText() {
        guard let selectedText else { return }
        edit.texts.removeAll { $0.id == selectedText }
        self.selectedText = nil
    }

    // MARK: - Masks

    var selectedMaskIndex: Int? {
        guard let selectedMask else { return nil }
        return edit.masks.firstIndex { $0.id == selectedMask }
    }

    func addMaskAtPlayhead() {
        let timeline = Timeline(clips: edit.clips)
        let (start, end) = MaskRegion.defaultSpan(
            atOutput: player.currentTime, timeline: timeline, bounds: edit.sourceRange
        )
        guard end - start > 0.3 else { return }

        let mask = MaskRegion(start: start, end: end)
        edit.masks.append(mask)
        edit.masks.sort { $0.start < $1.start }
        selectedMask = mask.id
    }

    func deleteSelectedMask() {
        guard let selectedMask else { return }
        edit.masks.removeAll { $0.id == selectedMask }
        self.selectedMask = nil
    }

    func deleteSelectedSegment() {
        guard let selection else { return }
        edit.segments.removeAll { $0.id == selection }
        self.selection = nil
    }

    // MARK: - Export

    /// Saves the frame under the playhead as a PNG, at full output size.
    ///
    /// A launch post needs a hero image as often as it needs a video, and the
    /// composited frame — background, shadow, zoom and all — is already the
    /// picture people want.
    func exportStill(toClipboard: Bool = false) {
        guard let project else { return }
        let timeline = Timeline(clips: edit.clips)
        let sourceTime = timeline.sourceTime(at: player.currentTime)
        let canvas = CompositionBuilder.canvasSize(
            forWidth: exportSettings.width, source: sourceSize, frame: edit.frame
        )

        var url: URL?
        if !toClipboard {
            let panel = NSSavePanel()
            let stamp = TimeFormat.clock(player.currentTime)
                .replacingOccurrences(of: ":", with: ".")
            panel.nameFieldStringValue = "\(project.name) \(stamp).png"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        let snapshot = renderState.snapshot
        Task { @MainActor in
            guard let image = await still.renderStill(
                sourceTime: sourceTime, snapshot: snapshot, canvasSize: canvas
            ) else {
                errorMessage = "Could not render that frame."
                return
            }
            if let url {
                guard Self.writePNG(image, to: url) else {
                    errorMessage = "Could not write \(url.lastPathComponent)."
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
                statusMessage = "Frame copied."
            }
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    func exportPanel() {
        guard project != nil else { return }
        showExportSheet = true
    }

    /// `toClipboard` writes to a temporary file and copies it, so the user can
    /// paste straight into Slack or a doc without picking a location.
    func export(toClipboard: Bool) {
        guard let project else { return }

        let name = "\(project.name).\(exportSettings.format.rawValue)"
        let url: URL
        if toClipboard {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Recut", isDirectory: true)
                .appendingPathComponent(name)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [exportSettings.format.contentType]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        pendingExportURL = url
        showExportPath = false

        Task {
            do {
                saveNow()
                try await exporter.export(
                    project: project, edit: edit, settings: exportSettings, to: url
                )
                showExportSheet = false
                pendingExportURL = nil
                if toClipboard {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([url as NSURL])
                    busyMessage = nil
                    statusMessage = "Copied \(name) to the clipboard."
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                showExportSheet = false
                pendingExportURL = nil
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
