import AVFoundation
import Foundation
import MediaIO
import RecipeCore

/// `AudioMixPlan` -> `AVMutableComposition` + `AVMutableAudioMix`.
///
/// The one place a mix becomes AVFoundation objects. Preview hands the result to an
/// `AVPlayer`; export reads it back through `AVAssetReaderAudioMixOutput`. Both therefore hear
/// exactly the plan — fades, per-clip volume, ducking, speed — with Apple's mixer doing the
/// arithmetic in both cases. The audio counterpart of "preview and export share `render()`".
public struct AudioMixComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let audioMix: AVMutableAudioMix
    /// The plan this was built from, so callers can skip a rebuild when nothing changed.
    public let plan: AudioMixPlan

    public var isEmpty: Bool { composition.tracks(withMediaType: .audio).isEmpty }
}

public enum AudioMixBuilder {

    /// Builds the composition. Tracks whose asset cannot be resolved (deleted from Photos, say)
    /// are skipped with a log line rather than failing the whole mix — a video with music and
    /// no voiceover is a far better outcome than one with no sound.
    public static func build(plan: AudioMixPlan, resolver: AssetResolver, assets: AssetPool) async -> AudioMixComposition {
        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []

        for track in plan.tracks {
            guard let reference = assets[track.assetID] else { continue }
            guard let resolved = await resolver.resolve(reference),
                  let asset = resolved.asset,
                  let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
                DiagnosticsLog.shared.warning(
                    "audio", "no audio track for \(reference.displayName); skipping \(track.role.rawValue)"
                )
                continue
            }
            let sourceDuration = (try? await asset.load(.duration).seconds) ?? track.sourceDuration

            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            // Clamp the source range to what the file actually has; a request past the end
            // throws from `insertTimeRange`, and a track that runs out simply goes quiet.
            let sourceStart = min(max(0, track.sourceStart), max(0, sourceDuration))
            let available = max(0, sourceDuration - sourceStart)
            let wantedSource = min(track.sourceDuration, available)
            guard wantedSource > 0.01 else { continue }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 44_100),
                duration: CMTime(seconds: wantedSource, preferredTimescale: 44_100)
            )
            let at = CMTime(seconds: track.timelineStart, preferredTimescale: 44_100)

            do {
                if track.timelineStart > 0.001 {
                    compositionTrack.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: at))
                }
                try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: at)
            } catch {
                DiagnosticsLog.shared.warning("audio", "insert failed for \(reference.displayName): \(error)")
                continue
            }

            // Speed: squeeze or stretch the inserted range so it occupies the clip's timeline
            // duration. Pitch is preserved by the algorithm choice below.
            if abs(track.speed - 1) > 0.001 {
                let inserted = CMTimeRange(start: at, duration: sourceRange.duration)
                let target = CMTime(seconds: wantedSource / track.speed, preferredTimescale: 44_100)
                compositionTrack.scaleTimeRange(inserted, toDuration: target)
            }

            let input = AVMutableAudioMixInputParameters(track: compositionTrack)
            input.audioTimePitchAlgorithm = abs(track.speed - 1) > 0.001 ? .spectral : .timeDomain
            applyEnvelope(track.envelope, to: input)
            parameters.append(input)
        }

        audioMix.inputParameters = parameters
        return AudioMixComposition(composition: composition, audioMix: audioMix, plan: plan)
    }

    /// Piecewise-linear gain -> a chain of volume ramps. The first point sets the initial
    /// level explicitly, otherwise AVFoundation starts the track at full volume until the
    /// first ramp begins.
    private static func applyEnvelope(_ envelope: [AudioMixPlan.GainPoint], to input: AVMutableAudioMixInputParameters) {
        guard let first = envelope.first else { return }
        input.setVolume(Float(first.gain), at: CMTime(seconds: max(0, first.time), preferredTimescale: 44_100))
        guard envelope.count > 1 else { return }
        for i in 1..<envelope.count {
            let a = envelope[i - 1]
            let b = envelope[i]
            let span = b.time - a.time
            guard span > 1e-6 else {
                input.setVolume(Float(b.gain), at: CMTime(seconds: b.time, preferredTimescale: 44_100))
                continue
            }
            input.setVolumeRamp(
                fromStartVolume: Float(a.gain), toEndVolume: Float(b.gain),
                timeRange: CMTimeRange(
                    start: CMTime(seconds: a.time, preferredTimescale: 44_100),
                    duration: CMTime(seconds: span, preferredTimescale: 44_100)
                )
            )
        }
    }
}
