import AVFoundation
import CoreGraphics
import Foundation
import MediaIO
import RecipeCore
import Vision

/// What we know about one of the user's photos.
///
/// Everything here comes from Vision requests that are already on the device — no downloaded
/// model, no licence question, no app-size cost. See docs/03-ai-models.md for why this
/// deliberately stops short of object detection.
public struct AssetFeatures: Sendable, Hashable {
    public var assetID: UUID
    /// Fraction of frame occupied by the salient region. Drives shot-scale matching.
    public var salientAreaFraction: Double?
    /// Where the subject is, for subject-aware cropping.
    public var salientRect: NormalizedRect?
    /// `VNCalculateImageAestheticsScoresRequest.overallScore`, roughly -1...1.
    public var aestheticScore: Double?
    /// Screenshots, receipts, documents. A built-in classifier we get for free, and the single
    /// most useful signal for keeping junk out of an auto-arranged reel.
    public var isUtility: Bool
    public var orientation: AssetOrientation
    public var aspectRatio: Double
    public var brightness: Double
    public var isVideo: Bool
    public var duration: Double
    /// Vision feature print, for near-duplicate detection between assets.
    public var featurePrint: FeaturePrintBox?

    public var framing: ShotFraming? {
        salientAreaFraction.map(ShotFraming.init(salientAreaFraction:))
    }

    public init(
        assetID: UUID,
        salientAreaFraction: Double? = nil,
        salientRect: NormalizedRect? = nil,
        aestheticScore: Double? = nil,
        isUtility: Bool = false,
        orientation: AssetOrientation = .portrait,
        aspectRatio: Double = 1,
        brightness: Double = 0.5,
        isVideo: Bool = false,
        duration: Double = 0,
        featurePrint: FeaturePrintBox? = nil
    ) {
        self.assetID = assetID
        self.salientAreaFraction = salientAreaFraction
        self.salientRect = salientRect
        self.aestheticScore = aestheticScore
        self.isUtility = isUtility
        self.orientation = orientation
        self.aspectRatio = aspectRatio
        self.brightness = brightness
        self.isVideo = isVideo
        self.duration = duration
        self.featurePrint = featurePrint
    }
}

/// Wraps `VNFeaturePrintObservation` so `AssetFeatures` can stay `Hashable` and `Sendable`.
///
/// The observation is immutable after creation and only ever read via `computeDistance`, which
/// is what makes the `@unchecked` sound.
public struct FeaturePrintBox: @unchecked Sendable, Hashable {
    public let observation: VNFeaturePrintObservation

    public init(_ observation: VNFeaturePrintObservation) {
        self.observation = observation
    }

    public static func == (lhs: FeaturePrintBox, rhs: FeaturePrintBox) -> Bool {
        lhs.observation === rhs.observation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(observation))
    }

    /// Euclidean distance between prints. Smaller is more similar; identical images give 0.
    public func distance(to other: FeaturePrintBox) -> Double? {
        var distance = Float(0)
        guard (try? observation.computeDistance(&distance, to: other.observation)) != nil else {
            return nil
        }
        return Double(distance)
    }
}

/// Runs the Vision requests that describe a user asset.
public struct AssetFeatureExtractor: Sendable {

    /// Analysis resolution. Vision does not need more than this to answer "where is the subject
    /// and is this a good photo", and decoding a 48 MP image to full size to ask would be
    /// gratuitous.
    private static let analysisDimension = 768

    private let resolver: AssetResolver
    private let colorAnalyzer = ColorAnalyzerBridge()

    public init(resolver: AssetResolver) {
        self.resolver = resolver
    }

    public func extract(
        from pool: AssetPool,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [UUID: AssetFeatures] {
        var results: [UUID: AssetFeatures] = [:]
        let visuals = pool.visuals

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

        // One handler, three requests — Vision shares the decoded image across them, so this is
        // meaningfully cheaper than three separate performs.
        try? handler.perform([saliencyRequest, aestheticsRequest, featurePrintRequest])

        var salientRect: NormalizedRect?
        if let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
           let objects = observation.salientObjects, !objects.isEmpty {
            var union: NormalizedRect?
            for object in objects {
                let box = object.boundingBox
                let rect = NormalizedRect.fromVision(
                    x: box.origin.x, y: box.origin.y,
                    width: box.size.width, height: box.size.height
                )
                union = union.map { $0.union(rect) } ?? rect
            }
            salientRect = union
        }

        let aesthetics = aestheticsRequest.results?.first as? VNImageAestheticsScoresObservation
        let featurePrint = (featurePrintRequest.results?.first as? VNFeaturePrintObservation)
            .map(FeaturePrintBox.init)

        return AssetFeatures(
            assetID: reference.id,
            salientAreaFraction: salientRect.map { min(1, $0.area) },
            salientRect: salientRect,
            aestheticScore: aesthetics.map { Double($0.overallScore) },
            isUtility: aesthetics?.isUtility ?? false,
            orientation: reference.orientation,
            aspectRatio: reference.aspectRatio,
            brightness: colorAnalyzer.meanBrightness(of: image),
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
}

/// Small bridge so `Mapping` can measure brightness without depending on `Analysis`.
/// Duplicating twenty lines is cheaper than a module dependency that would let asset scoring
/// reach into reference analysis.
struct ColorAnalyzerBridge: Sendable {
    func meanBrightness(of image: CGImage) -> Double {
        let width = min(64, image.width)
        let height = min(64, image.height)
        guard width > 0, height > 0 else { return 0.5 }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0.5 }

        var total = 0.0
        for i in Swift.stride(from: 0, to: buffer.count, by: 4) {
            total += 0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1])
                + 0.0722 * Double(buffer[i + 2])
        }
        return total / (Double(width * height) * 255)
    }
}
