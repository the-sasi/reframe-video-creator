import Foundation

// MARK: - Root

/// The extracted *style* of a reference video: pacing, cuts, camera moves, transitions, text
/// rhythm and beat alignment, with no assets and no pixels.
///
/// This is the central abstraction of the product. It is asset-free by construction — there is
/// nowhere in this type to put a file path — which is what makes a recipe reusable across
/// projects and safe to share.
///
/// Determinism matters here: `RecipeCompiler` seeds all identifiers from the source
/// fingerprint, so analysing the same file twice produces byte-identical JSON. That turns
/// "did my change to the motion analyser alter anything?" into a diff.
public struct EditRecipe: Codable, Sendable, Hashable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date

    public var source: SourceInfo
    public var canvas: CanvasSpec
    public var duration: Double

    public var beatGrid: BeatGrid?
    public var scenes: [SceneTemplate]
    public var textSlots: [TextSlotTemplate]
    public var audio: AudioPlan
    public var palette: Palette
    public var stats: RecipeStats
    public var confidence: ConfidenceReport
    /// Library categories ("Product", "Fast Reel", …). Optional so recipes written before the
    /// template library existed still decode.
    public var tags: [String]?
    /// True for the built-in starter templates; nil or false for anything analysed from a
    /// reference. The library uses this to separate "yours" from "starters".
    public var isBuiltIn: Bool?

    public init(
        schemaVersion: Int = RecipeSchema.current,
        id: UUID,
        title: String,
        createdAt: Date,
        source: SourceInfo,
        canvas: CanvasSpec,
        duration: Double,
        beatGrid: BeatGrid?,
        scenes: [SceneTemplate],
        textSlots: [TextSlotTemplate],
        audio: AudioPlan,
        palette: Palette,
        stats: RecipeStats,
        confidence: ConfidenceReport,
        tags: [String]? = nil,
        isBuiltIn: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.source = source
        self.canvas = canvas
        self.duration = duration
        self.beatGrid = beatGrid
        self.scenes = scenes
        self.textSlots = textSlots
        self.audio = audio
        self.palette = palette
        self.stats = stats
        self.confidence = confidence
        self.tags = tags
        self.isBuiltIn = isBuiltIn
    }

    /// Category chips for the library. Falls back to something derived from the stats when a
    /// recipe was analysed before tags existed, so nothing shows up unclassified.
    public var displayTags: [String] {
        if let tags, !tags.isEmpty { return tags }
        var derived: [String] = []
        if stats.medianSceneDuration < 0.8 { derived.append("Fast Reel") }
        else if stats.medianSceneDuration > 2.0 { derived.append("Slideshow") }
        if beatGrid?.cutsAlignedToBeats.value == true { derived.append("Beat Sync") }
        if stats.textSlotCount >= 3 { derived.append("Text Heavy") }
        if stats.transitionCount == 0 { derived.append("Minimal") }
        if derived.isEmpty { derived.append("Reference") }
        return derived
    }

    /// How many user assets this recipe wants. Drives the "add 12 photos" prompt.
    public var assetSlotCount: Int { scenes.count }

    /// Text slots the user is expected to fill, excluding anything the analyser flagged as
    /// creator watermark (those never make it into `textSlots` in the first place).
    public var fillableTextSlots: [TextSlotTemplate] { textSlots.filter { $0.role != .watermark } }
}

// MARK: - Source

/// What the reference file *was*. Retained so the summary screen can describe it and so
/// `fingerprint` can key caches — deliberately holds no pixels and no path.
public struct SourceInfo: Codable, Sendable, Hashable {
    public var duration: Double
    public var fps: Double
    public var width: Int
    public var height: Int
    public var aspect: AspectPreset
    public var hasAudio: Bool
    /// Content hash of the source. Identifies the reference for cache keys and determinism
    /// seeding without retaining anything about it.
    public var fingerprint: String

