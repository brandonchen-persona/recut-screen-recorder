import Foundation
import AVFoundation

/// Captures the microphone alongside the screen.
///
/// Its buffers are timestamped on the same host clock ScreenCaptureKit uses, so
/// they drop straight into the same `AVAssetWriter` session as a second audio
/// track without any resynchronisation.
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

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(device: AVCaptureDevice) throws {
        guard !session.isRunning else { return }
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
        session.commitConfiguration()

        // startRunning blocks; keep it off the main thread.
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
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
        onSample?(sampleBuffer)
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
