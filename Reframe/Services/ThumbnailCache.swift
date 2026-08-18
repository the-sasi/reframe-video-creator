import AVFoundation
import ImageIO
import Photos
import ReframeKit
import UIKit

/// One place that turns an `AssetReference` into a small `UIImage`, with a session cache.
///
/// Every grid, row and timeline strip used to load its own thumbnails, each with its own
/// PhotoKit request and its own spinner. Centralising it means an asset is decoded once for
/// the whole session, and the timeline strip — which asks for the same twenty images on every
/// zoom step — never touches PhotoKit twice.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 400
    }

    func cached(for asset: AssetReference, size: CGSize) -> UIImage? {
        cache.object(forKey: key(asset, size) as NSString)
    }

    func thumbnail(for asset: AssetReference, size: CGSize) async -> UIImage? {
        let cacheKey = key(asset, size)
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }
        if let running = inFlight[cacheKey] { return await running.value }

        let task = Task<UIImage?, Never> { [asset] in
            await Self.load(asset, size: size)
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image { cache.setObject(image, forKey: cacheKey as NSString) }
        return image
    }

    func evictAll() {
        cache.removeAllObjects()
    }

    private func key(_ asset: AssetReference, _ size: CGSize) -> String {
        "\(asset.id.uuidString)|\(Int(size.width))x\(Int(size.height))"
    }

    private static func load(_ asset: AssetReference, size: CGSize) async -> UIImage? {
        let scale = UIScreen.main.scale
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        switch asset.origin {
        case .photoLibrary(let identifier):
            return await libraryThumbnail(identifier, size: pixels)
        case .sandboxRelativePath(let path):
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return await fileThumbnail(documents.appendingPathComponent(path), kind: asset.kind, size: pixels)
        case .fileBookmark(let data):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return nil
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return await fileThumbnail(url, kind: asset.kind, size: pixels)
        }
    }

    private static func libraryThumbnail(_ identifier: String, size: CGSize) async -> UIImage? {
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        // iCloud-resident photos would otherwise show a permanent spinner in the grid.
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: phAsset, targetSize: size, contentMode: .aspectFill, options: options
            ) { result, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
    }

    private static func fileThumbnail(_ url: URL, kind: AssetKind, size: CGSize) async -> UIImage? {
        switch kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else { return nil }
            return UIImage(cgImage: cgImage)
        case .audio:
            return nil
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary
                  ) else { return nil }
            return UIImage(cgImage: thumbnail)
        }
    }
}
