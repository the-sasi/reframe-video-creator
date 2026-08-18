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
    /// Automatically lower music while a voice clip is playing. On by default because it is
    /// what people expect from a voiceover, and it is a mix-plan property rather than a manual
    /// keyframe job.
    public var duckMusicUnderVoice: Bool
    /// Canvas background behind letterboxed (`.fit`) clips and any gap. Hex, defaults to black.
    public var backgroundHex: String

    public init(
        schemaVersion: Int = RecipeSchema.current,
        id: UUID = UUID(),
        canvas: CanvasSpec = .reel1080,
        recipeID: UUID? = nil,
        clips: [VideoClip] = [],
        textLayers: [TextLayer] = [],
        overlays: [OverlayLayer] = [],
        audio: [AudioClip] = [],
        duckMusicUnderVoice: Bool = true,
        backgroundHex: String = "#000000"
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canvas = canvas
        self.recipeID = recipeID
        self.clips = clips
        self.textLayers = textLayers
        self.overlays = overlays
        self.audio = audio
        self.duckMusicUnderVoice = duckMusicUnderVoice
        self.backgroundHex = backgroundHex
    }

    // Fields added after v1 decode with defaults, so a project saved by an earlier build opens.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, canvas, recipeID, clips, textLayers, overlays, audio
        case duckMusicUnderVoice, backgroundHex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        canvas = try c.decode(CanvasSpec.self, forKey: .canvas)
        recipeID = try c.decodeIfPresent(UUID.self, forKey: .recipeID)
        clips = try c.decode([VideoClip].self, forKey: .clips)
        textLayers = try c.decode([TextLayer].self, forKey: .textLayers)
        overlays = try c.decode([OverlayLayer].self, forKey: .overlays)
        audio = try c.decode([AudioClip].self, forKey: .audio)
        duckMusicUnderVoice = try c.decodeIfPresent(Bool.self, forKey: .duckMusicUnderVoice) ?? true
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#000000"
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
    /// How the source fills the canvas. `.fill` crops (the default, and what the Ken Burns
    /// rects operate within); `.fit` letterboxes against `Timeline.backgroundHex`.
    public var fitMode: FitMode

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
        grain: Double = 0,
        fitMode: FitMode = .fill
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
        self.fitMode = fitMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, slotID, start, duration, sourceStart, cropStart, cropEnd, easing
        case transitionIn, grade, speed, opacity, volume, vignette, grain, fitMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        slotID = try c.decodeIfPresent(String.self, forKey: .slotID)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        cropStart = try c.decodeIfPresent(NormalizedRect.self, forKey: .cropStart) ?? .full
        cropEnd = try c.decodeIfPresent(NormalizedRect.self, forKey: .cropEnd) ?? .full
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .easeInOut
        transitionIn = try c.decodeIfPresent(Transition.self, forKey: .transitionIn)
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade) ?? .neutral
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        fitMode = try c.decodeIfPresent(FitMode.self, forKey: .fitMode) ?? .fill
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

    /// Seconds of source footage this clip consumes. Speed 2× over a 1 s slot uses 2 s.
    public var sourceDuration: Double { duration * speed }
    public var sourceEnd: Double { sourceStart + sourceDuration }
}

