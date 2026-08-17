import Foundation

/// Turns a style into a document: `EditRecipe` + assets + words -> `Timeline`.
///
/// This is where confidence gating actually bites. Low-confidence inferences are replaced by
/// their declared `safeFallback` here, once, rather than being re-decided at every render.
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

        public init(
            canvas: CanvasSpec? = nil,
            respectBeatGrid: Bool = true,
            allowAssetReuse: Bool = true,
            applyGrade: Bool = false
        ) {
            self.canvas = canvas
            self.respectBeatGrid = respectBeatGrid
            self.allowAssetReuse = allowAssetReuse
            self.applyGrade = applyGrade
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
            canvas: canvas, options: options, ids: ids
        )
        timeline.textLayers = buildTextLayers(
            recipe: recipe, content: content, canvas: canvas, ids: ids
        )
        if let logoID = content.logoAssetID {
            timeline.overlays = [buildLogoOverlay(assetID: logoID, recipe: recipe, ids: ids)]
        }
        if let musicID = content.musicAssetID {
            timeline.audio = [buildMusicClip(assetID: musicID, recipe: recipe, ids: ids)]
        }

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
        ids: DeterministicID
    ) -> [VideoClip] {
        recipe.scenes.enumerated().map { index, scene in
            let assetID = assignment[scene.slot.id]
            let asset = assetID.flatMap { assets[$0] }

            // Duration may be quantised to the beat grid, but never below one frame.
            var duration = scene.duration
            if options.respectBeatGrid,
               recipe.audio.suggestedCutStyle == .onBeat,
               let grid = recipe.beatGrid,
               grid.cutsAlignedToBeats.value,
               let snappedEnd = grid.nearestBeat(to: scene.end) {
                // The start may or may not have a beat near it; falling back to the literal
                // start keeps the scene anchored rather than dropping the quantisation entirely.
                let snappedStart = grid.nearestBeat(to: scene.start) ?? scene.start
                duration = max(canvas.frameDuration, snappedEnd - snappedStart)
            }
            duration = max(canvas.frameDuration, canvas.snapToFrame(duration))

            let (cropStart, cropEnd) = resolveCrop(
                scene: scene, asset: asset, canvas: canvas
            )

            let transition = scene.transitionIn.map(Transition.init(template:))

            // A video asset in a slot plays from its own start, trimmed to the slot duration.
            let sourceStart: Double = {
                guard let asset, asset.kind == .video else { return 0 }
                // Skip the first beat of a clip — the first frames of user footage are
                // routinely the worst ones.
                let skip = min(0.25, max(0, asset.duration - duration))
                return skip
            }()

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
                grade: options.applyGrade ? (scene.grade ?? .neutral) : .neutral,
                speed: 1.0,
                opacity: 1.0,
                // Reference audio never reaches the output. User video keeps its own sound only
                // if there is no music bed; the binder mutes by default and the editor unmutes.
                volume: 0.0
            )
        }
    }

    /// Re-anchors the reference's camera move onto the user's asset.
    ///
    /// The recipe stores *rects*, not "zoom 1.17x", precisely so this can happen: we keep the
    /// reference's motion shape and magnitude but re-centre it on this asset's aspect ratio, and
    /// we apply the aspect-fill crop the canvas needs. A landscape photo in a 9:16 slot gets a
    /// centred vertical crop, then the reference's push-in on top of that.
    private func resolveCrop(
        scene: SceneTemplate,
        asset: AssetReference?,
        canvas: CanvasSpec
    ) -> (NormalizedRect, NormalizedRect) {
        let move = scene.move

        // Confidence gate: an untrusted move degrades to its declared fallback.
        let effective = move.effectiveKind
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

        // Aspect-fill: the largest sub-rect of the source with the canvas's aspect ratio.
        let sourceAspect = asset.aspectRatio
        let targetAspect = canvas.aspectRatio
        var fill = NormalizedRect.full
        if sourceAspect > targetAspect {
            // Source is wider: crop horizontally.
            let w = targetAspect / sourceAspect
            fill = NormalizedRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else if sourceAspect < targetAspect {
            // Source is taller: crop vertically. Bias upward — subjects sit above centre far
            // more often than below, and a centred crop on a portrait photo decapitates people.
            let h = sourceAspect / targetAspect
            fill = NormalizedRect(x: 0, y: (1 - h) * 0.35, width: 1, height: h)
        }

        // Compose the reference's move inside the fill rect.
        func compose(_ move: NormalizedRect) -> NormalizedRect {
            NormalizedRect(
                x: fill.x + move.x * fill.width,
                y: fill.y + move.y * fill.height,
                width: fill.width * move.width,
                height: fill.height * move.height
            ).clampedInsideUnitSquare()
        }

        return (compose(rawStart), compose(rawEnd))
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
                sizeRatio: fitSizeRatio(
                    slot: slot, text: userText, canvas: canvas
                ),
                colorHex: slot.style.colorHex,
                hasShadow: slot.style.shadow?.value ?? true,
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

    private func buildMusicClip(
        assetID: UUID, recipe: EditRecipe, ids: DeterministicID
    ) -> AudioClip {
        AudioClip(
            id: ids.uuid("audio/music"),
            assetID: assetID,
            start: 0,
            duration: recipe.duration,
            sourceStart: 0,
            volume: 1.0,
            fadeIn: 0.15,
            fadeOut: min(0.8, recipe.duration * 0.1)
        )
    }
}
