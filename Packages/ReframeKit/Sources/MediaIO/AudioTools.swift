import Accelerate
import AVFoundation
import Foundation
import RecipeCore

/// Pulls the soundtrack out of a video into a standalone M4A.
///
/// Used for "keep the reference's audio" and "extract to Files". Nothing here runs unless the
/// user asks for it explicitly; the analysis pipeline still never touches the reference's audio
/// beyond the numbers it measures. The user is responsible for having the rights to whatever
/// they extract — the app says so where the option is offered.
public enum AudioExtractor {

    /// Extracts to `Documents/ImportedMedia/`. Returns the sandbox-relative path and duration.
    public static func extract(from videoURL: URL, displayName: String) async throws -> (relativePath: String, duration: Double) {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw ReframeError.audioExtractionFailed(detail: "no audio track")
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration > 0.1 else {
            throw ReframeError.audioExtractionFailed(detail: "empty audio")
        }

        // Audio-only composition so the export session never has to look at the video.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ReframeError.audioExtractionFailed(detail: "could not create composition track")
        }
        do {
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)),
                of: audioTrack, at: .zero
            )
        } catch {
            throw ReframeError.audioExtractionFailed(detail: error.localizedDescription)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ReframeError.audioExtractionFailed(detail: "no M4A export preset")
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/extracted-\(UUID().uuidString).m4a"
        let destination = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw ReframeError.audioExtractionFailed(detail: error.localizedDescription)
        }

        DiagnosticsLog.shared.info(
            "audio", "extracted \(displayName): \(String(format: "%.1fs", duration)) -> \(relative)"
        )
        return (relative, duration)
    }
}

/// Peak/RMS envelope of an audio file, downsampled to a fixed number of bins for drawing.
///
/// A few hundred floats per track — cached alongside the project so a waveform is decoded once,
/// not every time the audio lane scrolls into view.
public struct Waveform: Codable, Sendable, Hashable {
    /// 0…1 per bin, left to right across the whole file.
    public var bins: [Float]
    public var duration: Double

    public init(bins: [Float], duration: Double) {
        self.bins = bins
        self.duration = duration
    }

    /// Bins covering `[start, start + length]` seconds, resampled to `count` values.
    public func slice(start: Double, length: Double, count: Int) -> [Float] {
        guard !bins.isEmpty, duration > 0, count > 0, length > 0 else { return [] }
        let perSecond = Double(bins.count) / duration
        return (0..<count).map { i in
            let t = start + length * Double(i) / Double(count)
            let index = Int(t * perSecond)
            return index >= 0 && index < bins.count ? bins[index] : 0
        }
    }
}

public enum WaveformSampler {

    /// Decodes to mono and folds into `binCount` RMS values, peak-normalised so a quiet track
    /// still draws as a readable shape.
    public static func sample(asset: AVAsset, binCount: Int = 600) async throws -> Waveform? {
        guard let decoded = try await AudioDecoder.decodeMono(asset: asset, sampleRate: 11_025) else {
            return nil
        }
        let samples = decoded.samples
        guard samples.count > binCount else {
            return Waveform(bins: samples.map { min(1, abs($0)) }, duration: decoded.duration)
        }
        let window = samples.count / binCount
        var bins = [Float](repeating: 0, count: binCount)
        samples.withUnsafeBufferPointer { pointer in
            for i in 0..<binCount {
                var rms: Float = 0
                vDSP_rmsqv(pointer.baseAddress! + i * window, 1, &rms, vDSP_Length(window))
                bins[i] = rms
            }
        }
        var peak: Float = 0
        vDSP_maxv(bins, 1, &peak, vDSP_Length(binCount))
        if peak > 1e-5 {
            var scale = 1 / peak
            vDSP_vsmul(bins, 1, &scale, &bins, 1, vDSP_Length(binCount))
        }
        return Waveform(bins: bins, duration: decoded.duration)
    }
}
