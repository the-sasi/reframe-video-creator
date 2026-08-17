import AVFoundation
import CryptoKit
import Foundation
import RecipeCore

/// A validated reference video, ready to analyse.
///
/// Validation happens once, here, so no analyser has to defend against a missing video track or
/// a zero-length asset. Construction either yields something analysable or throws a
/// `ReframeError` with a usable recovery action.
public struct MediaSource: Sendable {
    public let asset: AVURLAsset
    public let url: URL
    public let info: SourceInfo

    private let videoTrackBox: TrackBox
    private let audioTrackBox: TrackBox?

    public var videoTrack: AVAssetTrack { videoTrackBox.track }
    public var audioTrack: AVAssetTrack? { audioTrackBox?.track }

    /// `AVAssetTrack` carries no `Sendable` conformance, which would otherwise force the whole
    /// of `MediaSource` to become `@unchecked`.
    ///
    /// Boxing keeps the struct's conformance *checked* and confines the unchecked claim to one
    /// place with one justification: a track here is an immutable descriptor resolved once
    /// during `init`, never reassigned, and only ever read through the async `load(_:)` API —
    /// which is the access path Apple documents as usable from any thread.
    private struct TrackBox: @unchecked Sendable {
        let track: AVAssetTrack
    }

    /// References longer than this produce unwieldy templates and slow analysis for no benefit.
    /// Not a hard failure — the caller can proceed after warning.
    public static let recommendedMaxDuration: Double = 120

    public init(url: URL) async throws {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        self.asset = asset
        self.url = url

        let isPlayable: Bool
        do {
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            throw ReframeError.corruptMedia(detail: error.localizedDescription)
        }
        guard isPlayable else {
            throw ReframeError.unsupportedFormat(detail: url.pathExtension.uppercased())
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else {
            throw ReframeError.noVideoTrack
        }
        // Held as a local as well as a stored property: `audioTrack` is a computed property
        // now, and reading one inside `init` before every stored property is assigned is
        // illegal — it requires a fully-initialized `self`.
        let audio = try await asset.loadTracks(withMediaType: .audio).first

        self.videoTrackBox = TrackBox(track: video)
        self.audioTrackBox = audio.map(TrackBox.init(track:))

        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ReframeError.corruptMedia(detail: "non-finite duration")
        }

        let nominalFPS = try await video.load(.nominalFrameRate)
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)

        // `naturalSize` ignores rotation. A portrait iPhone video reports 1920x1080 with a 90°
        // transform, and using it raw would make every vertical reference look landscape.
        let presented = naturalSize.applying(transform)
        let width = Int(abs(presented.width).rounded())
        let height = Int(abs(presented.height).rounded())

        self.info = SourceInfo(
            duration: duration,
            fps: nominalFPS > 0 ? Double(nominalFPS) : 30,
            width: width,
            height: height,
            aspect: AspectPreset(width: width, height: height),
            hasAudio: audio != nil,
            fingerprint: Self.fingerprint(url: url, duration: duration, width: width, height: height)
        )
    }

    /// Identifies the reference for cache keys and determinism seeding.
    ///
    /// Hashes the head of the file plus its size and dimensions rather than the whole file —
    /// reading 1 MB is instant, reading a 4K video to hash it is not, and the combination is
    /// more than distinctive enough for a personal library.
    private static func fingerprint(url: URL, duration: Double, width: Int, height: Int) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(duration)|\(width)x\(height)".utf8))

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 1_048_576) {
                hasher.update(data: head)
            }
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64 {
                hasher.update(data: Data("\(size)".utf8))
            }
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public var isLongerThanRecommended: Bool {
        info.duration > Self.recommendedMaxDuration
    }
}
