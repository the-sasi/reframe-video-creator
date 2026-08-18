import Foundation

/// A reference to one of the user's assets. **Never a copy.**
///
/// A 20-photo project costs kilobytes because this is all that is persisted: an identifier, a
/// few measurements, and — for files outside Photos — a security-scoped bookmark. Resolution
/// to actual pixels happens in `MediaIO`, which is why this type has no AVFoundation import.
public struct AssetReference: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: AssetKind
    public var origin: AssetOrigin
    /// For display and for the "a photo is missing" error. Not used for resolution.
    public var displayName: String
    /// Source pixel dimensions, cached so the scorer and planner do not have to load the asset.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Seconds, for video and audio. Zero for stills.
    public var duration: Double
    public var creationDate: Date?

    public init(
        id: UUID = UUID(),
        kind: AssetKind,
        origin: AssetOrigin,
        displayName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double = 0,
        creationDate: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.displayName = displayName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.creationDate = creationDate
    }

    public var aspectRatio: Double {
        pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1
    }

    public var orientation: AssetOrientation {
        switch aspectRatio {
        case ..<0.9: return .portrait
        case 0.9...1.1: return .square
        default: return .landscape
        }
    }
}

public enum AssetKind: String, Codable, Sendable, Hashable {
    case image
    case video
    case audio
}

public enum AssetOrientation: String, Codable, Sendable, Hashable {
    case portrait, square, landscape
}

/// Where the bytes live. Both cases are references; neither is a copy.
public enum AssetOrigin: Codable, Sendable, Hashable {
    /// `PHAsset.localIdentifier`.
    case photoLibrary(localIdentifier: String)
    /// Security-scoped bookmark data for a file outside the sandbox.
    case fileBookmark(Data)
    /// A file we created inside the sandbox (a recording, a proxy). Path relative to Documents.
    case sandboxRelativePath(String)
}

/// Everything the user brought to a project.
public struct AssetPool: Codable, Sendable, Hashable {
    public var assets: [AssetReference]

    public init(assets: [AssetReference] = []) {
        self.assets = assets
    }

    public subscript(id: UUID) -> AssetReference? {
        assets.first { $0.id == id }
    }

    public var images: [AssetReference] { assets.filter { $0.kind == .image } }
    public var videos: [AssetReference] { assets.filter { $0.kind == .video } }
    public var audioTracks: [AssetReference] { assets.filter { $0.kind == .audio } }
    /// What can fill a visual slot.
    public var visuals: [AssetReference] { assets.filter { $0.kind == .image || $0.kind == .video } }

    public mutating func add(_ asset: AssetReference) {
        guard !assets.contains(where: { $0.origin == asset.origin }) else { return }
        assets.append(asset)
    }

    public mutating func remove(id: UUID) {
        assets.removeAll { $0.id == id }
    }
}

/// The user's words. Kept separate from the pool because text is not an asset and does not
/// want the same lifecycle.
public struct UserContent: Codable, Sendable, Hashable {
    /// Keyed by `TextSlotTemplate.id`.
    public var textBySlot: [String: String]
    public var logoAssetID: UUID?
    public var musicAssetID: UUID?
    public var voiceoverAssetID: UUID?
    /// The reference video's own soundtrack, extracted at the user's request. Nil unless they
    /// explicitly chose "Keep reference audio" — nothing is extracted by default.
    public var referenceAudioAssetID: UUID?
    /// Volume for the user's own video clips' sound, 0…1. Zero (the default) keeps the music
    /// bed clean; the editor can raise individual clips afterwards.
    public var clipAudioVolume: Double

    public init(
        textBySlot: [String: String] = [:],
        logoAssetID: UUID? = nil,
        musicAssetID: UUID? = nil,
        voiceoverAssetID: UUID? = nil,
        referenceAudioAssetID: UUID? = nil,
        clipAudioVolume: Double = 0
    ) {
        self.textBySlot = textBySlot
        self.logoAssetID = logoAssetID
        self.musicAssetID = musicAssetID
        self.voiceoverAssetID = voiceoverAssetID
        self.referenceAudioAssetID = referenceAudioAssetID
        self.clipAudioVolume = clipAudioVolume
    }

    private enum CodingKeys: String, CodingKey {
        case textBySlot, logoAssetID, musicAssetID, voiceoverAssetID
        case referenceAudioAssetID, clipAudioVolume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textBySlot = try c.decodeIfPresent([String: String].self, forKey: .textBySlot) ?? [:]
        logoAssetID = try c.decodeIfPresent(UUID.self, forKey: .logoAssetID)
        musicAssetID = try c.decodeIfPresent(UUID.self, forKey: .musicAssetID)
        voiceoverAssetID = try c.decodeIfPresent(UUID.self, forKey: .voiceoverAssetID)
        referenceAudioAssetID = try c.decodeIfPresent(UUID.self, forKey: .referenceAudioAssetID)
        clipAudioVolume = try c.decodeIfPresent(Double.self, forKey: .clipAudioVolume) ?? 0
    }

