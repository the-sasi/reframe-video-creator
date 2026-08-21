import Foundation

/// Plans an edit *from music*: beat grid + energy structure in, `EditRecipe` out.
///
/// This is Flow B's engine. It deliberately produces the same artifact reference analysis
/// does — a recipe — so asset mapping, subject-aware binding, preview, variations, undo and
/// export are all the existing pipeline. There is no second editing architecture here; music
/// is simply another author of the plan.
///
/// The planner is deterministic: the same analysis and options produce byte-identical output
/// (IDs are seeded from the track fingerprint), which makes it testable in CoreCheck on any
/// platform and diffable across algorithm changes.
public enum MusicEditPlanner {

    // MARK: - Input

    /// The slice of audio analysis the planner needs, platform-free so RecipeCore never
    /// imports AVFoundation. Built from `AudioAnalysis` in the app layer.
    public struct MusicProfile: Codable, Sendable, Hashable {
        public var bpm: Double
        public var bpmConfidence: Double
        public var beats: [Double]
        public var downbeats: [Double]
        /// Normalised RMS envelope at `energySamplesPerSecond`.
        public var energyCurve: [Double]
        public var energySamplesPerSecond: Double
        public var duration: Double
        /// Content hash of the track; seeds all generated identifiers.
        public var fingerprint: String

        public init(
            bpm: Double, bpmConfidence: Double, beats: [Double], downbeats: [Double],
            energyCurve: [Double], energySamplesPerSecond: Double = 4,
            duration: Double, fingerprint: String
        ) {
            self.bpm = bpm
            self.bpmConfidence = bpmConfidence
            self.beats = beats
            self.downbeats = downbeats
            self.energyCurve = energyCurve
            self.energySamplesPerSecond = energySamplesPerSecond
            self.duration = duration
            self.fingerprint = fingerprint
        }
    }

    public struct Options: Sendable, Hashable {
        public var canvas: CanvasSpec
        /// Hard cap on the edit's length. The edit ends on a downbeat at or before this.
        public var maxDuration: Double
        /// How many visual assets the user brought. The planner aims for roughly one slot per
        /// asset (reuse is the binder's business), and never plans fewer than 4 scenes.
        public var assetCount: Int
        /// 0...1, how hard the edit leans into the music. 0.5 is the default feel; higher
        /// means denser cutting at peaks and stronger motion contrast between sections.
        public var intensity: Double

        public init(
            canvas: CanvasSpec = .reel1080, maxDuration: Double = 30,
            assetCount: Int = 8, intensity: Double = 0.5
        ) {
            self.canvas = canvas
            self.maxDuration = maxDuration
            self.assetCount = assetCount
            self.intensity = min(max(intensity, 0), 1)
        }
    }

    // MARK: - Plan

