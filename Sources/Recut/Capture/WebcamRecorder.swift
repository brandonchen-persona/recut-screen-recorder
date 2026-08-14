import Foundation
import AVFoundation
import CoreMedia

/// Captures the webcam alongside the screen.
///
/// Its frames go into the *same* movie as a second video track rather than a
/// separate file, which sidesteps synchronisation entirely: both tracks share
/// one `AVAssetWriter` session, so they line up by construction.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.recut.capture.webcam", qos: .userInitiated)

    private(set) var frameSize: CGSize = .zero

    /// Set while `prepare` is waiting to see what the camera actually sends.
    private var sizeProbe: ((CGSize) -> Void)?
    private let probeLock = NSLock()

    /// Called for every frame while running.
    var onSample: ((CMSampleBuffer) -> Void)?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Wires up the session and reports the frame size.
    ///
    /// Has to happen before the writer is built: `AVAssetWriter` wants every
    /// input added before `startWriting()`, and an input needs its dimensions.
    ///
    /// The size comes from a **real frame**, not from `device.activeFormat`.
    /// `activeFormat` still reports the device's native format after a session
    /// preset is applied, and a virtual camera can deliver something else
    /// entirely — an ultra-wide one mirroring a 3440×1440 desktop, say. When
    /// the declared size doesn't match, `AVAssetWriter` scales every frame into
    /// it, squeezing a wide image into a 16:9 box: the camera came out
    /// stretched vertically.
    @discardableResult
    func prepare(device: AVCaptureDevice) async throws -> CGSize {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecutError.message("Could not use \(device.localizedName).")
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecutError.message("Could not capture from \(device.localizedName).")
        }
        session.addOutput(output)
        session.commitConfiguration()

        let declared = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fallback = CGSize(width: Int(declared.width), height: Int(declared.height))

        frameSize = await measuredFrameSize(timeout: 2.5) ?? fallback
        return frameSize
    }

    /// Starts the camera and waits for one frame, so the writer is told the
    /// size the device really produces.
    private func measuredFrameSize(timeout: TimeInterval) async -> CGSize? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGSize?, Never>) in
            var resumed = false
            let finish: (CGSize?) -> Void = { [weak self] size in
                self?.probeLock.lock()
                defer { self?.probeLock.unlock() }
                guard !resumed else { return }
                resumed = true
                self?.sizeProbe = nil
                continuation.resume(returning: size)
            }

            probeLock.lock()
            sizeProbe = { finish($0) }
            probeLock.unlock()

            queue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
            // A camera that never delivers shouldn't block the recording.
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Starts the camera without recording, so the framing preview can run
    /// while the user is still setting up.
    func startPreview() {
        guard !session.isRunning else { return }
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        onSample = nil
        guard session.isRunning else { return }
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        probeLock.lock()
        let probe = sizeProbe
        probeLock.unlock()

        if let probe, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            probe(CGSize(
                width: CVPixelBufferGetWidth(pixels),
                height: CVPixelBufferGetHeight(pixels)
            ))
        }
        onSample?(sampleBuffer)
    }
}
