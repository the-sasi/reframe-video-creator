import Foundation
import RecipeCore

/// `(Timeline, time) -> RenderPlan`. Pure, deterministic, GPU-free.
///
/// This is the most-tested type in the engine, because it is where every timing decision lives
/// and because testing it needs nothing but arithmetic.
public struct RenderPlanner: Sendable {

    public init() {}

    public func plan(_ timeline: Timeline, at time: Double) -> RenderPlan {
        let stage = planStage(timeline, at: time)
        let overlays = planOverlays(timeline, at: time)

        return RenderPlan(
            canvas: timeline.canvas,
            time: time,
            background: SIMD4<Float>(0, 0, 0, 1),
            stage: stage,
            overlays: overlays
        )
    }

    // MARK: - Visual stage

    private func planStage(_ timeline: Timeline, at time: Double) -> RenderPlan.Stage {
        guard let index = activeClipIndex(timeline, at: time) else {
            return .single([])
        }
        let clip = timeline.clips[index]

        // A transition is centred on the boundary: half before, half after. Both clips render
        // slightly outside their own time range during the overlap, which is why layer
        // construction clamps local time rather than assuming it is in bounds.
        if let transition = clip.transitionIn,
           transition.kind != .cut,
           transition.duration > 0,
           index > 0 {
            let half = transition.duration / 2
            let windowStart = clip.start - half
            let windowEnd = clip.start + half
            if time >= windowStart, time < windowEnd {
                let progress = (time - windowStart) / transition.duration
                return .transition(
                    RenderPlan.TransitionStage(
                        from: layers(for: timeline.clips[index - 1], timeline: timeline, at: time),
                        to: layers(for: clip, timeline: timeline, at: time),
                        kind: transition.kind,
                        direction: transition.direction,
                        progress: min(max(progress, 0), 1)
                    )
                )
            }
        }

        // Also check the *next* clip: at a time still inside this clip, we may already be in the
        // first half of the next clip's incoming transition.
        if index + 1 < timeline.clips.count {
            let next = timeline.clips[index + 1]
            if let transition = next.transitionIn,
               transition.kind != .cut,
               transition.duration > 0 {
                let half = transition.duration / 2
                let windowStart = next.start - half
                if time >= windowStart {
                    let progress = (time - windowStart) / transition.duration
                    return .transition(
                        RenderPlan.TransitionStage(
                            from: layers(for: clip, timeline: timeline, at: time),
                            to: layers(for: next, timeline: timeline, at: time),
                            kind: transition.kind,
                            direction: transition.direction,
                            progress: min(max(progress, 0), 1)
                        )
                    )
                }
            }
        }

        return .single(layers(for: clip, timeline: timeline, at: time))
    }

    /// The clip whose time range contains `time`, tolerating the transition overlap at either
    /// end so a lookup one frame past the last clip still resolves.
    private func activeClipIndex(_ timeline: Timeline, at time: Double) -> Int? {
        guard !timeline.clips.isEmpty else { return nil }
        if let index = timeline.clips.firstIndex(where: { time >= $0.start && time < $0.end }) {
            return index
        }
        if time < timeline.clips[0].start { return 0 }
        if time >= timeline.clips[timeline.clips.count - 1].end { return timeline.clips.count - 1 }
        return nil
    }

    private func layers(
        for clip: VideoClip, timeline: Timeline, at time: Double
    ) -> [RenderPlan.PlanLayer] {
        // Clamp: during a transition a clip is asked to render outside its own range. A still
        // simply holds its final Ken Burns position; a video holds its last frame.
        let localTime = min(max(time - clip.start, 0), clip.duration)

        guard let assetID = clip.assetID else {
            return [
                RenderPlan.PlanLayer(
                    content: .placeholder(label: "Add a photo"),
                    opacity: clip.opacity
                )
            ]
        }

        return [
            RenderPlan.PlanLayer(
                content: .asset(
                    id: assetID,
                    sourceTime: clip.sourceTime(atLocalTime: localTime)
                ),
                sourceCrop: clip.crop(atLocalTime: localTime),
                destination: .full,
                opacity: clip.opacity,
                grade: clip.grade,
                vignette: clip.vignette,
                grain: clip.grain
            )
        ]
    }

    // MARK: - Overlays