    public static func plan(music: MusicProfile, options: Options = Options()) -> EditRecipe {
        let ids = DeterministicID(seed: "music/\(music.fingerprint)")
        let duration = min(music.duration, options.maxDuration)
        let sections = MusicSectionizer.sections(
            energyCurve: music.energyCurve,
            samplesPerSecond: music.energySamplesPerSecond,
            duration: music.duration
        )

        // 1. Cut times: walk the beats, keeping a per-section target of beats-per-cut. Cuts
        //    prefer downbeats when the target allows, so structural moments land structurally.
        let cuts = planCuts(music: music, sections: sections, duration: duration, options: options)

        // 2. Cut times → scenes, with per-section motion and transitions.
        var scenes: [SceneTemplate] = []
        for (index, bounds) in zip(cuts, cuts.dropFirst()).enumerated() {
            let (start, end) = bounds
            let mid = (start + end) / 2
            let section = sections.last(where: { $0.start <= mid }) ?? sections.first
                ?? MusicSection(kind: .steady, start: 0, end: duration, intensity: 0.5)
            scenes.append(scene(
                index: index, start: start, end: end,
                section: section, options: options, ids: ids
            ))
        }

        // 3. Recipe wrapper. `cutsAlignedToBeats` is true by construction, which is what makes
        //    the binder quantise and the "snap to music" default fire.
        let grid = BeatGrid(
            bpm: Confident(music.bpm, confidence: music.bpmConfidence, basis: "your track"),
            beats: music.beats,
            downbeats: music.downbeats,
            cutsAlignedToBeats: .measured(true, "planned on the grid")
        )
        let durations = scenes.map(\.duration).sorted()
        let median = durations.isEmpty ? 0 : durations[durations.count / 2]
        let actualDuration = scenes.last?.end ?? duration

        return EditRecipe(
            id: ids.uuid("recipe"),
            title: "Music Edit",
            createdAt: Date(timeIntervalSince1970: 0),  // overwritten by the caller; keeps output deterministic
            source: SourceInfo(
                duration: music.duration, fps: Double(options.canvas.fps),
                width: options.canvas.width, height: options.canvas.height,
                aspect: AspectPreset(width: options.canvas.width, height: options.canvas.height),
                hasAudio: true, fingerprint: music.fingerprint
            ),
            canvas: options.canvas,
            duration: actualDuration,
            beatGrid: grid,
            scenes: scenes,
            textSlots: [],
            audio: AudioPlan(
                hasMusic: true,
                hasSpeech: Confident(false, confidence: 0.5, basis: "not analysed for speech"),
                energyCurve: music.energyCurve,
                suggestedCutStyle: .onBeat
            ),
            palette: Palette(dominant: [], meanBrightness: 0.5, meanSaturation: 0.5, contrast: 0.5),
            stats: RecipeStats(
                sceneCount: scenes.count,
                medianSceneDuration: median,
                cutsPerSecond: actualDuration > 0 ? Double(scenes.count) / actualDuration : 0,
                transitionCount: scenes.compactMap(\.transitionIn).filter { $0.kind.value != .cut }.count,
                textSlotCount: 0
            ),
            confidence: ConfidenceReport(
                overall: music.bpmConfidence, scenes: 1.0, motion: 1.0,
                text: 1.0, audio: music.bpmConfidence, weakest: "audio.bpm"
            ),
            tags: ["Beat Sync", "Music"],
            isBuiltIn: false
        )
    }

    // MARK: - Cuts

    /// Beats-per-cut per section kind, before intensity scaling. The feel each kind is after:
    /// intro settles, build accelerates across its own length, peak hits, release exhales.
    static func beatsPerCut(for kind: MusicSection.Kind, intensity: Double) -> Double {
        // intensity 0 → multiply targets by 1.5 (calmer); 1 → by 0.7 (denser).
        let scale = 1.5 - 0.8 * intensity
        switch kind {
        case .intro: return 4 * scale
        case .build: return 2 * scale
        case .peak: return 1 * max(0.9, scale * 0.8)
        case .release: return 3 * scale
        case .outro: return 4 * scale
        case .steady: return 2 * scale
        }
    }

    private static func planCuts(
        music: MusicProfile, sections: [MusicSection],
        duration: Double, options: Options
    ) -> [Double] {
        let beats = music.beats.filter { $0 < duration }.sorted()
        guard beats.count >= 2 else {
            // No usable grid (rubato, spoken word): fall back to even slots so Flow B still
            // produces an edit instead of an error.
            let count = max(4, min(options.assetCount, Int(duration / 2)))
            let step = duration / Double(count)
            return (0...count).map { Double($0) * step }
        }
        let downbeats = Set(music.downbeats.map { quantized($0) })
        let minShot = 0.4
        // Global average shot length also respects how much material the user brought: with 6
        // photos and 30 s, plan ~6–10 scenes, not 40. Achieved by a floor on beats-per-cut.
        let wantedScenes = max(4, options.assetCount + options.assetCount / 2)

        var cuts: [Double] = [0]
        var beatsSinceCut = 0.0
        var index = 0
        while index < beats.count {
            let beat = beats[index]
            defer { index += 1 }
            guard let last = cuts.last, beat - last >= minShot else { continue }
            let section = sections.last(where: { $0.start <= beat })?.kind ?? .steady
            var target = beatsPerCut(for: section, intensity: options.intensity)
            // Material floor: stretch every section proportionally when assets are few.
            let projected = Double(beats.count) / max(1.0, target)
            if projected > Double(wantedScenes) * 1.6 {
                target *= projected / (Double(wantedScenes) * 1.6)
            }
            beatsSinceCut += 1
            let isDownbeat = downbeats.contains(quantized(beat))
            // Cut when the target is met — a beat early if that lands on a downbeat, so
            // structure wins over arithmetic.
            if beatsSinceCut >= target || (isDownbeat && beatsSinceCut >= target - 1) {
                cuts.append(beat)
                beatsSinceCut = 0
            }
        }
        // Close the last scene on the final beat before the cap (or the cap itself).
        if let last = cuts.last, duration - last >= minShot {
            cuts.append(duration)
        } else if cuts.count > 1 {
            cuts[cuts.count - 1] = duration
        }
        return cuts
    }