    public init(
        duration: Double, fps: Double, width: Int, height: Int,
        aspect: AspectPreset, hasAudio: Bool, fingerprint: String
    ) {
        self.duration = duration
        self.fps = fps
        self.width = width
        self.height = height
        self.aspect = aspect
        self.hasAudio = hasAudio
        self.fingerprint = fingerprint
    }
}

// MARK: - Rhythm

public struct BeatGrid: Codable, Sendable, Hashable {
    public var bpm: Confident<Double>
    /// Beat onsets in seconds from the start of the reference.
    public var beats: [Double]
    /// Every fourth beat, phase-aligned to the strongest onsets. Used for major structural cuts.
    public var downbeats: [Double]
    /// Whether the reference's own cuts land on this grid. If false, the recipe keeps the
    /// reference's literal timings instead of quantising the user's edit to beats.
    public var cutsAlignedToBeats: Confident<Bool>

    public init(
        bpm: Confident<Double>, beats: [Double],
        downbeats: [Double], cutsAlignedToBeats: Confident<Bool>
    ) {
        self.bpm = bpm
        self.beats = beats
        self.downbeats = downbeats
        self.cutsAlignedToBeats = cutsAlignedToBeats
    }

    /// Nearest beat to `time`, or nil if none is within `tolerance`.
    public func nearestBeat(to time: Double, tolerance: Double = 0.12) -> Double? {
        guard let nearest = beats.min(by: { abs($0 - time) < abs($1 - time) }) else { return nil }
        return abs(nearest - time) <= tolerance ? nearest : nil
    }
}

// MARK: - Scenes

/// One shot's worth of structure. Describes the *shape* of a scene, not its content.
public struct SceneTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var index: Int
    public var start: Double
    public var end: Double

    /// What the reference used here. A preference for the binder, not a constraint — the user
    /// can put a still where the reference had motion footage.
    public var sourceKind: SourceKind
    public var role: Confident<SceneRole>
    public var slot: AssetSlot
    public var move: CameraMove
    /// Transition *into* this scene. The first scene's is nil (or a fade-in from black).
    public var transitionIn: TransitionTemplate?
    public var effects: [EffectTemplate]
    public var grade: ColorGrade?

    public init(
        id: String, index: Int, start: Double, end: Double,
        sourceKind: SourceKind, role: Confident<SceneRole>, slot: AssetSlot,
        move: CameraMove, transitionIn: TransitionTemplate?,
        effects: [EffectTemplate] = [], grade: ColorGrade? = nil
    ) {
        self.id = id
        self.index = index
        self.start = start
        self.end = end
        self.sourceKind = sourceKind
        self.role = role
        self.slot = slot
        self.move = move
        self.transitionIn = transitionIn
        self.effects = effects
        self.grade = grade
    }

    public var duration: Double { max(0, end - start) }
}

public enum SourceKind: String, Codable, Sendable, Hashable {
    case image
    case video
    case unknown
}

/// Inferred narrative function of a scene. Drives which of the user's photos is a good fit —
/// the hero slot wants their best shot, the opening wants something establishing.
public enum SceneRole: String, Codable, Sendable, Hashable, CaseIterable {
    case opening
    case body
    case detail
    case wide
    case hero
    case closing

    public var displayName: String {
        switch self {
        case .opening: return "Opening"
        case .body: return "Body"
        case .detail: return "Detail"
        case .wide: return "Wide"
        case .hero: return "Hero"
        case .closing: return "Closing"
        }
    }
}