public enum FitMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Crop to fill the canvas. Ken Burns rects live inside the fill window.
    case fill
    /// Show the whole source, letterboxed against the timeline background.
    case fit

    public var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        }
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
    /// A newline forces a line break; otherwise lines wrap greedily to `frame.width`.
    public var text: String
    public var role: TextRole
    public var start: Double
    public var end: Double
    public var frame: NormalizedRect
    public var alignment: TextAlignment
    public var fontCategory: FontCategory
    /// A concrete face, when the user picked one. Nil means "whatever the category maps to",
    /// which is what every layer bound from a recipe starts with — see `TextFont`.
    public var fontName: String?
    public var weight: TextWeight
    public var isItalic: Bool
    public var allCaps: Bool
    /// Cap height as a fraction of canvas height.
    public var sizeRatio: Double
    /// Tracking, in ems. 0.05 is a noticeable open feel; negative tightens.
    public var letterSpacing: Double
    /// Line height multiplier.
    public var lineSpacing: Double
    public var colorHex: String
    public var opacity: Double
    public var hasShadow: Bool
    public var outline: TextOutline?
    public var background: TextBackground?
    /// Radians, about the frame centre.
    public var rotation: Double
    public var entry: TextEntryAnimation
    public var exit: TextExitAnimation
    /// Per-word start offsets from `start`, in seconds, when the words carry their own timing —
    /// captions transcribed from speech, mainly. Same count as words in `text`. The planner
    /// reveals each word at its offset; entry animation is then ignored.
    public var wordTimings: [Double]?

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
        fontName: String? = nil,
        weight: TextWeight = .bold,
        isItalic: Bool = false,
        allCaps: Bool = false,
        sizeRatio: Double = 0.055,
        letterSpacing: Double = 0,
        lineSpacing: Double = 1.18,
        colorHex: String = "#FFFFFF",
        opacity: Double = 1,
        hasShadow: Bool = true,
        outline: TextOutline? = nil,
        background: TextBackground? = nil,
        rotation: Double = 0,
        entry: TextEntryAnimation = .fadeIn,
        exit: TextExitAnimation = .fadeOut,
        wordTimings: [Double]? = nil
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
        self.fontName = fontName
        self.weight = weight
        self.isItalic = isItalic
        self.allCaps = allCaps
        self.sizeRatio = sizeRatio
        self.letterSpacing = letterSpacing
        self.lineSpacing = lineSpacing
        self.colorHex = colorHex
        self.opacity = opacity
        self.hasShadow = hasShadow
        self.outline = outline
        self.background = background
        self.rotation = rotation
        self.entry = entry
        self.exit = exit
        self.wordTimings = wordTimings
    }

    private enum CodingKeys: String, CodingKey {
        case id, slotID, text, role, start, end, frame, alignment, fontCategory, fontName
        case weight, isItalic, allCaps, sizeRatio, letterSpacing, lineSpacing, colorHex, opacity
        case hasShadow, outline, background, rotation, entry, exit, wordTimings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        slotID = try c.decodeIfPresent(String.self, forKey: .slotID)
        text = try c.decode(String.self, forKey: .text)
        role = try c.decode(TextRole.self, forKey: .role)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        frame = try c.decode(NormalizedRect.self, forKey: .frame)
        alignment = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .center
        fontCategory = try c.decodeIfPresent(FontCategory.self, forKey: .fontCategory) ?? .sansSerif
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        weight = try c.decodeIfPresent(TextWeight.self, forKey: .weight) ?? .bold
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        allCaps = try c.decodeIfPresent(Bool.self, forKey: .allCaps) ?? false
        sizeRatio = try c.decodeIfPresent(Double.self, forKey: .sizeRatio) ?? 0.055
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.18
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        hasShadow = try c.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? true
        outline = try c.decodeIfPresent(TextOutline.self, forKey: .outline)
        background = try c.decodeIfPresent(TextBackground.self, forKey: .background)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        entry = try c.decodeIfPresent(TextEntryAnimation.self, forKey: .entry) ?? .fadeIn
        exit = try c.decodeIfPresent(TextExitAnimation.self, forKey: .exit) ?? .fadeOut
        wordTimings = try c.decodeIfPresent([Double].self, forKey: .wordTimings)
    }

    public var duration: Double { max(0, end - start) }

    /// The words the renderer draws, honouring forced line breaks and `allCaps`. A newline is
    /// carried as a marker word so layout can start a new line without a separate structure.
    public var displayWords: [String] {
        let source = allCaps ? text.uppercased() : text
        var words: [String] = []
        for (lineIndex, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if lineIndex > 0 { words.append(TextLayer.lineBreakMarker) }
            words.append(contentsOf: line.split(separator: " ", omittingEmptySubsequences: true).map(String.init))
        }
        return words
    }

    /// Sentinel emitted by `displayWords` between forced lines. Never rasterised.
    public static let lineBreakMarker = "\u{2028}"

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

public enum TextWeight: String, Codable, Sendable, Hashable, CaseIterable {
    case light, regular, medium, semibold, bold, heavy, black

    public var displayName: String { rawValue.capitalized }
}

/// A stroke drawn around the glyphs. Width is in ems so it scales with the type.
public struct TextOutline: Codable, Sendable, Hashable {
    public var colorHex: String
    public var widthEm: Double

    public init(colorHex: String = "#000000", widthEm: Double = 0.06) {
        self.colorHex = colorHex
        self.widthEm = widthEm
    }
}

/// A filled box behind each line (or the whole block). The Reel "caption pill".
public struct TextBackground: Codable, Sendable, Hashable {
    public var colorHex: String
    public var opacity: Double
    /// Horizontal/vertical padding, in ems.
    public var paddingEm: Double
    /// Corner radius, in ems.
    public var cornerRadiusEm: Double

