import Foundation
import RecipeCore

/// Turns observations into a plan: `ReferenceAnalysis` -> `EditRecipe`.
///
/// A pure function, deliberately. All the I/O and framework work happened upstream; this stage
/// is arithmetic and judgement, so it can be tested against a synthetic analysis and it can be
/// re-run under different assumptions without re-analysing the video.
///
/// Determinism: identifiers derive from the source fingerprint via `DeterministicID`, never
/// from `UUID()`. Same reference in, byte-identical JSON out.
public struct RecipeCompiler: Sendable {

    public init() {}

    public func compile(
        _ analysis: ReferenceAnalysis,
        title: String,
        createdAt: Date,
        canvas: CanvasSpec? = nil
    ) -> EditRecipe {
        let ids = DeterministicID(seed: analysis.source.fingerprint)
        let outputCanvas = canvas ?? Self.canvas(for: analysis.source)
        let roles = inferSceneRoles(shots: analysis.shots)

        let scenes = analysis.shots.enumerated().map { index, shot in
            compileScene(
                shot: shot,
                index: index,
                role: roles[index],
                palette: analysis.scenePalettes[index],
                referencePalette: analysis.palette,
                ids: ids
            )
        }

        let textSlots = compileTextSlots(analysis.textTracks, ids: ids)
        let beatGrid = compileBeatGrid(analysis.audio, shots: analysis.shots)
        let audioPlan = compileAudioPlan(analysis.audio, beatGrid: beatGrid)

        let durations = analysis.shots.map(\.duration).sorted()
        let median = durations.isEmpty ? 0 : durations[durations.count / 2]
        let transitionCount = scenes.filter {
            ($0.transitionIn?.effectiveKind ?? .cut) != .cut
        }.count

        let stats = RecipeStats(
            sceneCount: scenes.count,
            medianSceneDuration: median,
            cutsPerSecond: analysis.source.duration > 0
                ? Double(max(0, scenes.count - 1)) / analysis.source.duration
                : 0,
            transitionCount: transitionCount,
            textSlotCount: textSlots.filter { $0.role != .watermark }.count
        )

        return EditRecipe(
            id: ids.uuid("recipe"),
            title: title,
            createdAt: createdAt,
            source: analysis.source,
            canvas: outputCanvas,
            duration: analysis.source.duration,
            beatGrid: beatGrid,
            scenes: scenes,
            textSlots: textSlots,
            audio: audioPlan,
            palette: analysis.palette,
            stats: stats,
            confidence: rollUpConfidence(scenes: scenes, textSlots: textSlots, audio: analysis.audio)
        )
    }

    /// Output canvas defaults to a 9:16 Reel unless the reference is clearly something else.
    /// A landscape reference bound to a portrait canvas would crop away most of every shot.
    private static func canvas(for source: SourceInfo) -> CanvasSpec {
        let fps = source.fps >= 50 ? 60 : 30
        switch source.aspect {
        case .square1x1:
            return CanvasSpec(width: 1080, height: 1080, fps: fps)
        case .landscape16x9:
            return CanvasSpec(width: 1920, height: 1080, fps: fps)
        case .portrait4x5:
            return CanvasSpec(width: 1080, height: 1350, fps: fps)
        case .portrait9x16, .other:
            return CanvasSpec(width: 1080, height: 1920, fps: fps)
        }
    }

    // MARK: - Scenes

    private func compileScene(
        shot: DetectedShot,
        index: Int,
        role: Confident<SceneRole>,
        palette: ScenePalette?,
        referencePalette: Palette,
        ids: DeterministicID
    ) -> SceneTemplate {
        let slotID = ids.string("asset", index + 1)

        let framing: Confident<ShotFraming> = {
            guard let fraction = shot.salientAreaFraction else {
                return Confident(
                    .medium, confidence: 0.30,
                    basis: "no salient region detected — defaulted"
                )
            }
            return Confident(
                ShotFraming(salientAreaFraction: fraction),
                confidence: 0.72,
                basis: String(format: "salient area %.2f of frame", fraction)
            )
        }()

        let move = compileCameraMove(shot.motion)

        // A shot with real motion energy was probably video in the reference; a static one was
        // probably a still. A preference for the binder, not a constraint.
        let sourceKind: SourceKind = {
            guard shot.motion != nil else { return .unknown }
            return shot.motionEnergy > 0.12 ? .video : .image
        }()

        let transition: TransitionTemplate? = index == 0
            ? nil
            : compileTransition(shot.boundaryIn)

        let grade: ColorGrade? = palette.map { scenePalette in
            ColorGrade(
                exposure: 0,
                contrast: min(1.2, max(0.9, scenePalette.contrast)),
                saturation: min(1.25, max(0.85, scenePalette.saturation / max(0.01, referencePalette.meanSaturation))),
                temperature: 0
            )
        }

        return SceneTemplate(
            id: ids.string("scene", index + 1),
            index: index,
            start: shot.start,
            end: shot.end,
            sourceKind: sourceKind,
            role: role,
            slot: AssetSlot(
                id: slotID,
                framing: framing,
                motionEnergy: shot.motionEnergy
            ),
            move: move,
            transitionIn: transition,
            effects: [],
            grade: grade
        )
    }

