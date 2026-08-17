import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import RecipeCore

#if canImport(UIKit)
import UIKit

/// `PHImageManager` hands back the platform image type — `UIImage` on iOS, `NSImage` on macOS —
/// and only one of them has a `cgImage` property. The engine builds for macOS so `swift test`
/// can run without a simulator, so this has to work on both.
extension UIImage {
    var platformCGImage: CGImage? { cgImage }
}
#elseif canImport(AppKit)
import AppKit

extension NSImage {
    var platformCGImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif

/// A resolved asset: the reference plus a way to actually get at pixels.
public struct ResolvedAsset: @unchecked Sendable {
    public let reference: AssetReference
    /// For stills.
    public let image: CGImage?
    /// For video and audio.
    public let asset: AVAsset?

    public init(reference: AssetReference, image: CGImage?, asset: AVAsset?) {
        self.reference = reference
        self.image = image
        self.asset = asset
    }
}

/// Turns `AssetReference`s into pixels, on demand.
///
/// Resolution can fail — the user deletes a photo from their library — and that is a normal
/// case, not a crash. Callers get `nil` and render a labelled placeholder.
public actor AssetResolver {

    private var imageCache: [UUID: CGImage] = [:]
    /// Bounded so a 30-photo project cannot pin 30 full-resolution decodes.
    private var cacheOrder: [UUID] = []
    private let cacheLimit: Int

    public init(cacheLimit: Int = 8) {
        self.cacheLimit = cacheLimit
    }

    public func resolve(_ reference: AssetReference, maxDimension: Int? = nil) async -> ResolvedAsset? {
        switch reference.kind {
        case .image:
            guard let image = await loadImage(reference, maxDimension: maxDimension) else { return nil }
            return ResolvedAsset(reference: reference, image: image, asset: nil)
        case .video, .audio:
            guard let asset = await loadAVAsset(reference) else { return nil }
            return ResolvedAsset(reference: reference, image: nil, asset: asset)
        }
    }

    public func evictCache() {
        imageCache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - Images

    private func loadImage(_ reference: AssetReference, maxDimension: Int?) async -> CGImage? {
        if maxDimension == nil, let cached = imageCache[reference.id] { return cached }

        let image: CGImage?
        switch reference.origin {
        case .photoLibrary(let localIdentifier):
            image = await loadFromPhotos(localIdentifier: localIdentifier, maxDimension: maxDimension)
        case .fileBookmark(let data):
            image = withSecurityScopedURL(data) { url in
                Self.decodeImage(at: url, maxDimension: maxDimension)
            }
        case .sandboxRelativePath(let path):
            let url = Self.documentsURL.appendingPathComponent(path)
            image = Self.decodeImage(at: url, maxDimension: maxDimension)
        }

        if let image, maxDimension == nil {
            store(image, for: reference.id)
        }
        return image
    }

    /// Downsamples during decode rather than after. Decoding a 48 MP photo to full size and
    /// then scaling it costs ~190 MB of transient memory per photo; this costs the size of the
    /// result.
    private static func decodeImage(at url: URL, maxDimension: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let maxDimension else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func loadFromPhotos(localIdentifier: String, maxDimension: Int?) async -> CGImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let phAsset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false  // iCloud fetches are a network request; we do not make them
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false

        let targetSize: CGSize = maxDimension.map {
            CGSize(width: $0, height: $0)
        } ?? PHImageManagerMaximumSize

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // The handler can fire twice (degraded then full). Resume once.
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                resumed = true
                continuation.resume(returning: image?.platformCGImage)
            }
        }
    }

    // MARK: - AV assets

    private func loadAVAsset(_ reference: AssetReference) async -> AVAsset? {
        switch reference.origin {
        case .photoLibrary(let localIdentifier):
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let phAsset = fetch.firstObject else { return nil }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            return await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(
                    forVideo: phAsset, options: options
                ) { asset, _, _ in
                    continuation.resume(returning: asset)
                }
            }
        case .fileBookmark(let data):
            return withSecurityScopedURL(data) { AVURLAsset(url: $0) }
        case .sandboxRelativePath(let path):
            return AVURLAsset(url: Self.documentsURL.appendingPathComponent(path))
        }
    }

    // MARK: - Helpers

    private func store(_ image: CGImage, for id: UUID) {
        imageCache[id] = image
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > cacheLimit {
            imageCache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func withSecurityScopedURL<T>(_ bookmark: Data, _ body: (URL) -> T?) -> T? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