    private static func quantized(_ time: Double) -> Int { Int((time * 1000).rounded()) }

    // MARK: - Scenes

    private static func scene(
        index: Int, start: Double, end: Double,
        section: MusicSection, options: Options, ids: DeterministicID
    ) -> SceneTemplate {
        let number = index + 1
        let move = cameraMove(index: index, section: section, options: options)
        let transition = transitionIn(index: index, section: section)
        let role: SceneRole = index == 0 ? .opening : (section.kind == .peak ? .hero : .body)
        let framing: ShotFraming
        switch section.kind {
        case .peak: framing = index.isMultiple(of: 2) ? .closeUp : .medium
        case .intro, .outro: framing = .wide
        default: framing = index.isMultiple(of: 3) ? .wide : .medium
        }
        return SceneTemplate(
            id: ids.string("scene", number),
            index: index, start: start, end: end,
            sourceKind: .unknown,
            role: .measured(role, "music section \(section.kind.rawValue)"),
            slot: AssetSlot(
                id: ids.string("asset", number),
                framing: .measured(framing, "music section \(section.kind.rawValue)"),
                motionEnergy: section.intensity
            ),
            move: move,
            transitionIn: transition
        )
    }

    /// Motion follows energy: calm sections drift, builds push in, peaks alternate stronger
    /// zooms, releases pull out. Amounts scale with section intensity and the user's setting.
    private static func cameraMove(
        index: Int, section: MusicSection, options: Options
    ) -> CameraMove {
        let strength = 0.06 + 0.10 * section.intensity * (0.5 + options.intensity)
        let tight = NormalizedRect.full.scaled(by: max(0.78, 1 - strength))
        let basis = "music \(section.kind.rawValue), intensity \(String(format: "%.2f", section.intensity))"
        switch section.kind {
        case .intro, .outro:
            // Gentle drift in; stillness reads as dead air even in an intro.
            let soft = NormalizedRect.full.scaled(by: 0.94)
            return CameraMove(
                kind: Confident(.zoomIn, confidence: 1.0, basis: basis),
                startRect: .full, endRect: soft, easing: .easeInOut
            )
        case .build:
            return CameraMove(
                kind: Confident(.zoomIn, confidence: 1.0, basis: basis),
                startRect: .full, endRect: tight, easing: .easeIn
            )
        case .release:
            return CameraMove(
                kind: Confident(.zoomOut, confidence: 1.0, basis: basis),
                startRect: tight, endRect: .full, easing: .easeOut
            )
        case .peak:
            if index.isMultiple(of: 2) {
                return CameraMove(
                    kind: Confident(.zoomIn, confidence: 1.0, basis: basis),
                    startRect: .full, endRect: tight, easing: .easeOut
                )
            }
            return CameraMove(
                kind: Confident(.zoomOut, confidence: 1.0, basis: basis),
                startRect: tight, endRect: .full, easing: .easeOut
            )
        case .steady:
            let soft = NormalizedRect.full.scaled(by: 0.90)
            if index.isMultiple(of: 2) {
                return CameraMove(
                    kind: Confident(.zoomIn, confidence: 1.0, basis: basis),
                    startRect: .full, endRect: soft, easing: .easeInOut
                )
            }
            return CameraMove(
                kind: Confident(.zoomOut, confidence: 1.0, basis: basis),
                startRect: soft, endRect: .full, easing: .easeInOut
            )
        }
    }

    /// Cuts carry the rhythm; softness is reserved for structural moments so it means
    /// something: dissolve into the intro's second shot, dissolve out of a release/outro.
    private static func transitionIn(index: Int, section: MusicSection) -> TransitionTemplate? {
        guard index > 0 else { return nil }
        let softKinds: TransitionKind?
        switch section.kind {
        case .outro: softKinds = .dissolve
        case .release: softKinds = index.isMultiple(of: 2) ? .dissolve : nil
        default: softKinds = nil
        }
        guard let kind = softKinds else {
            return TransitionTemplate(kind: .measured(.cut, "music"), duration: 0)
        }
        return TransitionTemplate(
            kind: .measured(kind, "music \(section.kind.rawValue)"),
            duration: 0.35, safeFallback: .cut
        )
    }
}
