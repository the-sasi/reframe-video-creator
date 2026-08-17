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

    public init(
        textBySlot: [String: String] = [:],
        logoAssetID: UUID? = nil,
        musicAssetID: UUID? = nil,
        voiceoverAssetID: UUID? = nil
    ) {
        self.textBySlot = textBySlot
        self.logoAssetID = logoAssetID
        self.musicAssetID = musicAssetID
        self.voiceoverAssetID = voiceoverAssetID
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

    public init(assetBySlot: [String: UUID] = [:], reasonBySlot: [String: String] = [:]) {
        self.assetBySlot = assetBySlot
        self.reasonBySlot = reasonBySlot
    }

    public subscript(slotID: String) -> UUID? {
        get { assetBySlot[slotID] }
        set { assetBySlot[slotID] = newValue }
    }
}
