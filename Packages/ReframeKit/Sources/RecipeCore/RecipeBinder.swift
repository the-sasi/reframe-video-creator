import Foundation

/// How much of the reference to reproduce. The three modes the product offers after analysis.
public enum BindingFidelity: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Timing, transitions, camera moves, text layout, beat grid, composition. Everything.
    case closeMatch
    /// Pacing, transitions, motion and rhythm — but none of the reference's text layout. The
    /// user's words are added freely in the editor rather than poured into the reference's slots.
    case styleOnly
    /// Only the skeleton: scene count and durations. Cuts everywhere, no motion, no text, no
    /// grade. A blank canvas with the reference's rhythm.
    case structureOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .closeMatch: return "Close Match"
        case .styleOnly: return "Use Style"
        case .structureOnly: return "Use Structure"
        }
    }

    public var summary: String {
        switch self {
        case .closeMatch:
            return "Timing, transitions, camera moves, text placement and rhythm — as close to the reference as your content allows."
        case .styleOnly:
            return "Pacing, transitions, motion and beat — but your own text, placed your way."
        case .structureOnly:
            return "Just the cut structure: same number of scenes, same lengths. Everything else is yours to add."
        }
    }

    var bindsTextSlots: Bool { self == .closeMatch }
    var bindsMoves: Bool { self != .structureOnly }
    var bindsTransitions: Bool { self != .structureOnly }
    var bindsGrade: Bool { self != .structureOnly }
}

/// Turns a style into a document: `EditRecipe` + assets + words -> `Timeline`.
///
/// This is where confidence gating actually bites. Low-confidence inferences are replaced by
/// their declared `safeFallback` here, once, rather than being re-decided at every render.
///
/// It is also where *composition transfer* happens: the reference recorded where its subject
/// sat in the frame, the asset features say where the user's subject sits, and the crop is
/// solved so the two coincide. A landscape photo bound into a 9:16 slot is cropped around its
/// subject, not around its centre.
public struct RecipeBinder: Sendable {

    public struct Options: Sendable {
        /// Override the recipe's canvas — re-target a 9:16 style to 1:1, say.
        public var canvas: CanvasSpec?
        /// Quantise scene boundaries to the beat grid when the recipe suggests it.
        public var respectBeatGrid: Bool
        /// Allow an asset to fill more than one slot when there are fewer assets than slots.
        public var allowAssetReuse: Bool
        /// Apply the reference's inferred colour grade to the user's assets.
        public var applyGrade: Bool
        public var fidelity: BindingFidelity
        /// Where each user asset's subject sits, from `AssetFeatures.salientRect`. Drives the
        /// smart crop. Assets missing from this map fall back to a centred, slightly top-biased
        /// crop.
        public var subjectRects: [UUID: NormalizedRect]

        public init(
            canvas: CanvasSpec? = nil,
            respectBeatGrid: Bool = true,
            allowAssetReuse: Bool = true,
            applyGrade: Bool = false,
            fidelity: BindingFidelity = .closeMatch,
            subjectRects: [UUID: NormalizedRect] = [:]
        ) {
            self.canvas = canvas
            self.respectBeatGrid = respectBeatGrid
            self.allowAssetReuse = allowAssetReuse
            self.applyGrade = applyGrade
            self.fidelity = fidelity
            self.subjectRects = subjectRects
        }

        public static let `default` = Options()
    }

    public init() {}

    public func bind(
        recipe: EditRecipe,
        assets: AssetPool,
        assignment: AssetAssignment,
        content: UserContent,
        options: Options = .default
    ) -> Timeline {
        let canvas = options.canvas ?? recipe.canvas
        let ids = DeterministicID(seed: recipe.source.fingerprint)

        var timeline = Timeline(
            id: ids.uuid("timeline"),
            canvas: canvas,
            recipeID: recipe.id
        )

        timeline.clips = buildClips(
            recipe: recipe, assets: assets, assignment: assignment,
            canvas: canvas, options: options, content: content, ids: ids
        )
        if options.fidelity.bindsTextSlots {
            timeline.textLayers = buildTextLayers(
                recipe: recipe, content: content, canvas: canvas, ids: ids
            )
        }
        if let logoID = content.logoAssetID {
            timeline.overlays = [buildLogoOverlay(assetID: logoID, recipe: recipe, ids: ids)]
        }
        timeline.audio = buildAudio(content: content, assets: assets, recipe: recipe, ids: ids)

        timeline.relayout()
        return timeline
    }

