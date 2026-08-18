import Foundation

/// The concrete, editable document: an `EditRecipe` bound to real assets and real words.
///
/// This is the only thing the editor mutates, and it mutates it exclusively through undoable
/// `EditCommand`s. A Codable value type, so snapshotting is copy-on-write cheap and
/// serialisation is free.
public struct Timeline: Codable, Sendable, Hashable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var canvas: CanvasSpec
    /// The recipe this was bound from, if any. Nil for "start from scratch" projects.
    public var recipeID: UUID?

    /// Sequential visual clips. Single visual track by design: multi-track video on a phone
    /// screen is a desktop idea, and transitions handle the only overlap the product needs.
    public var clips: [VideoClip]
    public var textLayers: [TextLayer]
    public var overlays: [OverlayLayer]
    public var audio: [AudioClip]

    public init(
        schemaVersion: Int = RecipeSchema.current,
        id: UUID = UUID(),
        canvas: CanvasSpec = .reel1080,
        recipeID: UUID? = nil,
        clips: [VideoClip] = [],
        textLayers: [TextLayer] = [],
        overlays: [OverlayLayer] = [],
        audio: [AudioClip] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canvas = canvas
        self.recipeID = recipeID
        self.clips = clips
        self.textLayers = textLayers
        self.overlays = overlays
        self.audio = audio
    }

    /// Total length. Clips are sequential, so this is the end of the last one — but text and
    /// audio can legitimately extend past it, so take the max.
    public var duration: Double {
        let clipEnd = clips.last.map { $0.start + $0.duration } ?? 0
        let textEnd = textLayers.map(\.end).max() ?? 0
        let audioEnd = audio.map { $0.start + $0.duration }.max() ?? 0
        let overlayEnd = overlays.map(\.end).max() ?? 0
        return max(max(clipEnd, textEnd), max(audioEnd, overlayEnd))
    }

    public func clip(id: UUID) -> VideoClip? { clips.first { $0.id == id } }
    public func clipIndex(id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    /// The clip visible at `time`, ignoring transition overlap.
    public func clip(at time: Double) -> VideoClip? {
        clips.first { time >= $0.start && time < $0.start + $0.duration }
    }

    /// Recomputes `start` for every clip so they butt up against each other with no gaps.
    ///
    /// Called after any structural edit. Transitions overlap *visually* during render but do
    /// not consume timeline time — a 0.3 s dissolve between two 1 s clips still totals 2 s.
    /// Keeping the model gapless means clip start times are always the sum of preceding
    /// durations, which makes the timeline UI and the planner both much simpler.
    public mutating func relayout() {
        var cursor = 0.0
        for i in clips.indices {
            clips[i].start = canvas.snapToFrame(cursor)
            clips[i].duration = max(canvas.frameDuration, canvas.snapToFrame(clips[i].duration))
            cursor = clips[i].start + clips[i].duration
        }
    }

    /// All time positions an edit gesture should snap to.
    public func snapTargets(beatGrid: BeatGrid?) -> [SnapTarget] {
        var targets: [SnapTarget] = [SnapTarget(time: 0, kind: .start)]
        for clip in clips {
            targets.append(SnapTarget(time: clip.start, kind: .clipBoundary))
        }
        if let last = clips.last {
            targets.append(SnapTarget(time: last.start + last.duration, kind: .end))
        }
        for beat in beatGrid?.beats ?? [] {
            targets.append(SnapTarget(time: beat, kind: .beat))
        }
        return targets
    }
}

public struct SnapTarget: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case start, end, clipBoundary, beat, playhead }
    public var time: Double
    public var kind: Kind

    public init(time: Double, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

// MARK: - Clips

public struct VideoClip: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Points into the project's `AssetPool`. Nil renders a labelled placeholder rather than
    /// crashing — the user deleting a photo from Photos must not destroy the project.
    public var assetID: UUID?
    /// Which slot of the recipe this fills. Retained so re-running Auto Arrange knows what
    /// each clip is *for* after the user has reordered things.
    public var slotID: String?

    public var start: Double
    public var duration: Double
    /// Offset into the source, for video assets. Ignored for stills.
    public var sourceStart: Double

    /// Ken Burns crop. Animates start -> end across the clip.
    public var cropStart: NormalizedRect
    public var cropEnd: NormalizedRect
    public var easing: Easing

    public var transitionIn: Transition?
    public var grade: ColorGrade
    public var speed: Double
    public var opacity: Double
    public var volume: Double
    /// 0...1 corner darkening.
    public var vignette: Double
    /// 0...1 film grain.
    public var grain: Double

    public init(
        id: UUID = UUID(),
        assetID: UUID?,
        slotID: String? = nil,
        start: Double,
        duration: Double,
        sourceStart: Double = 0,
        cropStart: NormalizedRect = .full,
        cropEnd: NormalizedRect = .full,
        easing: Easing = .easeInOut,
        transitionIn: Transition? = nil,
        grade: ColorGrade = .neutral,
        speed: Double = 1.0,
        opacity: Double = 1.0,
        volume: Double = 1.0,
        vignette: Double = 0,
        grain: Double = 0
    ) {
        self.id = id
        self.assetID = assetID
        self.slotID = slotID
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.cropStart = cropStart
        self.cropEnd = cropEnd
        self.easing = easing
        self.transitionIn = transitionIn
        self.grade = grade
        self.speed = speed
        self.opacity = opacity
        self.volume = volume
        self.vignette = vignette
        self.grain = grain
    }

    public var end: Double { start + duration }

    public func crop(atLocalTime t: Double) -> NormalizedRect {
        guard duration > 0 else { return cropStart }
        let progress = easing.apply(min(max(t / duration, 0), 1))
        return cropStart.interpolated(to: cropEnd, t: progress).clampedInsideUnitSquare()
    }

    /// Source time for a given local time, accounting for speed. Stills ignore this.
    public func sourceTime(atLocalTime t: Double) -> Double {
        sourceStart + t * speed
    }
}

