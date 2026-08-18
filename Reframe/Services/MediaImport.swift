import AVFoundation
import ImageIO
import Photos
import PhotosUI
import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns picker results into `AssetReference`s.
///
/// Preferred path: reference the library asset by identifier, copying nothing. Fallback: no
/// identifier — Limited Library access, an iCloud-only item, or a picker that declined to hand
/// one over — copy the file into the sandbox so the import still succeeds rather than silently
/// dropping the item.
enum MediaImport {

    static func reference(from item: PhotosPickerItem) async -> AssetReference? {
        if let identifier = item.itemIdentifier, let reference = libraryReference(for: identifier) {
            return reference
        }
        return await copiedReference(from: item)
    }

    /// Builds a reference from a Photos identifier, reading dimensions from `PHAsset` rather
    /// than by decoding — so adding 40 items costs no image decoding at all.
    static func libraryReference(for identifier: String) -> AssetReference? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let phAsset = fetch.firstObject else { return nil }

        let kind: AssetKind
        switch phAsset.mediaType {
        case .image: kind = .image
        case .video: kind = .video
        case .audio: kind = .audio
        default: return nil
        }

        return AssetReference(
            kind: kind,
            origin: .photoLibrary(localIdentifier: identifier),
            displayName: (phAsset.value(forKey: "filename") as? String) ?? "Item",
            pixelWidth: phAsset.pixelWidth,
            pixelHeight: phAsset.pixelHeight,
            duration: phAsset.duration,
            creationDate: phAsset.creationDate
        )
    }

    /// Copies a picked item into the sandbox and measures it. Slower and uses disk, which is
    /// why it is the fallback rather than the default.
    static func copiedReference(from item: PhotosPickerItem) async -> AssetReference? {
        guard let media = try? await item.loadTransferable(type: PickedMedia.self) else {
            return nil
        }

        let ext = media.url.pathExtension.lowercased()
        let isVideo = ["mov", "mp4", "m4v"].contains(ext)

        var width = 0
        var height = 0
        var duration = 0.0

        if isVideo {
            let asset = AVURLAsset(url: media.url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let presented = size.applying(transform)
                width = Int(abs(presented.width).rounded())
                height = Int(abs(presented.height).rounded())
            }
            duration = (try? await asset.load(.duration).seconds) ?? 0
        } else if let source = CGImageSourceCreateWithURL(media.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
            // EXIF orientation 5–8 means the stored pixels are rotated; present the upright size.
            if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
                swap(&width, &height)
            }
        }

        guard width > 0, height > 0 else { return nil }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/\(media.url.lastPathComponent)"
        let destination = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: media.url, to: destination)) != nil else {
            return nil
        }

        return AssetReference(
            kind: isVideo ? .video : .image,
            origin: .sandboxRelativePath(relative),
            displayName: media.url.lastPathComponent,
            pixelWidth: width,
            pixelHeight: height,
            duration: duration
        )
    }

    /// Copies an audio file from Files into the sandbox and validates it can be decoded.
    /// Returns nil (with a reason) for DRM-protected tracks — Apple Music downloads copy fine
    /// but have no readable audio track.
    static func importAudio(from url: URL) async -> (reference: AssetReference?, note: String?) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/audio-\(UUID().uuidString).\(url.pathExtension)"
        let destination = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
            DiagnosticsLog.shared.failure("content", "could not copy audio \(url.lastPathComponent)")
            return (nil, "Couldn't read that audio file.")
        }

        let asset = AVURLAsset(url: destination)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        guard duration > 0, hasAudio else {
            try? FileManager.default.removeItem(at: destination)
            DiagnosticsLog.shared.warning("content", "audio unreadable or DRM-protected: \(url.lastPathComponent)")
            return (nil, "That track is protected and can't be used. Apple Music downloads won't work — try a file you own.")
        }

        let reference = AssetReference(
            kind: .audio,
            origin: .sandboxRelativePath(relative),
            displayName: url.deletingPathExtension().lastPathComponent,
            pixelWidth: 0, pixelHeight: 0, duration: duration
        )
        DiagnosticsLog.shared.info("content", "audio added: \(reference.displayName), \(String(format: "%.1fs", duration))")
        return (reference, nil)
    }
}

/// Carries a picked photo or video out of the picker as a file we control.
///
/// Both representations are declared because `.any(of: [.images, .videos])` can hand back
/// either, and a movie has no useful `Data` representation at 4K.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { media in
            SentTransferredFile(media.url)
        } importing: { received in
            PickedMedia(url: try Self.stage(received.file, fallbackExtension: "mov"))
        }

        FileRepresentation(contentType: .image) { media in
            SentTransferredFile(media.url)
        } importing: { received in
            PickedMedia(url: try Self.stage(received.file, fallbackExtension: "jpg"))
        }
    }

    /// The picker deletes its temporary file the moment the transfer completes, so it has to be
    /// moved somewhere we own before anything else touches it.
    private static func stage(_ file: URL, fallbackExtension: String) throws -> URL {
        let ext = file.pathExtension.isEmpty ? fallbackExtension : file.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }
}