    private func planOverlays(_ timeline: Timeline, at time: Double) -> [RenderPlan.PlanLayer] {
        var layers: [RenderPlan.PlanLayer] = []

        // Logo below text: if they collide, the words stay readable.
        for overlay in timeline.overlays where overlay.isVisible(at: time) {
            layers.append(
                RenderPlan.PlanLayer(
                    content: .asset(id: overlay.assetID, sourceTime: 0),
                    sourceCrop: .full,
                    destination: overlay.frame,
                    opacity: overlay.opacity
                )
            )
        }

        for layer in timeline.textLayers where layer.isVisible(at: time) {
            if let draw = textDraw(for: layer, at: time) {
                layers.append(
                    RenderPlan.PlanLayer(
                        content: .text(draw),
                        destination: layer.frame,
                        opacity: 1  // per-word opacity lives inside the draw
                    )
                )
            }
        }

        return layers
    }

    /// Resolves a text layer's animation state into per-word alpha, offset and scale.
    func textDraw(for layer: TextLayer, at time: Double) -> TextDraw? {
        let words = layer.text
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !words.isEmpty else { return nil }

        let local = time - layer.start
        let remaining = layer.end - time
        let entryDuration = layer.entry.duration
        let exitDuration = layer.exit.duration

        // Exit applies uniformly across words — a staggered exit reads as a glitch, where a
        // staggered entry reads as choreography.
        var exitAlpha = 1.0
        if exitDuration > 0, layer.exit != .none, remaining < exitDuration {
            exitAlpha = max(0, remaining / exitDuration)
        }
        var exitOffset = 0.0
        var exitScale = 1.0
        switch layer.exit {
        case .slideDown where remaining < exitDuration:
            exitOffset = (1 - exitAlpha) * 0.05
        case .popOut where remaining < exitDuration:
            exitScale = 0.85 + exitAlpha * 0.15
        default:
            break
        }

        let drawWords: [TextDraw.Word] = words.enumerated().map { index, word in
            var alpha = 1.0
            var offsetY = 0.0
            var scale = 1.0

            switch layer.entry {
            case .none:
                break

            case .fadeIn:
                if entryDuration > 0, local < entryDuration {
                    alpha = min(1, max(0, local / entryDuration))
                }

            case .popIn:
                if entryDuration > 0, local < entryDuration {
                    let t = min(1, max(0, local / entryDuration))
                    alpha = t
                    // Overshoot then settle. A linear scale-up reads as a zoom; the overshoot
                    // is what makes it read as a pop.
                    scale = t < 0.7 ? 0.8 + t * 0.35 : 1.06 - (t - 0.7) * 0.2
                }

            case .slideUp, .slideDown:
                if entryDuration > 0, local < entryDuration {
                    let t = Easing.easeOut.apply(min(1, max(0, local / entryDuration)))
                    alpha = t
                    offsetY = (1 - t) * (layer.entry == .slideUp ? 0.06 : -0.06)
                }

            case .wordByWord:
                // Stagger across the entry window, leaving each word a fade of its own.
                let perWord = entryDuration / Double(max(1, words.count))
                let wordStart = Double(index) * perWord
                let fade = max(0.08, perWord * 0.8)
                alpha = min(1, max(0, (local - wordStart) / fade))
                scale = 0.94 + alpha * 0.06

            case .typeOn:
                // Approximated at word granularity. Genuine per-character typing would need
                // per-glyph rasterisation, which is a lot of texture churn for an effect that
                // reads almost identically at 30 fps.
                let perWord = entryDuration / Double(max(1, words.count))
                alpha = local >= Double(index) * perWord ? 1 : 0
            }

            return TextDraw.Word(
                text: word,
                opacity: min(alpha, exitAlpha),
                offsetY: offsetY + exitOffset,
                scale: scale * exitScale
            )
        }

        // Everything invisible: skip the layer entirely rather than issue no-op draws.
        guard drawWords.contains(where: { $0.opacity > 0.001 }) else { return nil }

        return TextDraw(
            layerID: layer.id,
            words: drawWords,
            fontCategory: layer.fontCategory,
            sizeRatio: layer.sizeRatio,
            color: .fromHex(layer.colorHex),
            hasShadow: layer.hasShadow,
            alignment: layer.alignment,
            frame: layer.frame
        )
    }

    // MARK: - Audio

    /// Mixed gain per audio clip at `time`. Preview and export both use this, so a fade heard
    /// in preview is the fade that gets written.
    public func audioGains(_ timeline: Timeline, at time: Double) -> [(clipID: UUID, gain: Double)] {
        timeline.audio
            .filter { time >= $0.start && time < $0.end }
            .map { ($0.id, $0.gain(at: time)) }
    }
}