public struct Transition: Codable, Sendable, Hashable {
    public var kind: TransitionKind
    public var duration: Double
    public var direction: TransitionDirection?

    public init(kind: TransitionKind, duration: Double, direction: TransitionDirection? = nil) {
        self.kind = kind
        self.duration = duration
        self.direction = direction
    }

    public static let cut = Transition(kind: .cut, duration: 0)

    /// Built from a recipe template with confidence gating already applied.
    public init(template: TransitionTemplate) {
        self.kind = template.effectiveKind
        self.duration = template.effectiveDuration
        self.direction = template.direction
    }
}

// MARK: - Text

public struct TextLayer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var slotID: String?
    /// The user's words. Never populated from `TextSlotTemplate.sampleText`.
    public var text: String
    public var role: TextRole
    public var start: Double
    public var end: Double
    public var frame: NormalizedRect
    public var alignment: TextAlignment
    public var fontCategory: FontCategory
    public var sizeRatio: Double
    public var colorHex: String
    public var hasShadow: Bool
    public var entry: TextEntryAnimation
    public var exit: TextExitAnimation

    public init(
        id: UUID = UUID(),
        slotID: String? = nil,
        text: String,
        role: TextRole,
        start: Double,
        end: Double,
        frame: NormalizedRect,
        alignment: TextAlignment = .center,
        fontCategory: FontCategory = .sansSerif,
        sizeRatio: Double = 0.055,
        colorHex: String = "#FFFFFF",
        hasShadow: Bool = true,
        entry: TextEntryAnimation = .fadeIn,
        exit: TextExitAnimation = .fadeOut
    ) {
        self.id = id
        self.slotID = slotID
        self.text = text
        self.role = role
        self.start = start
        self.end = end
        self.frame = frame
        self.alignment = alignment
        self.fontCategory = fontCategory
        self.sizeRatio = sizeRatio
        self.colorHex = colorHex
        self.hasShadow = hasShadow
        self.entry = entry
        self.exit = exit
    }

    public var duration: Double { max(0, end - start) }

    public func isVisible(at time: Double) -> Bool { time >= start && time < end }

    /// 0...1 opacity from the entry/exit animations. Word-level reveal is handled by the
    /// planner, which needs per-word timing this scalar cannot express.
    public func opacity(at time: Double) -> Double {
        guard isVisible(at: time) else { return 0 }
        let local = time - start
        let remaining = end - time

        var alpha = 1.0
        let entryDuration = entry.duration
        if entryDuration > 0, local < entryDuration {
            switch entry {
            case .none, .wordByWord, .typeOn: alpha = 1.0
            default: alpha = local / entryDuration
            }
        }
        let exitDuration = exit.duration
        if exitDuration > 0, remaining < exitDuration, exit != .none {
            alpha = min(alpha, remaining / exitDuration)
        }
        return min(max(alpha, 0), 1)
    }
}

// MARK: - Overlays & audio

/// The user's logo, or any other static image layer.
public struct OverlayLayer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    public var start: Double
    public var end: Double
    public var frame: NormalizedRect
    public var opacity: Double

    public init(
        id: UUID = UUID(), assetID: UUID, start: Double, end: Double,
        frame: NormalizedRect, opacity: Double = 1.0
    ) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.end = end
        self.frame = frame
        self.opacity = opacity
    }

    public func isVisible(at time: Double) -> Bool { time >= start && time < end }
}

public struct AudioClip: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    public var start: Double
    public var duration: Double
    public var sourceStart: Double
    public var volume: Double
    public var fadeIn: Double
    public var fadeOut: Double

    public init(
        id: UUID = UUID(), assetID: UUID, start: Double, duration: Double,
        sourceStart: Double = 0, volume: Double = 1.0,
        fadeIn: Double = 0, fadeOut: Double = 0.5
    ) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var end: Double { start + duration }

    public func gain(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        var g = volume
        if fadeIn > 0, time - start < fadeIn {
            g *= (time - start) / fadeIn
        }
        if fadeOut > 0, end - time < fadeOut {
            g *= (end - time) / fadeOut
        }
        return min(max(g, 0), 1)
    }
}