    // MARK: - Clips

    private func buildClips(
        recipe: EditRecipe,
        assets: AssetPool,
        assignment: AssetAssignment,
        canvas: CanvasSpec,
        options: Options,
        content: UserContent,
        ids: DeterministicID
    ) -> [VideoClip] {
        let durations = sceneDurations(recipe: recipe, canvas: canvas, options: options)

        return recipe.scenes.enumerated().map { index, scene in
            let assetID = assignment[scene.slot.id]
            let asset = assetID.flatMap { assets[$0] }
            let duration = durations[index]

            let (cropStart, cropEnd) = resolveCrop(
                scene: scene, asset: asset, canvas: canvas,
                subjectRect: assetID.flatMap { options.subjectRects[$0] },
                bindsMoves: options.fidelity.bindsMoves
            )

            let transition: Transition? = options.fidelity.bindsTransitions
                ? scene.transitionIn.map(Transition.init(template:))
                : nil

            // A video asset in a slot plays from its own start, trimmed to the slot duration.
            let sourceStart: Double = {
                guard let asset, asset.kind == .video else { return 0 }
                // Skip the first beat of a clip — the first frames of user footage are
                // routinely the worst ones. Never skip so much the clip cannot fill its slot.
                return min(0.25, max(0, asset.duration - duration))
            }()

            let grade: ColorGrade = (options.applyGrade && options.fidelity.bindsGrade)
                ? (scene.grade ?? .neutral)
                : .neutral

            return VideoClip(
                id: ids.uuid("clip/\(scene.id)"),
                assetID: assetID,
                slotID: scene.slot.id,
                start: scene.start,
                duration: duration,
                sourceStart: sourceStart,
                cropStart: cropStart,
                cropEnd: cropEnd,
                easing: scene.move.easing,
                transitionIn: index == 0 ? nil : transition,
                grade: grade,
                speed: 1.0,
                opacity: 1.0,
                // Reference audio never reaches the output through a clip. User video keeps its
                // own sound at the level the content screen chose — muted by default, so the
                // music bed is clean; the editor can raise it per clip.
                volume: asset?.kind == .video ? content.clipAudioVolume : 0
            )
        }
    }

    /// Scene durations, optionally quantised to the beat grid.
    ///
    /// Quantised *cumulatively*: each boundary snaps to its nearest beat, monotonicity is
    /// enforced, and durations are the differences. Snapping each scene's own start and end
    /// independently — which is what an earlier version did — let rounding accumulate across
    /// the timeline, so a 12-scene reel drifted a beat and a half from the reference by its end.
    private func sceneDurations(recipe: EditRecipe, canvas: CanvasSpec, options: Options) -> [Double] {
        let scenes = recipe.scenes
        guard !scenes.isEmpty else { return [] }
        let minimum = canvas.frameDuration * 2

        var boundaries: [Double] = [scenes[0].start] + scenes.map(\.end)

        if options.respectBeatGrid,
           recipe.audio.suggestedCutStyle == .onBeat,
           let grid = recipe.beatGrid,
           grid.cutsAlignedToBeats.value {
            for i in 1..<boundaries.count {
                if let snapped = grid.nearestBeat(to: boundaries[i]),
                   snapped > boundaries[i - 1] + minimum {
                    boundaries[i] = snapped
                }
            }
        }

        // Frame-align and enforce monotonicity, so no scene collapses below two frames.
        var durations: [Double] = []
        for i in 1..<boundaries.count {
            let raw = boundaries[i] - boundaries[i - 1]
            durations.append(max(minimum, canvas.snapToFrame(raw)))
        }
        return durations
    }