    /// Converts a fitted motion into a pair of crop rects.
    ///
    /// The recipe stores rects rather than "zoom 1.17x" so the binder can re-anchor the move on
    /// the user's photo. The conversion inverts the measurement: if the reference's *content*
    /// grew by 1.17x, the *crop* must shrink to 1/1.17, because a smaller crop rect is a
    /// tighter shot.
    private func compileCameraMove(_ motion: FittedMotion?) -> CameraMove {
        guard let motion, motion.sampleCount > 0 else {
            return CameraMove.still
        }

        let kind = motion.kind
        let confidence = motion.confidence
        let basis = motion.basis

        switch kind {
        case .none:
            return CameraMove(
                kind: Confident(.none, confidence: confidence, basis: basis),
                startRect: .full, endRect: .full, easing: .linear, safeFallback: .none
            )

        case .zoomIn, .zoomOut:
            // Clamp: a measured 3x zoom is a fit failure, and applying it to a photo would
            // magnify a handful of pixels to full screen.
            let cropRatio = min(1.6, max(0.62, 1 / motion.scale))
            let (start, end): (NormalizedRect, NormalizedRect) = kind == .zoomIn
                ? (.full, NormalizedRect.full.scaled(by: cropRatio))
                : (NormalizedRect.full.scaled(by: min(1.0, cropRatio)), .full)
            return CameraMove(
                kind: Confident(kind, confidence: confidence, basis: basis),
                startRect: start.clampedInsideUnitSquare(),
                endRect: end.clampedInsideUnitSquare(),
                easing: .easeInOut,
                safeFallback: .none
            )

        case .panLeft, .panRight, .panUp, .panDown:
            // Panning needs headroom: crop in slightly so there is somewhere to pan *to*.
            let base = NormalizedRect.full.scaled(by: 0.88)
            let dx = min(0.10, max(-0.10, motion.translationX)) / 2
            let dy = min(0.10, max(-0.10, motion.translationY)) / 2
            return CameraMove(
                kind: Confident(kind, confidence: confidence, basis: basis),
                startRect: base.offset(dx: -dx, dy: -dy).clampedInsideUnitSquare(),
                endRect: base.offset(dx: dx, dy: dy).clampedInsideUnitSquare(),
                easing: .easeInOut,
                safeFallback: .none
            )

        case .rotate, .complex:
            // We can see that something moved but not name it. Rather than apply a rotation we
            // are not sure about, offer a gentle push-in at the measured confidence and let the
            // fallback ladder take it to static if that confidence is too low.
            return CameraMove.gentlePushIn(
                confidence: min(confidence, 0.5),
                basis: basis + " — not a nameable move, substituted gentle push"
            )
        }
    }

    private func compileTransition(_ boundary: DetectedBoundary) -> TransitionTemplate {
        let kind = boundary.transitionKind
        return TransitionTemplate(
            kind: Confident(kind, confidence: boundary.confidence, basis: boundary.basis),
            // Cuts have no duration; gradual transitions are clamped to something sane —
            // a measured 2-second dissolve in a 12-scene reel is a detection failure.
            duration: kind == .cut ? 0 : min(0.8, max(0.12, boundary.duration)),
            direction: nil,
            safeFallback: .cut
        )
    }

    // MARK: - Roles

