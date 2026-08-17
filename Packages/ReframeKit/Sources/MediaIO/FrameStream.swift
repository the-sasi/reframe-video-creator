import Accelerate
import AVFoundation
import CoreVideo
import Foundation
import RecipeCore

/// One decoded frame, downscaled for analysis.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is a CoreFoundation type without a Sendable
/// conformance. The safety argument: each frame's buffer is produced by exactly one reader,
/// handed to exactly one consumer, and never mutated after construction. The retained
/// `CMSampleBuffer` keeps the pixel buffer alive past the reader's recycling.
public struct AnalysisFrame: @unchecked Sendable {
    public let index: Int
    public let time: Double
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int
    /// Retained solely to keep `pixelBuffer` valid.
    private let sampleBuffer: CMSampleBuffer

    init(index: Int, time: Double, sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
        self.index = index
        self.time = time
        self.sampleBuffer = sampleBuffer
        self.pixelBuffer = pixelBuffer
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
    }
}

/// Streams decoded, downscaled frames from a video track.
///
/// Frames stream; they do not accumulate. A 60 s reference costs one frame of resident memory,
/// not 1,800 — which is the difference between analysing 4K comfortably and being jetsammed.
public struct FrameStream: Sendable {

    public struct Configuration: Sendable {
        /// Longest edge, in pixels, after downscale. 256 is enough for content-difference
        /// scene detection and cheap enough to run several times faster than realtime.
        public var maxDimension: Int
        /// Decode every Nth frame. 1 for scene detection (a cut between skipped frames is a
        /// missed cut); higher for OCR and colour, where temporal resolution is not the point.
        public var frameStride: Int
        /// Restrict to a sub-range. Used to sample within one scene.
        public var timeRange: ClosedRange<Double>?

        public init(maxDimension: Int = 256, frameStride: Int = 1, timeRange: ClosedRange<Double>? = nil) {
            self.maxDimension = maxDimension
            self.frameStride = max(1, frameStride)
            self.timeRange = timeRange
        }

        /// Full temporal resolution, small frames. Cuts are single-frame events.
        public static let sceneDetection = Configuration(maxDimension: 256, frameStride: 1)
        /// Vision text recognition wants resolution and does not need every frame.
        public static let textRecognition = Configuration(maxDimension: 720, frameStride: 8)
        /// Optical flow: enough resolution to fit a transform, few enough frames to be quick.
        public static let motion = Configuration(maxDimension: 480, frameStride: 1)
    }

    private let source: MediaSource
    private let configuration: Configuration

    public init(source: MediaSource, configuration: Configuration = .sceneDetection) {
        self.source = source
        self.configuration = configuration
    }

    /// Approximate number of frames this stream will yield. Used for real progress reporting —
    /// the analysis screen only shows a determinate bar where the denominator is genuinely known.
    public var estimatedFrameCount: Int {
        let duration = configuration.timeRange.map { $0.upperBound - $0.lowerBound }
            ?? source.info.duration
        return max(1, Int(duration * source.info.fps) / configuration.frameStride)
    }

    public func frames() -> AsyncThrowingStream<AnalysisFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await produce(into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func produce(into continuation: AsyncThrowingStream<AnalysisFrame, Error>.Continuation) async throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw ReframeError.corruptMedia(detail: error.localizedDescription)
        }

        if let range = configuration.timeRange {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 600)
            )
        }

        // Scale during decode rather than after. VideoToolbox does this on the way out of the
        // decoder, so a 4K source never exists as a full-resolution CPU buffer.
        let (targetWidth, targetHeight) = scaledSize()
        let output = AVAssetReaderTrackOutput(
            track: source.videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ReframeError.unsupportedFormat(detail: "reader rejected BGRA output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ReframeError.corruptMedia(detail: reader.error?.localizedDescription ?? "startReading failed")
        }
        defer { reader.cancelReading() }

        var decodedIndex = 0
        var emittedIndex = 0

        while let sample = output.copyNextSampleBuffer() {
            // Cooperative cancellation checked every frame, so closing the analysis screen
            // actually stops the work rather than orphaning it.
            if Task.isCancelled {
                throw ReframeError.analysisCancelled
            }

            defer { decodedIndex += 1 }
            guard decodedIndex % configuration.frameStride == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            continuation.yield(
                AnalysisFrame(
                    index: emittedIndex,
                    time: time.isFinite ? time : Double(emittedIndex) / source.info.fps,
                    sampleBuffer: sample,
                    pixelBuffer: pixelBuffer
                )
            )
            emittedIndex += 1
        }

        if reader.status == .failed {
            throw ReframeError.corruptMedia(
                detail: reader.error?.localizedDescription ?? "read failed"
            )
        }
    }

    /// Preserves aspect ratio, and forces even dimensions — odd widths break some pixel-format
    /// conversions and produce a diagonal-shear artefact that is baffling to debug.
    private func scaledSize() -> (Int, Int) {
        let w = Double(source.info.width)
        let h = Double(source.info.height)
        guard w > 0, h > 0 else { return (configuration.maxDimension, configuration.maxDimension) }

        let scale = min(1.0, Double(configuration.maxDimension) / max(w, h))
        let sw = max(2, Int((w * scale).rounded()))
        let sh = max(2, Int((h * scale).rounded()))
        return (sw - sw % 2, sh - sh % 2)
    }
}