    /// Re-anchors the reference's camera move onto the user's asset, around its subject.
    ///
    /// The recipe stores *rects*, not "zoom 1.17x", precisely so this can happen: we keep the
    /// reference's motion shape and magnitude, solve the aspect-fill window so the user's subject
    /// lands where the reference's subject was, and compose the move inside that window.
    func resolveCrop(
        scene: SceneTemplate,
        asset: AssetReference?,
        canvas: CanvasSpec,
        subjectRect: NormalizedRect?,
        bindsMoves: Bool
    ) -> (NormalizedRect, NormalizedRect) {
        let move = scene.move

        // Confidence gate: an untrusted move degrades to its declared fallback.
        let effective = bindsMoves ? move.effectiveKind : .none
        let (rawStart, rawEnd): (NormalizedRect, NormalizedRect) = {
            if effective == .none {
                return (.full, .full)
            }
            if move.kind.isTrustworthy {
                return (move.startRect, move.endRect)
            }
            // Fallback kind differs from the detected one: synthesise a plain move.
            switch effective {
            case .zoomIn: return (.full, NormalizedRect.full.scaled(by: 0.90))
            case .zoomOut: return (NormalizedRect.full.scaled(by: 0.90), .full)
            default: return (.full, .full)
            }
        }()

        guard let asset else { return (rawStart, rawEnd) }

        let window = Self.fillWindow(
            sourceAspect: asset.aspectRatio,
            targetAspect: canvas.aspectRatio,
            subject: subjectRect,
            referenceSubject: scene.slot.subjectRect,
            framing: scene.slot.framing
        )

        // Compose the reference's move inside the window.
        func compose(_ move: NormalizedRect) -> NormalizedRect {
            NormalizedRect(
                x: window.x + move.x * window.width,
                y: window.y + move.y * window.height,
                width: window.width * move.width,
                height: window.height * move.height
            ).clampedInsideUnitSquare()
        }

        return (compose(rawStart), compose(rawEnd))
    }

    /// The region of the source that fills the canvas, positioned around the subject.
    ///
    /// Three inputs, in order of authority:
    /// 1. **The user's subject.** If saliency found one, the window is placed so its centre
    ///    lands where the reference's subject centre was (or at a natural upper-centre point
    ///    when the reference did not say).
    /// 2. **The slot's framing.** A close-up slot given a wide photo is tightened around the
    ///    subject, so a "detail" scene reads as a detail rather than a shrunken wide.
    /// 3. **The default.** No subject known: centred horizontally, biased upward vertically —
    ///    subjects sit above centre far more often than below, and a centred crop on a portrait
    ///    photo decapitates people.
    public static func fillWindow(
        sourceAspect: Double,
        targetAspect: Double,
        subject: NormalizedRect?,
        referenceSubject: Confident<NormalizedRect>?,
        framing: Confident<ShotFraming>
    ) -> NormalizedRect {
        // Aspect-fill: the largest sub-rect of the source with the canvas's aspect.
        var window = NormalizedRect.full
        if sourceAspect > targetAspect + 1e-6 {
            window = NormalizedRect(x: 0, y: 0, width: targetAspect / sourceAspect, height: 1)
        } else if sourceAspect < targetAspect - 1e-6 {
            window = NormalizedRect(x: 0, y: 0, width: 1, height: sourceAspect / targetAspect)
        }

        // Where the subject should land in the canvas.
        let anchor: (x: Double, y: Double) = {
            if let reference = referenceSubject, reference.confidence >= 0.4 {
                return (reference.value.centerX, reference.value.centerY)
            }
            return (0.5, 0.42)
        }()

        guard let subject else {
            // No subject: centre horizontally, bias upward.
            window.x = (1 - window.width) / 2
            window.y = (1 - window.height) * 0.35
            return window.clampedInsideUnitSquare()
        }

        // Tighten for framing. The subject's share of the *window* is what the viewer sees.
        if framing.isTrustworthy {
            let desired: Double? = {
                switch framing.value {
                case .closeUp: return 0.50
                case .medium: return 0.28
                case .wide: return nil
                }
            }()
            if let desired {
                let subjectShare = subject.area / max(window.area, 1e-6)
                if subjectShare < desired * 0.6 {
                    // Never tighter than the subject itself, never below 62% of the window —
                    // beyond that a photo is being magnified past what it can bear.
                    let byArea = (subjectShare / desired).squareRoot()
                    let bySubject = max(
                        subject.width / max(window.width, 1e-6),
                        subject.height / max(window.height, 1e-6)
                    )
                    let factor = min(1, max(0.62, byArea, bySubject))
                    window = window.scaled(by: factor)
                }
            }
        }

        // Place the window so the subject centre maps to the anchor.
        window.x = subject.centerX - anchor.x * window.width
        window.y = subject.centerY - anchor.y * window.height
        return window.clampedInsideUnitSquare()
    }

    // MARK: - Text