/// What kind of asset belongs in this scene.
public struct AssetSlot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// How tight the reference's shot was, derived from salient-region area.
    public var framing: Confident<ShotFraming>
    /// 0...1, how much the reference frame moved during this scene. High energy suggests the
    /// user's video clips rather than a still.
    public var motionEnergy: Double
    /// Free-text hint from the optional intelligence provider, e.g. "product close-up".
    /// Presentation only — the scorer does not read it.
    public var preferSubject: String?
    /// Where the reference's subject sat in the frame, normalised. This is what lets the binder
    /// put the *user's* subject in the same place — composition transfer rather than a centred
    /// crop. Nil when saliency found nothing.
    public var subjectRect: Confident<NormalizedRect>?

    public init(
        id: String, framing: Confident<ShotFraming>,
        motionEnergy: Double, preferSubject: String? = nil,
        subjectRect: Confident<NormalizedRect>? = nil
    ) {
        self.id = id
        self.framing = framing
        self.motionEnergy = motionEnergy
        self.preferSubject = preferSubject
        self.subjectRect = subjectRect
    }
}

public enum ShotFraming: String, Codable, Sendable, Hashable, CaseIterable {
    case closeUp
    case medium
    case wide

    /// Classified from the fraction of frame area the salient region occupies. Thresholds
    /// chosen so a typical product close-up (subject fills most of frame) reads as `.closeUp`
    /// and an establishing shot reads as `.wide`.
    public init(salientAreaFraction: Double) {
        switch salientAreaFraction {
        case 0.45...: self = .closeUp
        case 0.18..<0.45: self = .medium
        default: self = .wide
        }
    }

    public var displayName: String {
        switch self {
        case .closeUp: return "Close-up"
        case .medium: return "Medium"
        case .wide: return "Wide"
        }
    }
}

// MARK: - Camera movement

/// The Ken Burns move for a scene, expressed as a crop rect that animates from `startRect` to
/// `endRect`. Storing rects rather than "zoom 1.17x" means the binder can re-anchor the move
/// onto the user's photo — whose subject is somewhere else — without re-deriving anything.
public struct CameraMove: Codable, Sendable, Hashable {
    public var kind: Confident<CameraMoveKind>
    public var startRect: NormalizedRect
    public var endRect: NormalizedRect
    public var easing: Easing
    /// Applied when `kind.confidence` falls below the fallback threshold.
    public var safeFallback: CameraMoveKind

    public init(
        kind: Confident<CameraMoveKind>, startRect: NormalizedRect,
        endRect: NormalizedRect, easing: Easing, safeFallback: CameraMoveKind = .none
    ) {
        self.kind = kind
        self.startRect = startRect
        self.endRect = endRect
        self.easing = easing
        self.safeFallback = safeFallback
    }

    public static let still = CameraMove(
        kind: Confident(.none, confidence: 1.0, basis: "no motion requested"),
        startRect: .full, endRect: .full, easing: .linear
    )

    /// A gentle default push-in. Used when motion analysis was too uncertain to trust but the
    /// scene would look dead without any movement — §37's "simpler motion" fallback.
    public static func gentlePushIn(confidence: Double, basis: String) -> CameraMove {
        CameraMove(
            kind: Confident(.zoomIn, confidence: confidence, basis: basis),
            startRect: .full,
            endRect: NormalizedRect.full.scaled(by: 0.90),
            easing: .easeInOut,
            safeFallback: .none
        )
    }

    /// Resolves the crop rect at normalised progress `t` through the scene.
    public func rect(at t: Double) -> NormalizedRect {
        let eased = easing.apply(t)
        return startRect.interpolated(to: endRect, t: eased).clampedInsideUnitSquare()
    }

    /// The move actually applied, after confidence gating.
    public var effectiveKind: CameraMoveKind {
        kind.isTrustworthy ? kind.value : safeFallback
    }
}

public enum CameraMoveKind: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case zoomIn
    case zoomOut
    case panLeft
    case panRight
    case panUp
    case panDown
    case rotate
    /// Motion was present but did not fit a simple model. Degrades to `safeFallback`.
    case complex

    public var displayName: String {
        switch self {
        case .none: return "Static"
        case .zoomIn: return "Push in"
        case .zoomOut: return "Pull out"
        case .panLeft: return "Pan left"
        case .panRight: return "Pan right"
        case .panUp: return "Pan up"
        case .panDown: return "Pan down"
        case .rotate: return "Rotate"
        case .complex: return "Complex move"
        }
    }
}