    public init(
        colorHex: String = "#000000", opacity: Double = 0.6,
        paddingEm: Double = 0.35, cornerRadiusEm: Double = 0.25
    ) {
        self.colorHex = colorHex
        self.opacity = opacity
        self.paddingEm = paddingEm
        self.cornerRadiusEm = cornerRadiusEm
    }
}

/// Curated faces that ship with iOS. Bundled system fonts may be rendered by any app; nothing
/// here is downloaded or embedded, so there is no font licence to carry.
public struct TextFont: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    /// PostScript-ish family name Core Text resolves. Nil means the system font.
    public let familyName: String?
    public let category: FontCategory

    public static let system = TextFont(id: "system", displayName: "SF Pro", familyName: nil, category: .sansSerif)

    public static let all: [TextFont] = [
        .system,
        TextFont(id: "sf-rounded", displayName: "SF Rounded", familyName: ".AppleSystemUIFontRounded", category: .sansSerif),
        TextFont(id: "helvetica-neue", displayName: "Helvetica Neue", familyName: "Helvetica Neue", category: .sansSerif),
        TextFont(id: "avenir-next", displayName: "Avenir Next", familyName: "Avenir Next", category: .sansSerif),
        TextFont(id: "futura", displayName: "Futura", familyName: "Futura", category: .displayBold),
        TextFont(id: "avenir-condensed", displayName: "Avenir Condensed", familyName: "Avenir Next Condensed", category: .condensed),
        TextFont(id: "georgia", displayName: "Georgia", familyName: "Georgia", category: .serif),
        TextFont(id: "baskerville", displayName: "Baskerville", familyName: "Baskerville", category: .serif),
        TextFont(id: "didot", displayName: "Didot", familyName: "Didot", category: .serif),
        TextFont(id: "typewriter", displayName: "American Typewriter", familyName: "American Typewriter", category: .serif),
        TextFont(id: "snell", displayName: "Snell Roundhand", familyName: "Snell Roundhand", category: .handwritten),
        TextFont(id: "marker", displayName: "Marker Felt", familyName: "Marker Felt", category: .handwritten),
        TextFont(id: "noteworthy", displayName: "Noteworthy", familyName: "Noteworthy", category: .handwritten),
        TextFont(id: "chalkduster", displayName: "Chalkduster", familyName: "Chalkduster", category: .handwritten),
        TextFont(id: "menlo", displayName: "Menlo", familyName: "Menlo", category: .monospace),
        TextFont(id: "courier", displayName: "Courier New", familyName: "Courier New", category: .monospace),
        TextFont(id: "copperplate", displayName: "Copperplate", familyName: "Copperplate", category: .displayBold),
    ]

    public static func named(_ familyName: String?) -> TextFont? {
        all.first { $0.familyName == familyName }
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
    /// What this clip *is* — decides ducking and the lane it draws in.
    public var role: AudioRole
    public var isMuted: Bool

    public init(
        id: UUID = UUID(), assetID: UUID, start: Double, duration: Double,
        sourceStart: Double = 0, volume: Double = 1.0,
        fadeIn: Double = 0, fadeOut: Double = 0.5,
        role: AudioRole = .music, isMuted: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.role = role
        self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, start, duration, sourceStart, volume, fadeIn, fadeOut, role, isMuted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetID = try c.decode(UUID.self, forKey: .assetID)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0.5
        role = try c.decodeIfPresent(AudioRole.self, forKey: .role) ?? .music
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }

    public var end: Double { start + duration }
    public var sourceEnd: Double { sourceStart + duration }

    /// The clip's own envelope at `time`: volume shaped by its fades. Ducking is layered on top
    /// by `AudioMixPlanner`, which sees the whole timeline.
    public func gain(at time: Double) -> Double {
        guard !isMuted, time >= start, time < end else { return 0 }
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

public enum AudioRole: String, Codable, Sendable, Hashable, CaseIterable {
    case music
    case voice
    case effect
    /// The reference video's own soundtrack, when the user chose to keep it.
    case reference
    /// A video clip's own sound. Never an `AudioClip` role — only `AudioMixPlan.Track` uses it.
    case clipAudio

    public var displayName: String {
        switch self {
        case .music: return "Music"
        case .voice: return "Voice"
        case .effect: return "Sound effect"
        case .reference: return "Reference audio"
        case .clipAudio: return "Clip audio"
        }
    }

    /// Whether other music should be lowered while this plays.
    public var causesDucking: Bool { self == .voice }
    /// Whether this track is lowered while a voice plays.
    public var isDucked: Bool { self == .music || self == .reference || self == .clipAudio }
}
