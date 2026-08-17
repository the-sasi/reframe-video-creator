import AVFoundation
import CoreVideo
import Foundation
import MediaIO
import RecipeCore
import Vision
import simd

/// Per-shot visual analysis: camera motion, shot scale, and palette.
///
/// All three in one pass over a shot's sampled frames, deliberately. Each would be a separate
/// decode of the same frames otherwise, and decoding is by far the expensive part — three
/// passes would roughly triple the cost of the motion stage for no benefit.
public struct ShotAnalyzer: Sendable {

    /// Frames sampled per shot. Five gives four motion pairs — enough for the trimmed fit to
    /// have something to trim and for `sampleCount` to mean something, without making long
    /// references crawl.
    public static let samplesPerShot = 5
    /// Grid density for flow sampling. 24x24 = 576 correspondences per pair, which is plenty
    /// for a 4-parameter fit and cheap to iterate twice.
    private static let flowGrid = 24

    private let colorAnalyzer = ColorAnalyzer()

    public init() {}

    public struct ShotVisuals: Sendable {
        public var motion: FittedMotion
        public var salientAreaFraction: Double?
        public var palette: ScenePalette
    }

    /// Analyses one shot. Returns nil only if no frames could be extracted at all.
    public func analyze(shot: DetectedShot, source: MediaSource) async -> ShotVisuals? {
        let frames = await sampleFrames(shot: shot, source: source)
        guard !frames.isEmpty else { return nil }

        async let motion = fitMotion(across: frames)
        async let saliency = meanSalientArea(in: frames)
        let palette = palette(from: frames)

        return ShotVisuals(
            motion: await motion,
            salientAreaFraction: await saliency,
            palette: palette
        )
    }

    // MARK: - Frame sampling

    private func sampleFrames(shot: DetectedShot, source: MediaSource) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        // Motion analysis needs the frame we asked for, not a nearby keyframe — tolerance here
        // would silently corrupt every fit.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 480, height: 480)

        let count = Self.samplesPerShot
        // Inset from the shot's edges: the first and last frames of a shot are often mid-
        // transition, and a dissolve frame is a blend of two shots, which fits nothing.
        let inset = min(0.08, shot.duration * 0.12)
        let start = shot.start + inset
        let end = max(start, shot.end - inset)
        let span = end - start

        let times: [CMTime] = (0..<count).map { i in
            let t = count > 1 ? start + span * Double(i) / Double(count - 1) : start
            return CMTime(seconds: t, preferredTimescale: 600)
        }