    /// Infers what each scene is *for*, from position, duration and shot scale.
    ///
    /// Rule-based and deterministic. A vision-language model could describe these in prose,
    /// more slowly and non-deterministically; the questions here are structural, and structure
    /// is what heuristics are good at. `IntelligenceProvider.refineSceneRoles` can improve on
    /// this when Apple Intelligence is available, and returns nil when it is not.
    func inferSceneRoles(shots: [DetectedShot]) -> [Confident<SceneRole>] {
        guard !shots.isEmpty else { return [] }
        let count = shots.count
        guard count > 2 else {
            return shots.indices.map { index in
                Confident(
                    index == 0 ? .opening : .closing,
                    confidence: 0.55,
                    basis: "only \(count) scenes"
                )
            }
        }

        let durations = shots.map(\.duration)
        let meanDuration = durations.reduce(0, +) / Double(count)

        // The hero is the longest shot that is not the opening or the closing — the one the
        // edit lingers on.
        let interiorRange = 1..<(count - 1)
        let heroIndex = interiorRange.max { durations[$0] < durations[$1] }

        return shots.enumerated().map { index, shot in
            if index == 0 {
                return Confident(
                    .opening, confidence: 0.86,
                    basis: "first scene, \(String(format: "%.2f", shot.duration))s"
                )
            }
            if index == count - 1 {
                return Confident(
                    .closing, confidence: 0.86,
                    basis: "last scene, \(String(format: "%.2f", shot.duration))s"
                )
            }
            if index == heroIndex, shot.duration > meanDuration * 1.4 {
                return Confident(
                    .hero, confidence: 0.71,
                    basis: String(
                        format: "longest interior scene, %.2fs vs %.2fs mean",
                        shot.duration, meanDuration
                    )
                )
            }
            if let fraction = shot.salientAreaFraction {
                if fraction >= 0.45 {
                    return Confident(
                        .detail, confidence: 0.66,
                        basis: String(format: "tight framing, salient area %.2f", fraction)
                    )
                }
                if fraction < 0.18 {
                    return Confident(
                        .wide, confidence: 0.66,
                        basis: String(format: "loose framing, salient area %.2f", fraction)
                    )
                }
            }
            return Confident(
                .body, confidence: 0.58,
                basis: "interior scene, no distinguishing framing"
            )
        }
    }

    // MARK: - Text

    private static let ctaKeywords = [
        "dm", "order", "shop", "buy", "book", "call", "link", "swipe",
        "get yours", "available", "message", "whatsapp", "enquire", "visit",
    ]

    private func compileTextSlots(
        _ tracks: [DetectedTextTrack], ids: DeterministicID
    ) -> [TextSlotTemplate] {
        // Watermarks are dropped here, permanently. They never become slots, so there is no
        // later stage at which somebody's handle could be reintroduced.
        let usable = tracks.filter { !$0.isLikelyWatermark }
        guard !usable.isEmpty else { return [] }

        let largestSize = usable.map(\.sizeRatio).max() ?? 0

        return usable.enumerated().map { index, track in
            let role = inferTextRole(
                track: track, index: index, total: usable.count, largestSize: largestSize
            )

            let category = inferFontCategory(track)
            let animation = inferTextAnimation(track)

            return TextSlotTemplate(
                id: ids.string("text", index + 1),
                role: role,
                start: track.start,
                end: track.end,
                frame: track.frame,
                alignment: alignment(for: track.frame),
                style: TextStyleTemplate(
                    category: category,
                    sizeRatio: track.sizeRatio,
                    colorHex: track.colorHex,
                    shadow: Confident(
                        true, confidence: 0.40,
                        basis: "not measured — defaulted on for legibility"
                    )
                ),
                animation: animation,
                // Hint only. Never bound into output — see RecipeBinder.buildTextLayers.
                sampleText: track.text,
                charCountHint: track.text.count
            )
        }
    }

    private func inferTextRole(
        track: DetectedTextTrack, index: Int, total: Int, largestSize: Double
    ) -> TextRole {
        let lowered = track.text.lowercased()
        if Self.ctaKeywords.contains(where: { lowered.contains($0) }) { return .cta }
        if index == 0, track.sizeRatio >= largestSize * 0.85 { return .title }
        if index == total - 1, total > 1 { return .cta }
        if track.sizeRatio >= largestSize * 0.7 { return .subtitle }
        return .caption
    }

    private func alignment(for frame: NormalizedRect) -> TextAlignment {
        switch frame.centerX {
        case ..<0.38: return .leading
        case 0.62...: return .trailing
        default: return .center
        }
    }

