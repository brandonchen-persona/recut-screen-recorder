import Foundation
import AVFoundation
import CoreMedia

/// A peak envelope of a recording's audio, in source time.
///
/// Stored per project so the clip lane can show where the talking is: the
/// commonest edit on a demo take is cutting the silence at the front and the
/// "…did that work?" at the end, and both are obvious from the shape.
struct Waveform: Codable, Equatable {
    /// Buckets per second of source time.
    var rate: Double
    /// Peak amplitude per bucket, 0...1.
    var peaks: [Float]

    var duration: Double { rate > 0 ? Double(peaks.count) / rate : 0 }

    static let empty = Waveform(rate: 0, peaks: [])
    var isEmpty: Bool { peaks.isEmpty }

    /// Peak at a source time, or 0 outside the recording.
    func peak(at seconds: Double) -> Double {
        guard rate > 0, !peaks.isEmpty else { return 0 }
        let index = Int(seconds * rate)
        guard index >= 0, index < peaks.count else { return 0 }
        return Double(peaks[index])
    }

    /// The loudest bucket in a span, which is what a single pixel column of a
    /// zoomed-out timeline should show — averaging washes speech out to a
    /// flat smear at anything below one bucket per pixel.
    func peak(from start: Double, to end: Double) -> Double {
        guard rate > 0, !peaks.isEmpty, end > start else { return peak(at: start) }
        // Half-open: a column ends where the next one begins, so a bucket
        // landing exactly on the boundary belongs to the next column only.
        let first = max(0, Int(start * rate))
        let last = min(peaks.count - 1, Int((end * rate).rounded(.up)) - 1)
        guard first <= last else { return 0 }
        var best: Float = 0
        for i in first...last where peaks[i] > best { best = peaks[i] }
        return Double(best)
    }
}

enum WaveformExtractor {

    /// Reads the audio track and reduces it to `rate` peaks per second.
    ///
    /// Decodes to 16-bit mono at a low sample rate: the envelope only needs
    /// enough resolution to draw, and asking the decoder for less means less
    /// work per project open.
    static func extract(from url: URL, rate: Double = 60) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return .empty
        }

        let sampleRate = 8_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .empty }
        reader.add(output)
        guard reader.startReading() else { return .empty }

        let perBucket = max(1, Int(sampleRate / max(1, rate)))
        var peaks: [Float] = []
        var runningPeak: Int16 = 0
        var counted = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }

            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    // magnitude(of:) rather than abs: Int16.min has no positive
                    // counterpart and abs would trap on it.
                    let magnitude = samples[i] == Int16.min
                        ? Int16.max
                        : (samples[i] < 0 ? -samples[i] : samples[i])
                    if magnitude > runningPeak { runningPeak = magnitude }
                    counted += 1
                    if counted == perBucket {
                        peaks.append(Float(runningPeak) / Float(Int16.max))
                        runningPeak = 0
                        counted = 0
                    }
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        if counted > 0 { peaks.append(Float(runningPeak) / Float(Int16.max)) }

        guard reader.status != .failed else {
            throw reader.error ?? RecutError.message("Could not read the audio.")
        }
        return Waveform(rate: sampleRate / Double(perBucket), peaks: peaks)
    }

    // MARK: - Caching

    /// Cached beside the recording. Extraction is a few hundred milliseconds on
    /// a long take — fine once, irritating on every open.
    static func cacheURL(for project: Project) -> URL {
        project.url.appendingPathComponent("waveform.json")
    }

    static func load(for project: Project) -> Waveform? {
        guard let data = try? Data(contentsOf: cacheURL(for: project)) else { return nil }
        return try? JSONDecoder().decode(Waveform.self, from: data)
    }

    static func save(_ waveform: Waveform, for project: Project) {
        guard let data = try? JSONEncoder().encode(waveform) else { return }
        try? data.write(to: cacheURL(for: project), options: .atomic)
    }
}
