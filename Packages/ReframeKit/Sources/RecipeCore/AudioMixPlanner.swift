import Foundation

/// Every sound in the timeline, resolved to tracks with gain envelopes.
///
/// A pure function of `(Timeline, AssetPool)`, and the *only* description of the mix: preview
/// builds its `AVAudioMix` from this and export reads its PCM through the same plan. Fades,
/// per-clip volume, muting and ducking are decided here once, so what you hear while editing
/// is what gets written — the audio counterpart of `RenderPlan`.
public struct AudioMixPlan: Sendable, Hashable {

    public struct GainPoint: Sendable, Hashable {
        /// Timeline seconds.
        public var time: Double
        /// 0…1.
        public var gain: Double

        public init(time: Double, gain: Double) {
            self.time = time
            self.gain = gain
        }
    }

    public struct Track: Sendable, Hashable, Identifiable {
        /// The `AudioClip.id` or `VideoClip.id` this track came from.
        public var id: UUID
        public var assetID: UUID
        public var role: AudioRole
        public var timelineStart: Double
        /// Timeline seconds.
        public var duration: Double
        public var sourceStart: Double
        /// Source seconds consumed per timeline second. 1 for audio clips; a video clip's speed.
        public var speed: Double
        /// Piecewise-linear gain, sorted by time, covering `[timelineStart, timelineEnd]`.
        public var envelope: [GainPoint]
        /// Whether this is a video clip's own soundtrack rather than a dedicated audio clip.
        public var isFromVideoClip: Bool

        public init(
            id: UUID, assetID: UUID, role: AudioRole, timelineStart: Double, duration: Double,
            sourceStart: Double, speed: Double, envelope: [GainPoint], isFromVideoClip: Bool
        ) {
            self.id = id
            self.assetID = assetID
            self.role = role
            self.timelineStart = timelineStart
            self.duration = duration
            self.sourceStart = sourceStart
            self.speed = speed
            self.envelope = envelope
            self.isFromVideoClip = isFromVideoClip
        }

        public var timelineEnd: Double { timelineStart + duration }
        public var sourceDuration: Double { duration * speed }

        /// Linear interpolation of the envelope. Zero outside the track.
        public func gain(at time: Double) -> Double {
            guard time >= timelineStart, time <= timelineEnd, let first = envelope.first else { return 0 }
            if time <= first.time { return first.gain }
            for i in 1..<envelope.count {
                let a = envelope[i - 1]
                let b = envelope[i]
                if time <= b.time {
                    let span = b.time - a.time
                    guard span > 1e-9 else { return b.gain }
                    let t = (time - a.time) / span
                    return a.gain + (b.gain - a.gain) * t
                }
            }
            return envelope.last?.gain ?? 0
        }

        /// Whether the envelope is ever audible. Silent tracks are dropped from the plan.
        public var isAudible: Bool { envelope.contains { $0.gain > 0.0005 } }
    }

    public var tracks: [Track]
    public var duration: Double

    public init(tracks: [Track], duration: Double) {
        self.tracks = tracks
        self.duration = duration
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// Tracks audible at `time`. For the level meter and the "what am I hearing" caption.
    public func audibleTracks(at time: Double) -> [Track] {
        tracks.filter { $0.gain(at: time) > 0.0005 }
    }
}

public struct AudioMixPlanner: Sendable {

    public struct Parameters: Sendable {
        /// Music level while a voice track is audible, as a fraction of its own gain.
        public var duckLevel: Double
        /// Seconds to ramp down before a voice starts and up after it ends.
        public var duckRamp: Double
        /// Tiny fades on video-clip audio so a cut never clicks.
        public var clipEdgeFade: Double

        public init(duckLevel: Double = 0.22, duckRamp: Double = 0.30, clipEdgeFade: Double = 0.012) {
            self.duckLevel = duckLevel
            self.duckRamp = duckRamp
            self.clipEdgeFade = clipEdgeFade
        }

        public static let `default` = Parameters()
    }

    public let parameters: Parameters

    public init(parameters: Parameters = .default) {
        self.parameters = parameters
    }