// MARK: - Transitions

public struct TransitionTemplate: Codable, Sendable, Hashable {
    public var kind: Confident<TransitionKind>
    public var duration: Double
    public var direction: TransitionDirection?
    /// Declared in the data rather than looked up in code, so §37's graceful degradation is a
    /// property of the document. A whip-pan we are 40% sure about becomes a cut, not a broken
    /// whip-pan.
    public var safeFallback: TransitionKind

    public init(
        kind: Confident<TransitionKind>, duration: Double,
        direction: TransitionDirection? = nil, safeFallback: TransitionKind = .cut
    ) {
        self.kind = kind
        self.duration = duration
        self.direction = direction
        self.safeFallback = safeFallback
    }

    public static let cut = TransitionTemplate(
        kind: Confident(.cut, confidence: 1.0, basis: "hard cut, frame delta above threshold"),
        duration: 0
    )

    public var effectiveKind: TransitionKind {
        kind.isTrustworthy ? kind.value : safeFallback
    }

    /// Zero-duration transitions are cuts regardless of what was detected.
    public var effectiveDuration: Double {
        effectiveKind == .cut ? 0 : duration
    }
}

public enum TransitionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case cut
    case dissolve
    case fadeToBlack
    case fadeToWhite
    case slide
    case push
    case zoomIn
    case zoomOut
    case whip
    case blur

    public var displayName: String {
        switch self {
        case .cut: return "Cut"
        case .dissolve: return "Dissolve"
        case .fadeToBlack: return "Fade to black"
        case .fadeToWhite: return "Fade to white"
        case .slide: return "Slide"
        case .push: return "Push"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .whip: return "Whip"
        case .blur: return "Blur"
        }
    }

    /// Whether this transition needs both scenes rendered simultaneously. `cut` does not,
    /// which is why it is the degenerate case rather than a special case.
    public var requiresBothScenes: Bool { self != .cut }

    public var needsDirection: Bool {
        self == .slide || self == .push || self == .whip
    }
}

public enum TransitionDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case left, right, up, down
}

// MARK: - Effects

/// Reserved and deliberately sparse. Generative cases live here when a free on-device model
/// exists; see docs/07-roadmap.md on why phase 6 is empty rather than stubbed.
public struct EffectTemplate: Codable, Sendable, Hashable {
    public var kind: EffectKind
    public var intensity: Double
    public var start: Double
    public var end: Double

    public init(kind: EffectKind, intensity: Double, start: Double, end: Double) {
        self.kind = kind
        self.intensity = intensity
        self.start = start
        self.end = end
    }
}

public enum EffectKind: String, Codable, Sendable, Hashable, CaseIterable {
    case shake
    case pulse
    case flash
    case vignette
}

// MARK: - Colour

/// Four scalars, because four scalars is what `ColorAnalyzer` can honestly infer. No LUTs.
public struct ColorGrade: Codable, Sendable, Hashable {
    public var exposure: Double     // -1...1, additive in linear space
    public var contrast: Double     // 0...2, 1 is neutral
    public var saturation: Double   // 0...2, 1 is neutral
    public var temperature: Double  // -1...1, positive is warmer

    public init(exposure: Double, contrast: Double, saturation: Double, temperature: Double) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
    }

    public static let neutral = ColorGrade(exposure: 0, contrast: 1, saturation: 1, temperature: 0)
    public var isNeutral: Bool { self == .neutral }
}

public struct Palette: Codable, Sendable, Hashable {
    /// Hex strings, most dominant first.
    public var dominant: [String]
    public var meanBrightness: Double
    public var meanSaturation: Double
    public var contrast: Double

    public init(dominant: [String], meanBrightness: Double, meanSaturation: Double, contrast: Double) {
        self.dominant = dominant
        self.meanBrightness = meanBrightness
        self.meanSaturation = meanSaturation
        self.contrast = contrast
    }

