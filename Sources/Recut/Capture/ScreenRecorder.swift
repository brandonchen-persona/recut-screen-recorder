import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import Combine

/// Captures a display, window or region with ScreenCaptureKit straight to disk,
/// while `CursorTracker` records the pointer track alongside it.
final class ScreenRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var lastError: String?
    /// Microphone input level while recording, 0...1.
    @Published private(set) var micLevel: Double = 0
    /// Whether this take has a microphone at all, so the HUD can leave the
    /// meter out rather than show a permanently dead one.
    @Published private(set) var hasMicrophone = false

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var webcamInput: AVAssetWriterInput?

    private let tracker = CursorTracker()
    private let microphone = MicrophoneRecorder()
    let webcam = WebcamRecorder()
    private let videoQueue = DispatchQueue(label: "com.recut.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.recut.capture.audio", qos: .userInitiated)
    private let stateLock = NSLock()

    private var sessionStarted = false
    private var firstPTS: CMTime = .zero
    private var lastPTS: CMTime = .zero
    private var frameCount = 0

    /// Time spent paused, subtracted from every sample so the written movie has
    /// no gap where the pause was.
    private var pausedTotal: CMTime = .zero
    private var pauseStartedAt: CMTime?

    private var projectURL: URL?
    private var captureSize = CGSize.zero
    private var captureFPS = 60
    private var targetLabel: String?
    private var targetKind: CaptureSource = .display
    private var drawsCursor = false
    private var planZooms = true
    private var elapsedTimer: Timer?
    private var elapsedBase: TimeInterval = 0
    private var elapsedStart: TimeInterval = 0

    // MARK: - Discovery & permission

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func shareableDisplays() async throws -> [SCDisplay] {
        try await shareableContent().displays
    }

    /// The windows worth offering in the picker.
    ///
    /// ScreenCaptureKit reports everything the window server knows about — 55
    /// entries on a normal desktop. Ordinary application windows all sit at
    /// **layer 0**; the rest is desktop backstops, wallpaper, the Dock, the
    /// Finder's desktop window, menu bar extras and Notification Center
    /// widgets, none of which anyone means to record. Filtering on the layer is
    /// what separates the two, not the title or the size.
    static func shareableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.recut.app"

        let candidates = content.windows
            .filter { $0.windowLayer == 0 }
            .filter { $0.isOnScreen }
            .filter { $0.owningApplication?.bundleIdentifier != ownBundleID }
            .filter { $0.frame.width > 120 && $0.frame.height > 120 }
            .filter { !($0.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

        // Collapse anything an app reports twice under one title, keeping the
        // larger. Two identical rows are worse than one: there's no way to tell
        // which is which, and picking the wrong one records the wrong window.
        var largestByTitle: [String: SCWindow] = [:]
        for window in candidates {
            let key = [
                window.owningApplication?.bundleIdentifier ?? "?",
                window.title ?? "",
            ].joined(separator: "\u{1}")
            let area = window.frame.width * window.frame.height
            if let existing = largestByTitle[key],
               existing.frame.width * existing.frame.height >= area {
                continue
            }
            largestByTitle[key] = window
        }

        return largestByTitle.values.sorted {
            let a = $0.owningApplication?.applicationName ?? ""
            let b = $1.owningApplication?.applicationName ?? ""
            let byApp = a.localizedCaseInsensitiveCompare(b)
            guard byApp == .orderedSame else { return byApp == .orderedAscending }
            return ($0.title ?? "")
                .localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
        }
    }

    /// Asks TCC directly instead of inferring permission from a thrown error —
    /// `SCShareableContent` fails for several reasons and they don't all mean
    /// "denied".
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt. Returns false when the grant is already
    /// recorded against a *different* build of this app, which is the usual
    /// state after a rebuild.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Screen Recording is pinned to the code signature. With no certificate to
    /// sign with, that's the ad-hoc cdhash, which changes on every rebuild.
    static var codeSignatureID: String {
        var code: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code else {
            return "unknown"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let hash = dict[kSecCodeInfoUnique as String] as? Data
        else { return "unknown" }
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static func nsScreen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }
    }

    // MARK: - Start

    /// `drawCursor` hides the system pointer at capture time so the editor can
    /// draw its own from the recorded track — which is the only way to smooth
    /// it, resize it, or hide it afterwards. A baked-in pointer is permanent.
    func start(
        target: RecordingTarget,
        captureAudio: Bool,
        microphoneDevice: AVCaptureDevice? = nil,
        webcamDevice: AVCaptureDevice? = nil,
        drawCursor: Bool = false,
        autoZoom: Bool = true,
        captureKeys: Bool = false,
        fps: Int = 60
    ) async throws {
        guard !isRecording else { return }
        lastError = nil
        planZooms = autoZoom

        let (width, height) = target.captureSize()
        let projectURL = Project.newProjectURL(named: Self.defaultName())
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        // The camera has to be configured before the writer, because its input
        // needs the frame size and every input must exist before startWriting().
        var webcamSize: CGSize?
        if let webcamDevice {
            webcamSize = try? await webcam.prepare(device: webcamDevice)
        }

        try setUpWriter(
            at: projectURL.appendingPathComponent("video.mov"),
            width: width, height: height, fps: fps,
            systemAudio: captureAudio, microphone: microphoneDevice != nil,
            webcamSize: webcamSize
        )

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = !drawCursor
        config.scalesToFit = true
        if case .area(_, let rect) = target {
            config.sourceRect = rect
        }
        if captureAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
        }

        // Keep our own windows (including the recording HUD) out of the capture.
        let content = try await Self.shareableContent()
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.recut.app"
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = target.contentFilter(excluding: ownApps)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        self.stream = stream
        self.projectURL = projectURL
        self.captureSize = CGSize(width: width, height: height)
        self.captureFPS = fps
        self.targetLabel = target.label
        self.targetKind = target.kind
        self.drawsCursor = drawCursor
        self.pausedTotal = .zero
        self.pauseStartedAt = nil

        try await stream.startCapture()

        if let device = microphoneDevice {
            microphone.onSample = { [weak self] buffer in
                self?.appendAudio(buffer, to: .microphone)
            }
            microphone.onLevel = { [weak self] level in
                Task { @MainActor in self?.micLevel = level }
            }
            try? microphone.start(device: device)
        }
        if webcamInput != nil {
            webcam.onSample = { [weak self] buffer in self?.appendWebcam(buffer) }
            webcam.startPreview()
        }

        let pointerFrame = target.pointerFrame
        await MainActor.run {
            self.tracker.start(displayFrame: pointerFrame, captureKeys: captureKeys)
            self.hasMicrophone = microphoneDevice != nil
            self.isRecording = true
            self.isPaused = false
            self.elapsed = 0
            self.elapsedBase = 0
            self.startElapsedTimer()
        }
    }

    private static func defaultName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(df.string(from: Date()))"
    }

    private func setUpWriter(
        at url: URL, width: Int, height: Int, fps: Int,
        systemAudio: Bool, microphone: Bool, webcamSize: CGSize?
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Screen content compresses far better with HEVC; fall back if the
        // machine can't encode it.
        let bitrate = min(Int(Double(width * height * fps) * 0.07), 80_000_000)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        var input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        if !writer.canAdd(input) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecutError.message("Could not configure the video encoder.")
        }
        writer.add(input)
        videoInput = input

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000,
        ]
        if systemAudio {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            track.expectsMediaDataInRealTime = true
            if writer.canAdd(track) { writer.add(track); systemAudioInput = track }
        }
        if microphone {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            track.expectsMediaDataInRealTime = true
            if writer.canAdd(track) { writer.add(track); micInput = track }
        }

        // QuickTime carries several video tracks happily, so the camera rides
        // along in the same file and stays in sync for free.
        if let webcamSize, webcamSize.width > 1, webcamSize.height > 1 {
            let w = Int(webcamSize.width / 2) * 2
            let h = Int(webcamSize.height / 2) * 2
            let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                ],
            ])
            track.expectsMediaDataInRealTime = true
            if writer.canAdd(track) { writer.add(track); webcamInput = track }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecutError.message("Could not start writing the recording.")
        }
        self.writer = writer
        sessionStarted = false
        frameCount = 0
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isPaused else { return }
                self.elapsed = self.elapsedBase + (CACurrentMediaTime() - self.elapsedStart)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    // MARK: - Pause

    /// ScreenCaptureKit has no pause, so samples are dropped while paused and
    /// every later timestamp is shifted back by the paused duration. The
    /// written movie then has no gap at all.
    func togglePause() {
        stateLock.lock()
        if pauseStartedAt == nil {
            pauseStartedAt = lastPTS
        } else if let started = pauseStartedAt {
            pausedTotal = pausedTotal + (lastPTS - started)
            pauseStartedAt = nil
        }
        let paused = pauseStartedAt != nil
        stateLock.unlock()

        DispatchQueue.main.async {
            self.isPaused = paused
            if paused {
                self.elapsedBase = self.elapsed
                self.tracker.pause()
            } else {
                self.elapsedStart = CACurrentMediaTime()
                self.tracker.resume()
            }
        }
    }

    // MARK: - Stop

    /// Synchronous so the lock is never held across a suspension point.
    private func captureState() -> (started: Bool, origin: CMTime, last: CMTime, frames: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (sessionStarted, firstPTS, lastPTS - pausedTotal, frameCount)
    }

    func stop() async throws -> Project {
        guard let stream, let writer, let projectURL else {
            throw RecutError.message("Nothing is being recorded.")
        }

        microphone.stop()
        Task { @MainActor in self.micLevel = 0 }
        webcam.stop()
        try? await stream.stopCapture()

        await MainActor.run {
            self.elapsedTimer?.invalidate()
            self.elapsedTimer = nil
            self.isRecording = false
            self.isPaused = false
        }

        let (started, origin, last, frames) = captureState()

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        webcamInput?.markAsFinished()

        if started {
            writer.endSession(atSourceTime: last)
        }
        await writer.finishWriting()

        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.systemAudioInput = nil
        self.micInput = nil
        let hadWebcam = self.webcamInput != nil
        self.webcamInput = nil
        self.projectURL = nil

        if let error = writer.error { throw error }
        guard started, frames > 1 else {
            try? FileManager.default.removeItem(at: projectURL)
            throw RecutError.message("The recording was too short to save.")
        }

        let events = await MainActor.run { self.tracker.finish(timeOrigin: origin.seconds) }
        let duration = max(0.05, (last - origin).seconds)

        var edit = EditModel()
        edit.clips = [Clip(sourceStart: 0, sourceEnd: duration)]
        if drawsCursor { edit.cursor.mode = .synthetic }
        edit.autoZoom.enabled = planZooms
        edit.segments = ZoomPlanner.plan(
            events: events, settings: edit.autoZoom, range: 0...duration
        )

        let meta = RecordingMeta(
            width: Int(captureSize.width),
            height: Int(captureSize.height),
            duration: duration,
            fps: captureFPS,
            createdAt: Date(),
            videoFile: "video.mov",
            displayName: targetLabel,
            cursorIsSynthetic: drawsCursor,
            source: targetKind,
            webcamFile: hadWebcam ? "video.mov" : nil
        )

        let project = Project(url: projectURL, meta: meta, events: events, edit: edit)
        try project.save()
        return project
    }

    func cancel() async {
        microphone.stop()
        Task { @MainActor in self.micLevel = 0 }
        webcam.stop()
        if let stream { try? await stream.stopCapture() }
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        webcamInput?.markAsFinished()
        writer?.cancelWriting()
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        stream = nil; writer = nil
        videoInput = nil; systemAudioInput = nil; micInput = nil; webcamInput = nil
        projectURL = nil
        await MainActor.run {
            self.elapsedTimer?.invalidate()
            self.elapsedTimer = nil
            self.isRecording = false
            self.isPaused = false
            self.tracker.stop()
        }
    }

    // MARK: - Sample handling

    private enum AudioChannel { case system, microphone }

    private func shift(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return buffer }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(), count: Int(count)
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil
        ) == noErr else { return buffer }

        for i in timings.indices {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset
            }
        }

        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        ) == noErr else { return nil }
        return copy
    }

    private func appendWebcam(_ buffer: CMSampleBuffer) {
        guard buffer.isValid, let writer, writer.status == .writing else { return }

        stateLock.lock()
        let ready = sessionStarted
        let paused = pauseStartedAt != nil
        let offset = pausedTotal
        stateLock.unlock()

        guard ready, !paused,
              let input = webcamInput, input.isReadyForMoreMediaData,
              let shifted = shift(buffer, by: offset)
        else { return }
        input.append(shifted)
    }

    private func appendAudio(_ buffer: CMSampleBuffer, to channel: AudioChannel) {
        guard buffer.isValid, let writer, writer.status == .writing else { return }

        stateLock.lock()
        let ready = sessionStarted
        let paused = pauseStartedAt != nil
        let offset = pausedTotal
        stateLock.unlock()

        guard ready, !paused else { return }
        let input = channel == .system ? systemAudioInput : micInput
        guard let input, input.isReadyForMoreMediaData else { return }
        guard let shifted = shift(buffer, by: offset) else { return }
        input.append(shifted)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit keeps emitting buffers when nothing on screen has
            // changed; those carry no image and must not be written.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw),
                  status == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil
            else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            stateLock.lock()
            lastPTS = pts
            let paused = pauseStartedAt != nil
            let offset = pausedTotal
            if !paused, !sessionStarted {
                sessionStarted = true
                firstPTS = pts
                writer.startSession(atSourceTime: pts)
            }
            if !paused { frameCount += 1 }
            stateLock.unlock()

            guard !paused, let input = videoInput, input.isReadyForMoreMediaData else { return }
            guard let shifted = shift(sampleBuffer, by: offset) else { return }
            input.append(shifted)

        case .audio:
            appendAudio(sampleBuffer, to: .system)

        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
            self.isRecording = false
        }
    }
}