    public func plan(_ timeline: Timeline, assets: AssetPool) -> AudioMixPlan {
        let duration = timeline.duration
        var tracks: [AudioMixPlan.Track] = []

        // Voice intervals drive ducking. Only dedicated voice clips count — a video clip's own
        // sound is treated as ambience rather than as narration.
        let voiceIntervals: [(Double, Double)] = timeline.duckMusicUnderVoice
            ? timeline.audio
                .filter { $0.role.causesDucking && !$0.isMuted && $0.volume > 0 }
                .map { ($0.start, $0.end) }
            : []

        for clip in timeline.audio where !clip.isMuted && clip.volume > 0 {
            guard clip.duration > 0, assets[clip.assetID] != nil else { continue }
            let envelope = envelope(
                for: clip,
                ducked: clip.role.isDucked ? voiceIntervals : []
            )
            let track = AudioMixPlan.Track(
                id: clip.id, assetID: clip.assetID, role: clip.role,
                timelineStart: clip.start, duration: clip.duration,
                sourceStart: clip.sourceStart, speed: 1,
                envelope: envelope, isFromVideoClip: false
            )
            if track.isAudible { tracks.append(track) }
        }

        // Video clips' own soundtracks, where the user turned them up.
        for clip in timeline.clips where clip.volume > 0.0005 {
            guard let assetID = clip.assetID,
                  let asset = assets[assetID], asset.kind == .video,
                  clip.duration > 0 else { continue }
            let envelope = clipEnvelope(
                start: clip.start, end: clip.end, volume: clip.volume,
                ducked: voiceIntervals
            )
            let track = AudioMixPlan.Track(
                id: clip.id, assetID: assetID, role: .clipAudio,
                timelineStart: clip.start, duration: clip.duration,
                sourceStart: clip.sourceStart, speed: clip.speed,
                envelope: envelope, isFromVideoClip: true
            )
            if track.isAudible { tracks.append(track) }
        }

        tracks.sort { ($0.timelineStart, $0.id.uuidString) < ($1.timelineStart, $1.id.uuidString) }
        return AudioMixPlan(tracks: tracks, duration: duration)
    }

    // MARK: - Envelopes

    private func envelope(for clip: AudioClip, ducked: [(Double, Double)]) -> [AudioMixPlan.GainPoint] {
        var breakpoints: Set<Double> = [clip.start, clip.end]
        if clip.fadeIn > 0 { breakpoints.insert(min(clip.end, clip.start + clip.fadeIn)) }
        if clip.fadeOut > 0 { breakpoints.insert(max(clip.start, clip.end - clip.fadeOut)) }
        insertDuckBreakpoints(&breakpoints, intervals: ducked, within: clip.start...clip.end)

        return breakpoints.sorted().map { time in
            AudioMixPlan.GainPoint(
                time: time,
                gain: clampGain(clip.gain(at: min(time, clip.end - 1e-6)) * duckFactor(at: time, intervals: ducked))
            )
        }
    }

    private func clipEnvelope(
        start: Double, end: Double, volume: Double, ducked: [(Double, Double)]
    ) -> [AudioMixPlan.GainPoint] {
        let fade = min(parameters.clipEdgeFade, (end - start) / 2)
        var breakpoints: Set<Double> = [start, start + fade, end - fade, end]
        insertDuckBreakpoints(&breakpoints, intervals: ducked, within: start...end)

        return breakpoints.sorted().map { time in
            var g = volume
            if fade > 0 {
                if time - start < fade { g *= (time - start) / fade }
                if end - time < fade { g *= (end - time) / fade }
            }
            return AudioMixPlan.GainPoint(
                time: time,
                gain: clampGain(g * duckFactor(at: time, intervals: ducked))
            )
        }
    }

    private func insertDuckBreakpoints(
        _ breakpoints: inout Set<Double>, intervals: [(Double, Double)], within range: ClosedRange<Double>
    ) {
        let ramp = parameters.duckRamp
        for (s, e) in intervals {
            for t in [s - ramp, s, e, e + ramp] where range.contains(t) {
                breakpoints.insert(t)
            }
        }
    }

    /// 1 outside voice, `duckLevel` inside, linear ramps either side. Overlapping intervals
    /// take the deepest duck.
    func duckFactor(at time: Double, intervals: [(Double, Double)]) -> Double {
        guard !intervals.isEmpty else { return 1 }
        let ramp = parameters.duckRamp
        let level = parameters.duckLevel
        var factor = 1.0
        for (s, e) in intervals {
            let f: Double
            if time >= s, time <= e {
                f = level
            } else if time < s, time > s - ramp, ramp > 0 {
                let t = (s - time) / ramp        // 1 at ramp start, 0 at s
                f = level + (1 - level) * t
            } else if time > e, time < e + ramp, ramp > 0 {
                let t = (time - e) / ramp        // 0 at e, 1 at ramp end
                f = level + (1 - level) * t
            } else {
                f = 1
            }
            factor = min(factor, f)
        }
        return factor
    }

    private func clampGain(_ g: Double) -> Double { min(max(g, 0), 1) }
}