    public static let neutral = Palette(
        dominant: [], meanBrightness: 0.5, meanSaturation: 0.5, contrast: 1.0
    )
}

// MARK: - Text

public struct TextSlotTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var role: TextRole
    public var start: Double
    public var end: Double
    public var frame: NormalizedRect
    public var alignment: TextAlignment
    public var style: TextStyleTemplate
    public var animation: TextAnimation

    /// What the reference's text said. **A hint, never content.**
    ///
    /// Shown to the user as "reference said: ... (17 chars)" so they can fit their own copy to
    /// the layout. `RecipeBinder` has no code path that reads this into a `TextLayer` — see
    /// docs/02-licensing.md.
    public var sampleText: String?
    public var charCountHint: Int

    public init(
        id: String, role: TextRole, start: Double, end: Double,
        frame: NormalizedRect, alignment: TextAlignment,
        style: TextStyleTemplate, animation: TextAnimation,
        sampleText: String? = nil, charCountHint: Int = 0
    ) {
        self.id = id
        self.role = role
        self.start = start
        self.end = end
        self.frame = frame
        self.alignment = alignment
        self.style = style
        self.animation = animation
        self.sampleText = sampleText
        self.charCountHint = charCountHint
    }

    public var duration: Double { max(0, end - start) }
}

public enum TextRole: String, Codable, Sendable, Hashable, CaseIterable {
    case title
    case subtitle
    case cta
    case caption
    /// Creator watermarks and handles. Detected so they can be *excluded*, never reproduced.
    case watermark

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .subtitle: return "Subtitle"
        case .cta: return "Call to action"
        case .caption: return "Caption"
        case .watermark: return "Watermark (ignored)"
        }
    }

    /// Placeholder shown in the content form.
    public var prompt: String {
        switch self {
        case .title: return "Product name"
        case .subtitle: return "Short description"
        case .cta: return "Call to action"
        case .caption: return "Caption"
        case .watermark: return ""
        }
    }
}

public enum TextAlignment: String, Codable, Sendable, Hashable, CaseIterable {
    case leading, center, trailing
}

public struct TextStyleTemplate: Codable, Sendable, Hashable {
    /// A *category*, never a family. Identifying an exact font from a 1080p frame is not
    /// solvable, and the schema refuses to pretend otherwise.
    public var category: Confident<FontCategory>
    /// Cap height as a fraction of canvas height. Resolution-independent.
    public var sizeRatio: Double
    public var colorHex: String
    public var shadow: Confident<Bool>?
    public var outline: Confident<Bool>?
    public var backgroundBox: String?

    public init(
        category: Confident<FontCategory>, sizeRatio: Double, colorHex: String,
        shadow: Confident<Bool>? = nil, outline: Confident<Bool>? = nil,
        backgroundBox: String? = nil
    ) {
        self.category = category
        self.sizeRatio = sizeRatio
        self.colorHex = colorHex
        self.shadow = shadow
        self.outline = outline
        self.backgroundBox = backgroundBox
    }

    public static let defaultTitle = TextStyleTemplate(
        category: Confident(.sansSerif, confidence: 0.5, basis: "default"),
        sizeRatio: 0.055,
        colorHex: "#FFFFFF",
        shadow: Confident(true, confidence: 0.5, basis: "default for legibility")
    )
}

public enum FontCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case sansSerif
    case serif
    case displayBold
    case condensed
    case handwritten
    case monospace

    public var displayName: String {
        switch self {
        case .sansSerif: return "Sans-serif"
        case .serif: return "Serif"
        case .displayBold: return "Bold display"
        case .condensed: return "Condensed"
        case .handwritten: return "Handwritten"
        case .monospace: return "Monospace"
        }
    }
}

public struct TextAnimation: Codable, Sendable, Hashable {
    public var entry: Confident<TextEntryAnimation>
    public var exit: Confident<TextExitAnimation>

    public init(entry: Confident<TextEntryAnimation>, exit: Confident<TextExitAnimation>) {
        self.entry = entry
        self.exit = exit
    }