    /// Builds text layers **only** from the user's words.
    ///
    /// `TextSlotTemplate.sampleText` is not read here, and there is no code path in this type
    /// that reads it. A slot with no user text produces no layer — an empty slot stays empty
    /// rather than being filled with the reference's copy. See docs/02-licensing.md.
    private func buildTextLayers(
        recipe: EditRecipe,
        content: UserContent,
        canvas: CanvasSpec,
        ids: DeterministicID
    ) -> [TextLayer] {
        recipe.fillableTextSlots.compactMap { slot in
            guard let userText = content.text(for: slot.id) else { return nil }

            return TextLayer(
                id: ids.uuid("text/\(slot.id)"),
                slotID: slot.id,
                text: userText,
                role: slot.role,
                start: canvas.snapToFrame(slot.start),
                end: canvas.snapToFrame(slot.end),
                frame: slot.frame,
                alignment: slot.alignment,
                fontCategory: slot.style.category.isTrustworthy
                    ? slot.style.category.value
                    : .sansSerif,  // §37: approximate typography rather than fail
                weight: slot.style.category.value == .displayBold ? .heavy : .bold,
                sizeRatio: fitSizeRatio(
                    slot: slot, text: userText, canvas: canvas
                ),
                colorHex: slot.style.colorHex,
                hasShadow: slot.style.shadow?.value ?? true,
                outline: (slot.style.outline?.value ?? false) ? TextOutline() : nil,
                entry: slot.animation.effectiveEntry,
                exit: slot.animation.effectiveExit
            )
        }
    }

    /// The reference's text and the user's text are rarely the same length. Rather than let a
    /// long product name overflow its box, scale the size down by the length ratio — bounded,
    /// so it never becomes unreadably small.
    private func fitSizeRatio(slot: TextSlotTemplate, text: String, canvas: CanvasSpec) -> Double {
        let base = slot.style.sizeRatio
        guard slot.charCountHint > 0 else { return base }
        let ratio = Double(slot.charCountHint) / Double(max(text.count, 1))
        return base * min(max(ratio, 0.6), 1.15)
    }

    // MARK: - Overlays & audio

    private func buildLogoOverlay(
        assetID: UUID, recipe: EditRecipe, ids: DeterministicID
    ) -> OverlayLayer {
        // Bottom-centre, above the safe area, small. The unopinionated default — the user
        // drags it wherever they want and that becomes an undoable command.
        OverlayLayer(
            id: ids.uuid("overlay/logo"),
            assetID: assetID,
            start: 0,
            end: recipe.duration,
            frame: NormalizedRect(x: 0.36, y: 0.855, width: 0.28, height: 0.075),
            opacity: 0.92
        )
    }

    /// Music, voiceover and (if the user chose to keep it) the reference's own soundtrack.
    /// Each is one `AudioClip` with a role; the mix planner decides how they interact.
    private func buildAudio(
        content: UserContent, assets: AssetPool, recipe: EditRecipe, ids: DeterministicID
    ) -> [AudioClip] {
        var clips: [AudioClip] = []
        let duration = recipe.duration

        if let musicID = content.musicAssetID {
            let trackDuration = assets[musicID]?.duration ?? duration
            clips.append(
                AudioClip(
                    id: ids.uuid("audio/music"),
                    assetID: musicID,
                    start: 0,
                    duration: trackDuration > 0 ? min(duration, trackDuration) : duration,
                    sourceStart: 0,
                    volume: 1.0,
                    fadeIn: 0.15,
                    fadeOut: min(0.8, duration * 0.1),
                    role: .music
                )
            )
        }
        if let referenceID = content.referenceAudioAssetID {
            let trackDuration = assets[referenceID]?.duration ?? duration
            clips.append(
                AudioClip(
                    id: ids.uuid("audio/reference"),
                    assetID: referenceID,
                    start: 0,
                    duration: trackDuration > 0 ? min(duration, trackDuration) : duration,
                    sourceStart: 0,
                    volume: content.musicAssetID == nil ? 1.0 : 0.5,
                    fadeIn: 0.05,
                    fadeOut: min(0.6, duration * 0.08),
                    role: .reference
                )
            )
        }
        if let voiceID = content.voiceoverAssetID {
            let trackDuration = assets[voiceID]?.duration ?? duration
            clips.append(
                AudioClip(
                    id: ids.uuid("audio/voice"),
                    assetID: voiceID,
                    start: 0,
                    duration: trackDuration > 0 ? min(duration, trackDuration) : duration,
                    sourceStart: 0,
                    volume: 1.0,
                    fadeIn: 0.02,
                    fadeOut: 0.05,
                    role: .voice
                )
            )
        }
        return clips
    }
}
