import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import MediaIO
import RecipeCore
import Vision

// `RecipeCore.NormalizedRect` is spelled out in full throughout this file. Vision's Swift-only
// API (iOS 18+) declares its own `NormalizedRect`, so the bare name is ambiguous in any file
// that imports both. Qualifying is noisier than a typealias but says plainly which one is meant.

/// Runs the Vision requests that describe a user asset and packs them into the persistable
/// `RecipeCore.AssetFeatures`.
///
/// Everything here comes from Vision requests that are already on the device — no downloaded
/// model, no licence question, no app-size cost. See docs/03-ai-models.md for why this
/// deliberately stops short of object detection. The feature print is stored as raw floats so
/// the result can live in the project file and never has to be recomputed for a photo that
/// has not changed.
public struct AssetFeatureExtractor: Sendable {

    /// Analysis resolution. Vision does not need more than this to answer "where is the subject
    /// and is this a good photo", and decoding a 48 MP image to full size to ask would be
    /// gratuitous.
    private static let analysisDimension = 768

    private let resolver: AssetResolver

    public init(resolver: AssetResolver) {
        self.resolver = resolver
    }

    public func extract(
        from pool: AssetPool,
        skipping existing: Set<UUID> = [],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [UUID: AssetFeatures] {
        var results: [UUID: AssetFeatures] = [:]
        let visuals = pool.visuals.filter { !existing.contains($0.id) }

        for (index, reference) in visuals.enumerated() {
            if Task.isCancelled { break }
            if let features = await extract(from: reference) {
                results[reference.id] = features
            }
            progress?(index + 1, visuals.count)
        }
        return results
    }

    public func extract(from reference: AssetReference) async -> AssetFeatures? {
        guard let resolved = await resolver.resolve(reference, maxDimension: Self.analysisDimension)
        else { return nil }

        // For video, analyse a frame from ~1s in. The very first frame of user footage is
        // routinely the worst one — mid-autofocus, mid-motion.
        let image: CGImage?
        if let still = resolved.image {
            image = still
        } else if let asset = resolved.asset {
            image = await Self.representativeFrame(of: asset)
        } else {
            image = nil
        }

        guard let image else {
            return AssetFeatures(
                assetID: reference.id,
                orientation: reference.orientation,
                aspectRatio: reference.aspectRatio,
                isVideo: reference.kind == .video,
                duration: reference.duration
            )
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()

        // One handler, four requests — Vision shares the decoded image across them, so this is
        // meaningfully cheaper than separate performs.
        try? handler.perform([saliencyRequest, aestheticsRequest, featurePrintRequest, faceRequest])

        var salientRect: RecipeCore.NormalizedRect?
        if let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
           let objects = observation.salientObjects, !objects.isEmpty {
            var union: RecipeCore.NormalizedRect?
            for object in objects {
                let box = object.boundingBox
                let rect = RecipeCore.NormalizedRect.fromVision(
                    x: box.origin.x, y: box.origin.y,
                    width: box.size.width, height: box.size.height
                )
                union = union.map { $0.union(rect) } ?? rect
            }
            salientRect = union
        }

        // Faces refine the subject: if saliency found nothing but a face is there, the face is
        // the subject; if both exist, the union keeps heads inside any crop.
        let faces = (faceRequest.results ?? []).map { face in
            RecipeCore.NormalizedRect.fromVision(
                x: face.boundingBox.origin.x, y: face.boundingBox.origin.y,
                width: face.boundingBox.size.width, height: face.boundingBox.size.height
            )
        }
        if !faces.isEmpty {
            let faceUnion = faces.dropFirst().reduce(faces[0]) { $0.union($1) }
            // Pad the face box a little so a crop anchored on it does not clip the hair.
            let padded = faceUnion.scaled(by: 1.4).clampedInsideUnitSquare()
            salientRect = salientRect.map { $0.union(padded) } ?? padded
        }

        let aesthetics = aestheticsRequest.results?.first as? VNImageAestheticsScoresObservation
        let featurePrint = (featurePrintRequest.results?.first as? VNFeaturePrintObservation)
            .flatMap(Self.floats(from:))

        let stats = Self.lumaStatistics(of: image)

        return AssetFeatures(
            assetID: reference.id,
            salientAreaFraction: salientRect.map { min(1, $0.area) },
            salientRect: salientRect,
            aestheticScore: aesthetics.map { Double($0.overallScore) },
            isUtility: aesthetics?.isUtility ?? false,
            orientation: reference.orientation,
            aspectRatio: reference.aspectRatio,
            brightness: stats.brightness,
            sharpness: stats.sharpness,
            faceCount: faces.count,
            isVideo: reference.kind == .video,
            duration: reference.duration,
            featurePrint: featurePrint
        )
    }

    private static func representativeFrame(of asset: AVAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: analysisDimension, height: analysisDimension)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: min(1.0, duration * 0.25), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    /// The feature print's raw vector. `VNFeaturePrintObservation.data` is a packed array of
    /// `elementType`; on every OS this app supports that is `Float`.
    private static func floats(from observation: VNFeaturePrintObservation) -> [Float]? {
        guard observation.elementType == .float, observation.elementCount > 0 else { return nil }
        let count = observation.elementCount
        return observation.data.withUnsafeBytes { raw -> [Float]? in
            guard raw.count >= count * MemoryLayout<Float>.size else { return nil }
            return Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    /// Mean luma and a sharpness estimate from a 96 px greyscale thumbnail.
    ///
    /// Sharpness is the variance of a 3×3 Laplacian, normalised into 0…1 with a soft knee. It
    /// separates "in focus" from "soft or motion-blurred" reliably enough to rank two similar
    /// photos, which is all the mapper asks of it.
    private static func lumaStatistics(of image: CGImage) -> (brightness: Double, sharpness: Double) {
        let width = min(96, image.width)
        let height = min(96, image.height)
        guard width > 2, height > 2 else { return (0.5, 0.5) }

        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0.5, 0.5) }

        var sum = 0.0
        var laplacianSum = 0.0
        var laplacianSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let c = Double(buffer[i])
                sum += c
                let lap = 4 * c
                    - Double(buffer[i - 1]) - Double(buffer[i + 1])
                    - Double(buffer[i - width]) - Double(buffer[i + width])
                laplacianSum += lap
                laplacianSquares += lap * lap
                count += 1
            }
        }
        guard count > 0 else { return (0.5, 0.5) }
        let brightness = sum / (count * 255)
        let mean = laplacianSum / count
        let variance = laplacianSquares / count - mean * mean
        // Empirically ~40 for soft photos, ~400+ for crisp ones at this thumbnail size.
        let sharpness = min(1, max(0, log10(max(variance, 1)) / 3.0))
        return (brightness, sharpness)
    }
}
