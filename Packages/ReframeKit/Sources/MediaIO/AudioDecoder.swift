import Accelerate
import AVFoundation
import Foundation
import RecipeCore

/// Mono PCM at a fixed analysis rate.
///
/// 22.05 kHz is deliberate: it halves the FFT work versus 44.1 kHz while retaining everything
/// up to ~11 kHz, and onset detection cares about the low and mid bands where percussive energy
/// lives. Nothing above 11 kHz contributes to a beat grid.
public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public var duration: Double { Double(samples.count) / sampleRate }

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum AudioDecoder {

    public static let analysisSampleRate: Double = 22_050

    /// Decodes an asset's audio track to mono float samples.
    ///
    /// Returns nil when there is no audio track — a silent reference is a normal case, not an
    /// error, and the recipe simply carries no beat grid.
    public static func decodeMono(
        asset: AVAsset,
        sampleRate: Double = analysisSampleRate,
        maxDuration: Double? = nil
    ) async throws -> DecodedAudio? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ReframeError.corruptMedia(detail: error.localizedDescription)
        }

        if let maxDuration {
            reader.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: maxDuration, preferredTimescale: 600)
            )
        }

        // Ask AVFoundation for exactly what we want — mono, float, deinterleaved, at the
        // analysis rate — so no resampling or channel mixing has to happen in our code.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ReframeError.unsupportedFormat(detail: "audio track rejected PCM output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ReframeError.corruptMedia(
                detail: reader.error?.localizedDescription ?? "audio startReading failed"
            )
        }
        defer { reader.cancelReading() }

        var samples = [Float]()
        // Pre-size to the expected length; audio is small enough to hold entirely and the
        // tempo estimator needs random access over the whole onset envelope.
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
            samples.reserveCapacity(Int(duration * sampleRate))
        }

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { throw ReframeError.analysisCancelled }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { pointer in
                samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: floatCount))
            }
        }

        guard !samples.isEmpty else { return nil }
        return DecodedAudio(samples: samples, sampleRate: sampleRate)
    }

    /// Peak-normalises in place. Onset detection thresholds are relative, but normalising means
    /// a quiet reference and a loud one produce the same envelope shape and therefore the same
    /// beat grid — which is part of the determinism promise.
    public static func normalized(_ audio: DecodedAudio) -> DecodedAudio {
        var peak: Float = 0
        vDSP_maxmgv(audio.samples, 1, &peak, vDSP_Length(audio.samples.count))
        guard peak > 1e-6 else { return audio }

        var scale = 1.0 / peak
        var output = [Float](repeating: 0, count: audio.samples.count)
        vDSP_vsmul(audio.samples, 1, &scale, &output, 1, vDSP_Length(audio.samples.count))
        return DecodedAudio(samples: output, sampleRate: audio.sampleRate)
    }
}