        var images: [CGImage] = []
        images.reserveCapacity(count)
        for await result in generator.images(for: times) {
            if Task.isCancelled { return images }
            if let image = try? result.image {
                images.append(image)
            }
        }
        return images
    }

    // MARK: - Motion

    /// Fits a similarity transform between each consecutive frame pair, then composes them
    /// into the shot's overall move.
    ///
    /// Composing rather than fitting first-to-last is what makes a continuous pan measurable:
    /// across a whole shot the first and last frames may share almost no content, and optical
    /// flow between them is meaningless. Adjacent frames always overlap.
    private func fitMotion(across frames: [CGImage]) async -> FittedMotion {
        guard frames.count >= 2 else { return .identity }

        var fits: [SimilarityFit] = []
        for i in 0..<(frames.count - 1) {
            if Task.isCancelled { break }
            if let fit = await fitPair(from: frames[i], to: frames[i + 1]) {
                fits.append(fit)
            }
        }
        guard !fits.isEmpty else { return .identity }

        // Compose: scales multiply, rotations and normalised translations add.
        var totalScale = 1.0
        var totalRotation = 0.0
        var totalX = 0.0
        var totalY = 0.0
        var totalResidual = 0.0
        for fit in fits {
            totalScale *= fit.scale
            totalRotation += fit.rotation
            totalX += fit.translationX
            totalY += fit.translationY
            totalResidual += fit.residual
        }

        return FittedMotion(
            scale: totalScale,
            translationX: totalX,
            translationY: totalY,
            rotationRadians: totalRotation,
            residual: totalResidual / Double(fits.count),
            sampleCount: fits.count
        )
    }

    /// Optical flow between two frames, reduced to a similarity transform.
    ///
    /// Falls back to `VNTranslationalImageRegistrationRequest` when flow is unavailable — that
    /// recovers pan but not zoom, so the fallback is reported with a residual that keeps its
    /// confidence low rather than pretending a zoom of 1.0 was measured.
    private func fitPair(from a: CGImage, to b: CGImage) async -> SimilarityFit? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: b, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float

        let handler = VNImageRequestHandler(cgImage: a, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return translationalFallback(from: a, to: b)
        }

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            return translationalFallback(from: a, to: b)
        }
        return fitFlowField(observation.pixelBuffer)
    }

    /// Samples the flow field on a grid and fits.
    ///
    /// Correspondences are normalised by frame width so `translationX` is in frame widths, not
    /// pixels — which makes the recipe resolution-independent, and lets a move measured on a
    /// 480 px analysis frame drive a 1080 px render.
    private func fitFlowField(_ buffer: CVPixelBuffer) -> SimilarityFit? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 2, height > 2 else { return nil }

        var source: [SIMD2<Double>] = []
        var target: [SIMD2<Double>] = []
        source.reserveCapacity(Self.flowGrid * Self.flowGrid)
        target.reserveCapacity(Self.flowGrid * Self.flowGrid)

        let scale = 1.0 / Double(width)

        for gy in 0..<Self.flowGrid {
            // Skip a margin: flow at the frame edge has nowhere to come from and is unreliable.
            let y = Int(Double(height) * (0.1 + 0.8 * Double(gy) / Double(Self.flowGrid - 1)))
            guard y >= 0, y < height else { continue }
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)

            for gx in 0..<Self.flowGrid {
                let x = Int(Double(width) * (0.1 + 0.8 * Double(gx) / Double(Self.flowGrid - 1)))
                guard x >= 0, x < width else { continue }

                let dx = Double(row[x * 2])
                let dy = Double(row[x * 2 + 1])
                guard dx.isFinite, dy.isFinite else { continue }
                // A flow vector longer than a third of the frame is a tracking failure, not a
                // camera move. Including them makes the trimmed fit work harder for nothing.
                guard abs(dx) < Double(width) / 3, abs(dy) < Double(height) / 3 else { continue }

                let p = SIMD2<Double>(Double(x) * scale, Double(y) * scale)
                source.append(p)
                target.append(SIMD2<Double>(p.x + dx * scale, p.y + dy * scale))
            }
        }

        guard source.count >= 8 else { return nil }
        return SimilarityFit.fit(source: source, target: target)
    }

    private func translationalFallback(from a: CGImage, to b: CGImage) -> SimilarityFit? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: b, options: [:])
        let handler = VNImageRequestHandler(cgImage: a, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return nil }

        let transform = observation.alignmentTransform
        let width = Double(a.width)
        guard width > 0 else { return nil }

        return SimilarityFit(
            scale: 1,
            rotation: 0,
            translationX: Double(transform.tx) / width,
            translationY: Double(transform.ty) / width,
            // Deliberately non-zero: this method cannot see zoom, and reporting a perfect fit
            // would let a missed zoom masquerade as a confident "no zoom".
            residual: 0.05,
            pointCount: 3
        )
    }

    // MARK: - Saliency

    /// Mean fraction of frame area occupied by salient regions, across sampled frames.
    /// Feeds `ShotFraming(salientAreaFraction:)` — this is how "close-up vs wide" is decided.
    private func meanSalientArea(in frames: [CGImage]) async -> Double? {
        var fractions: [Double] = []

        for frame in frames {
            if Task.isCancelled { break }
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: frame, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first as? VNSaliencyImageObservation,
                  let objects = observation.salientObjects, !objects.isEmpty
            else { continue }

            // Union rather than sum: overlapping salient boxes would otherwise total more than
            // the frame and report every shot as a close-up.
            var union: NormalizedRect?
            for object in objects {
                let box = object.boundingBox
                let rect = NormalizedRect.fromVision(
                    x: box.origin.x, y: box.origin.y,
                    width: box.size.width, height: box.size.height
                )
                union = union.map { $0.union(rect) } ?? rect
            }
            if let union {
                fractions.append(min(1, union.area))
            }
        }

        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    // MARK: - Palette

    private func palette(from frames: [CGImage]) -> ScenePalette {
        // Middle frame only: shot palette is stable enough that sampling five frames costs
        // five times as much for a result that differs in the third decimal place.
        guard let middle = frames.count > 0 ? frames[frames.count / 2] : nil else {
            return ScenePalette(dominant: [], brightness: 0.5, saturation: 0.5, contrast: 1)
        }
        return colorAnalyzer.palette(from: colorAnalyzer.sample(image: middle, maxSamples: 1200))
    }
}