    public static let fade = TextAnimation(
        entry: Confident(.fadeIn, confidence: 0.5, basis: "default"),
        exit: Confident(.fadeOut, confidence: 0.5, basis: "default")
    )

    public var effectiveEntry: TextEntryAnimation {
        entry.isTrustworthy ? entry.value : .fadeIn
    }

    public var effectiveExit: TextExitAnimation {
        exit.isTrustworthy ? exit.value : .fadeOut
    }
}

public enum TextEntryAnimation: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case fadeIn
    case popIn
    case slideUp
    case slideDown
    /// The dominant Reel typography motion. Rendered as a per-word delay, which is why
    /// `TextRasterizer` rasterises per word rather than per line.
    case wordByWord
    case typeOn

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .fadeIn: return "Fade in"
        case .popIn: return "Pop in"
        case .slideUp: return "Slide up"
        case .slideDown: return "Slide down"
        case .wordByWord: return "Word by word"
        case .typeOn: return "Type on"
        }
    }

    /// Seconds the entry animation occupies.
    public var duration: Double {
        switch self {
        case .none: return 0
        case .fadeIn, .popIn: return 0.25
        case .slideUp, .slideDown: return 0.30
        case .wordByWord, .typeOn: return 0.45
        }
    }
}

public enum TextExitAnimation: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case fadeOut
    case popOut
    case slideDown

    public var duration: Double {
        switch self {
        case .none: return 0
        case .fadeOut: return 0.20
        case .popOut, .slideDown: return 0.25
        }
    }
}

// MARK: - Audio

public struct AudioPlan: Codable, Sendable, Hashable {
    public var hasMusic: Bool
    public var hasSpeech: Confident<Bool>
    /// Normalised RMS envelope, ~4 samples/second. Drives the "energy" readout and could later
    /// drive intensity-matched effects.
    public var energyCurve: [Double]
    public var suggestedCutStyle: CutStyle

    public init(
        hasMusic: Bool, hasSpeech: Confident<Bool>,
        energyCurve: [Double], suggestedCutStyle: CutStyle
    ) {
        self.hasMusic = hasMusic
        self.hasSpeech = hasSpeech
        self.energyCurve = energyCurve
        self.suggestedCutStyle = suggestedCutStyle
    }

    public static let silent = AudioPlan(
        hasMusic: false,
        hasSpeech: Confident(false, confidence: 1.0, basis: "no audio track"),
        energyCurve: [],
        suggestedCutStyle: .literal
    )
}

public enum CutStyle: String, Codable, Sendable, Hashable {
    /// Quantise scene boundaries to the beat grid.
    case onBeat
    /// Keep the reference's literal timings.
    case literal

    public var displayName: String {
        switch self {
        case .onBeat: return "Beat-synced"
        case .literal: return "Reference timing"
        }
    }
}

// MARK: - Stats

/// Precomputed so the summary screen never has to walk the scene array.
public struct RecipeStats: Codable, Sendable, Hashable {
    public var sceneCount: Int
    public var medianSceneDuration: Double
    public var cutsPerSecond: Double
    public var transitionCount: Int
    public var textSlotCount: Int

    public init(
        sceneCount: Int, medianSceneDuration: Double, cutsPerSecond: Double,
        transitionCount: Int, textSlotCount: Int
    ) {
        self.sceneCount = sceneCount
        self.medianSceneDuration = medianSceneDuration
        self.cutsPerSecond = cutsPerSecond
        self.transitionCount = transitionCount
        self.textSlotCount = textSlotCount
    }

    /// Human phrase for the summary: "fast cuts", "relaxed pacing".
    public var pacingDescription: String {
        switch medianSceneDuration {
        case ..<0.6: return "Very fast cuts"
        case 0.6..<1.2: return "Fast cuts"
        case 1.2..<2.5: return "Steady pacing"
        default: return "Relaxed pacing"
        }
    }
}