    /// Font category from bounding-box geometry alone.
    ///
    /// Deliberately reported at low confidence. Identifying a typeface from a 1080p frame is
    /// not solvable, and the honest output is a category with a caveat, not a family name. The
    /// only genuinely reliable signal available here is *proportion*: a box that is tall
    /// relative to its per-character width is a condensed face; a very tall box is display
    /// weight. Serif detection would need stroke-terminal analysis at a resolution the
    /// reference does not have.
    private func inferFontCategory(_ track: DetectedTextTrack) -> Confident<FontCategory> {
        let characterCount = max(1, track.text.count)
        let widthPerCharacter = track.frame.width / Double(characterCount)
        let ratio = track.frame.height > 0 ? widthPerCharacter / track.frame.height : 0.5

        if ratio < 0.34 {
            return Confident(
                .condensed, confidence: 0.46,
                basis: String(format: "width/char %.2f of cap height — narrow", ratio)
            )
        }
        if track.sizeRatio > 0.075 {
            return Confident(
                .displayBold, confidence: 0.44,
                basis: String(format: "cap height %.3f of frame — display scale", track.sizeRatio)
            )
        }
        return Confident(
            .sansSerif, confidence: 0.38,
            basis: "no distinguishing proportion — defaulted (serif detection not possible at this resolution)"
        )
    }

    private func inferTextAnimation(_ track: DetectedTextTrack) -> TextAnimation {
        let entry: Confident<TextEntryAnimation>
        if track.entryExtentGrowth >= 2 {
            entry = Confident(
                .wordByWord, confidence: 0.62,
                basis: "\(track.entryExtentGrowth) monotonic width increases during entry"
            )
        } else if track.observationCount >= 4 {
            entry = Confident(
                .fadeIn, confidence: 0.44,
                basis: "stable extent from first sighting — no reveal detected"
            )
        } else {
            entry = Confident(
                .fadeIn, confidence: 0.30,
                basis: "too few observations to characterise entry"
            )
        }

        return TextAnimation(
            entry: entry,
            exit: Confident(
                .fadeOut, confidence: 0.35,
                basis: "not measured — OCR cannot see a fade below its confidence floor"
            )
        )
    }

    // MARK: - Audio

    private func compileBeatGrid(_ audio: AudioAnalysis?, shots: [DetectedShot]) -> BeatGrid? {
        guard let audio, !audio.beats.isEmpty else { return nil }

        // Do the reference's own cuts land on this grid? If they do, quantising the user's edit
        // to beats reproduces the feel. If they don't, quantising would *impose* a rhythm the
        // reference never had, so the recipe keeps literal timings instead.
        let cutTimes = shots.dropFirst().map(\.start)
        let tolerance = 0.08
        let aligned = cutTimes.filter { cut in
            audio.beats.contains { abs($0 - cut) <= tolerance }
        }.count

        let ratio = cutTimes.isEmpty ? 0 : Double(aligned) / Double(cutTimes.count)
        let alignedEnough = ratio >= 0.5

        return BeatGrid(
            bpm: Confident(audio.bpm, confidence: audio.bpmConfidence, basis: audio.bpmBasis),
            beats: audio.beats,
            downbeats: audio.downbeats,
            cutsAlignedToBeats: Confident(
                alignedEnough,
                confidence: cutTimes.isEmpty ? 0.2 : min(0.9, 0.5 + abs(ratio - 0.5)),
                basis: "\(aligned)/\(cutTimes.count) cuts within \(Int(tolerance * 1000))ms of a beat"
            )
        )
    }

    private func compileAudioPlan(_ audio: AudioAnalysis?, beatGrid: BeatGrid?) -> AudioPlan {
        guard let audio else { return .silent }
        return AudioPlan(
            hasMusic: !audio.beats.isEmpty && audio.bpmConfidence > 0.3,
            hasSpeech: Confident(
                audio.hasSpeech, confidence: audio.speechConfidence, basis: audio.speechBasis
            ),
            energyCurve: audio.energyCurve,
            suggestedCutStyle: (beatGrid?.cutsAlignedToBeats.value ?? false) ? .onBeat : .literal
        )
    }

    // MARK: - Confidence

    private func rollUpConfidence(
        scenes: [SceneTemplate], textSlots: [TextSlotTemplate], audio: AudioAnalysis?
    ) -> ConfidenceReport {
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0.5 : values.reduce(0, +) / Double(values.count)
        }

        let sceneConfidence = mean(
            scenes.compactMap { $0.transitionIn?.kind.confidence } + scenes.map(\.role.confidence)
        )
        let motionConfidence = mean(scenes.map(\.move.kind.confidence))
        let textConfidence = textSlots.isEmpty
            ? 1.0  // No text slots is not low confidence — it is a confident absence.
            : mean(textSlots.map(\.style.category.confidence))
        let audioConfidence = audio.map(\.bpmConfidence) ?? 1.0

        return ConfidenceReport.rollUp(
            scenes: sceneConfidence,
            motion: motionConfidence,
            text: textConfidence,
            audio: audioConfidence
        )
    }
}