    public func text(for slotID: String) -> String? {
        guard let value = textBySlot[slotID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Which asset fills which slot. The output of `AssetMapper`, and the thing the mapping screen
/// lets the user override one tap at a time.
public struct AssetAssignment: Codable, Sendable, Hashable {
    /// Keyed by `AssetSlot.id`.
    public var assetBySlot: [String: UUID]
    /// Why each assignment was made, for the "tight crop, high quality" caption.
    public var reasonBySlot: [String: String]
    /// Slots the user has pinned. Auto Arrange and Shuffle leave these exactly as they are and
    /// solve around them — a manual choice must never be silently undone by the solver.
    public var lockedSlots: Set<String>

    public init(
        assetBySlot: [String: UUID] = [:],
        reasonBySlot: [String: String] = [:],
        lockedSlots: Set<String> = []
    ) {
        self.assetBySlot = assetBySlot
        self.reasonBySlot = reasonBySlot
        self.lockedSlots = lockedSlots
    }

    private enum CodingKeys: String, CodingKey { case assetBySlot, reasonBySlot, lockedSlots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetBySlot = try c.decodeIfPresent([String: UUID].self, forKey: .assetBySlot) ?? [:]
        reasonBySlot = try c.decodeIfPresent([String: String].self, forKey: .reasonBySlot) ?? [:]
        lockedSlots = try c.decodeIfPresent(Set<String>.self, forKey: .lockedSlots) ?? []
    }

    public subscript(slotID: String) -> UUID? {
        get { assetBySlot[slotID] }
        set { assetBySlot[slotID] = newValue }
    }

    public func isLocked(_ slotID: String) -> Bool { lockedSlots.contains(slotID) }

    public mutating func setLocked(_ locked: Bool, slotID: String) {
        if locked { lockedSlots.insert(slotID) } else { lockedSlots.remove(slotID) }
    }
}

/// The persistable, framework-free description of a user asset's visual features.
///
/// Lives in `RecipeCore` so it can travel inside `Project` JSON. `Mapping` produces it from
/// Vision requests and consumes it for scoring; nothing here references a Vision type — the
/// feature print is stored as raw floats and compared with plain Euclidean distance, which is
/// exactly what `VNFeaturePrintObservation.computeDistance` does under the hood.
public struct AssetFeatures: Codable, Sendable, Hashable {
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
    /// 0…1, from Laplacian variance. Low means soft focus or motion blur.
    public var sharpness: Double?
    public var faceCount: Int
    public var isVideo: Bool
    public var duration: Double
    /// Vision feature print, for near-duplicate detection between assets.
    public var featurePrint: [Float]?

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
        sharpness: Double? = nil,
        faceCount: Int = 0,
        isVideo: Bool = false,
        duration: Double = 0,
        featurePrint: [Float]? = nil
    ) {
        self.assetID = assetID
        self.salientAreaFraction = salientAreaFraction
        self.salientRect = salientRect
        self.aestheticScore = aestheticScore
        self.isUtility = isUtility
        self.orientation = orientation
        self.aspectRatio = aspectRatio
        self.brightness = brightness
        self.sharpness = sharpness
        self.faceCount = faceCount
        self.isVideo = isVideo
        self.duration = duration
        self.featurePrint = featurePrint
    }

    private enum CodingKeys: String, CodingKey {
        case assetID, salientAreaFraction, salientRect, aestheticScore, isUtility, orientation
        case aspectRatio, brightness, sharpness, faceCount, isVideo, duration, featurePrint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try c.decode(UUID.self, forKey: .assetID)
        salientAreaFraction = try c.decodeIfPresent(Double.self, forKey: .salientAreaFraction)
        salientRect = try c.decodeIfPresent(NormalizedRect.self, forKey: .salientRect)
        aestheticScore = try c.decodeIfPresent(Double.self, forKey: .aestheticScore)
        isUtility = try c.decodeIfPresent(Bool.self, forKey: .isUtility) ?? false
        orientation = try c.decodeIfPresent(AssetOrientation.self, forKey: .orientation) ?? .portrait
        aspectRatio = try c.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? 1
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.5
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness)
        faceCount = try c.decodeIfPresent(Int.self, forKey: .faceCount) ?? 0
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        featurePrint = try c.decodeIfPresent([Float].self, forKey: .featurePrint)
    }

    /// Euclidean distance between feature prints. Smaller is more similar; identical images
    /// give 0. Nil if either print is missing or the two are not comparable.
    public func featureDistance(to other: AssetFeatures) -> Double? {
        guard let a = featurePrint, let b = other.featurePrint, a.count == b.count, !a.isEmpty
        else { return nil }
        var sum: Double = 0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// A single 0…1 "worth using" score combining aesthetics, sharpness and the utility flag.
    /// The mapper uses the individual signals; this is for sorting and badges.
    public var qualityScore: Double {
        var score = 0.5
        if let aestheticScore { score = min(1, max(0, (aestheticScore + 1) / 2)) }
        if let sharpness { score = score * 0.75 + sharpness * 0.25 }
        if isUtility { score *= 0.3 }
        return score
    }
}
