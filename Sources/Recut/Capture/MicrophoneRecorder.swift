import Foundation
import AVFoundation

/// Captures the microphone alongside the screen.
///
/// Its buffers are timestamped on the same host clock ScreenCaptureKit uses, so
/// they drop straight into the same `AVAssetWriter` session as a second audio
/// track without any resynchronisation.
///
/// "Timestamped on the same clock" is the part external devices break, and the
/// reason the built-in microphone always worked while a USB interface recorded
/// nothing usable — see `hostTimed(_:)`.
final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.recut.capture.mic", qos: .userInitiated)

    /// Called for every buffer while running.
    var onSample: ((CMSampleBuffer) -> Void)?

    /// Called about twenty times a second with the current input level, 0...1.
    ///
    /// Drives the meter next to the microphone picker: the point is to see the
    /// bars move *before* recording, rather than discover a dead mic in the edit.
    var onLevel: ((Double) -> Void)?

    private var lastLevelReport: CFAbsoluteTime = 0
    private var passthrough = false

    /// Puts a captured buffer's timestamps on the host clock.
    ///
    /// This is the one that matters. `AVCaptureSession` stamps its output on
    /// `synchronizationClock`, which for an external interface is that device's
    /// own clock rather than the host's — the property is read-only, so the
    /// session cannot simply be told to use the host clock. ScreenCaptureKit
    /// stamps video on the host clock, and `ScreenRecorder` opens the writer's
    /// session at a *video* timestamp. Feed it microphone buffers counted from a
    /// different epoch and they land nowhere near that session: the track comes
    /// out empty, truncated, or drifting further out of sync the longer you
    /// record. The built-in microphone runs on the host clock already, which is
    /// why it never showed the problem.
    private func hostTimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
        guard !passthrough, let sessionClock = session.synchronizationClock else { return buffer }
        let host = CMClockGetHostTimeClock()
        // Fast path when the session is already on the host clock. Audio devices
        // normally aren't, even the built-in one — its clock is *aligned* with
        // the host rather than the same object, which is why the conversion is
        // near-zero there and large for a device on its own epoch. Converting
        // every buffer rather than once also tracks drift, which is what pulls a
        // long take back into sync instead of letting it slide.
        guard sessionClock !== host else { return buffer }

        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return buffer }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil
        ) == noErr else { return buffer }

        for i in timings.indices {
            let pts = timings[i].presentationTimeStamp
            if pts.isValid {
                timings[i].presentationTimeStamp =
                    CMSyncConvertTime(pts, from: sessionClock, to: host)
            }
            let dts = timings[i].decodeTimeStamp
            if dts.isValid {
                timings[i].decodeTimeStamp = CMSyncConvertTime(dts, from: sessionClock, to: host)
            }
        }

        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        ) == noErr, let copy else { return buffer }
        return copy
    }

    /// Whether this device needs the conversion above — for diagnostics.
    var isOnHostClock: Bool {
        guard let clock = session.synchronizationClock else { return true }
        return clock === CMClockGetHostTimeClock()
    }

    /// What the writer's AAC input is configured for, so the two always agree.
    static let sampleRate = 48_000.0
    static let channelCount = 2

    /// Linear PCM at a fixed rate and channel count.
    ///
    /// `AVCaptureAudioDataOutput` hands over the *device's own* format unless
    /// told otherwise: 44.1 kHz from most interfaces, mono from a headset, and
    /// as many as 18 channels from a rack unit. The AAC encoder downstream does
    /// cope with all of those on its own — that was measured, not assumed — so
    /// this is not what makes external microphones work. It is here to keep the
    /// level meter and the waveform reading one predictable format, and to stop
    /// a 96 kHz device pushing twice the data through the writer for nothing.
    static var canonicalOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func availableDevices() -> [AVCaptureDevice] {
        // `.external` covers USB and Thunderbolt interfaces, which is most of
        // what "my microphone isn't listed" turns out to mean.
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// The device's native format, for the diagnostics command.
    static func describeFormat(_ device: AVCaptureDevice) -> String {
        guard let format = device.activeFormat.formatDescription.audioStreamBasicDescription else {
            return "unknown format"
        }
        let channels = format.mChannelsPerFrame
        return String(format: "%.0f Hz, %u ch", format.mSampleRate, channels)
    }

    /// Opens the device without starting a session, so a microphone that can't
    /// be used is caught *before* the window hides and the countdown runs —
    /// rather than after a take that turns out to be silent.
    static func validate(device: AVCaptureDevice) throws {
        // Retried, because the meter's own session has usually just let go of
        // this device and USB hardware does not always release on the same
        // breath. One attempt turned "the meter was running" into "your
        // microphone can't be used".
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                _ = try AVCaptureDeviceInput(device: device)
                return
            } catch {
                lastError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
            }
        }
        throw RecutError.message("""
            \(device.localizedName) can't be used for recording right now.

            Another app may have it open, or it may have been unplugged. \
            \(lastError?.localizedDescription ?? "")
            """)
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// - Parameter passthrough: leave false. True hands over exactly what the
    ///   device produces — its own format, on its own clock — and exists so
    ///   `--mics … raw` can show the difference. Nothing in the app sets it.
    func start(device: AVCaptureDevice, passthrough: Bool = false) throws {
        self.passthrough = passthrough
        // Reconfiguring a running session is legal and is what switching
        // microphones needs; the old early-return here made a device change a
        // no-op, so the picker moved and the input didn't.
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecutError.message("Could not use \(device.localizedName).")
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecutError.message("Could not capture from \(device.localizedName).")
        }
        session.addOutput(output)
        // Must be set after the output is added to a session, and it is what
        // makes every microphone deliver the same format.
        output.audioSettings = passthrough ? nil : Self.canonicalOutputSettings
        session.commitConfiguration()

        // startRunning blocks; keep it off the main thread.
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        // No `isRunning` guard: `startRunning()` is dispatched, so a quick
        // stop-then-start used to skip this entirely and leave the old delegate
        // wired to a session that was only just coming up.
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        onSample = nil
        onLevel = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(hostTimed(sampleBuffer))
        reportLevel(from: connection)
    }

    private func reportLevel(from connection: AVCaptureConnection) {
        guard let onLevel else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelReport > 0.05 else { return }
        lastLevelReport = now

        // The loudest channel, so a mic wired to one side still reads.
        let peak = connection.audioChannels
            .map { Double($0.averagePowerLevel) }
            .max() ?? -160
        onLevel(Self.meterLevel(dBFS: peak))
    }

    /// Maps a level in dBFS onto a 0...1 meter.
    ///
    /// Linear amplitude spends almost the whole bar on the top few dB, which
    /// makes normal speech look like nothing is arriving. A floor at -54 dB
    /// with a mild curve puts speech in the middle of the bar, where a glance
    /// can tell live from dead.
    static func meterLevel(dBFS: Double) -> Double {
        guard dBFS.isFinite else { return 0 }
        let floorDB = -54.0
        guard dBFS > floorDB else { return 0 }
        let fraction = (dBFS - floorDB) / -floorDB
        return min(1, max(0, pow(fraction, 0.7)))
    }
}
