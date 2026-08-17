import Foundation
import RecipeCore

/// A flat, immutable draw list for one instant in time.
///
/// Produced by a pure function of `(Timeline, time)` and consumed by Metal. Splitting "what to
/// draw" from "how to draw it" is what lets layer ordering, transition interpolation, Ken Burns
/// curves and text timing all be unit-tested on a Mac with no GPU, no simulator and no device.
public struct RenderPlan: Sendable, Hashable {
    public var canvas: CanvasSpec
    public var time: Double
    public var background: SIMD4<Float>
    public var stage: Stage
    /// Text and logo, composited *above* the transition rather than inside it. Reel typography
    /// almost always sits over the cut rather than participating in it.
    public var overlays: [PlanLayer]

    public init(
        canvas: CanvasSpec,
        time: Double,
        background: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        stage: Stage,
        overlays: [PlanLayer] = []
    ) {
        self.canvas = canvas
        self.time = time
        self.background = background
        self.stage = stage
        self.overlays = overlays
    }

    /// A cut is the degenerate `.single` case rather than a transition with zero duration,
    /// which keeps the renderer's fast path genuinely fast.
    public enum Stage: Sendable, Hashable {
        case single([PlanLayer])
        case transition(TransitionStage)
    }

    public struct TransitionStage: Sendable, Hashable {
        public var from: [PlanLayer]
        public var to: [PlanLayer]
        public var kind: TransitionKind
        public var direction: TransitionDirection?
        /// 0...1 through the transition.
        public var progress: Double

        public init(
            from: [PlanLayer], to: [PlanLayer], kind: TransitionKind,
            direction: TransitionDirection?, progress: Double
        ) {
            self.from = from
            self.to = to
            self.kind = kind
            self.direction = direction
            self.progress = progress
        }
    }

    /// Every layer the renderer knows about is a textured quad with a transform. Images, video
    /// frames, text and logos all take the same path — that uniformity is why adding an effect
    /// is a shader and a case rather than a subsystem.
    public struct PlanLayer: Sendable, Hashable {
        public var content: Content
        /// Region of the *source* to sample, normalised. This is the Ken Burns crop.
        public var sourceCrop: NormalizedRect
        /// Region of the *canvas* to fill, normalised.
        public var destination: NormalizedRect
        public var opacity: Double
        public var grade: ColorGrade
        public var rotation: Double
        /// Uniform scale about the destination centre, for pop-in animation.
        public var scale: Double

        public init(
            content: Content,
            sourceCrop: NormalizedRect = .full,
            destination: NormalizedRect = .full,
            opacity: Double = 1,
            grade: ColorGrade = .neutral,
            rotation: Double = 0,
            scale: Double = 1
        ) {
            self.content = content
            self.sourceCrop = sourceCrop
            self.destination = destination
            self.opacity = opacity
            self.grade = grade
            self.rotation = rotation
            self.scale = scale
        }

        public enum Content: Sendable, Hashable {
            /// A still or a video frame from the user's pool.
            case asset(id: UUID, sourceTime: Double, isVideo: Bool)
            /// A slot with no asset assigned, or an asset that has gone missing. Rendered as a
            /// labelled placeholder rather than crashing or silently dropping the scene.
            case placeholder(label: String)
            case text(TextDraw)
            case solid(SIMD4<Float>)
        }
    }
}

/// Everything the renderer needs to draw one text layer at one instant.
///
/// Words carry individual alpha and offset so `wordByWord` — the dominant Reel typography
/// motion — is a per-quad delay rather than a special case in the renderer. That is also why
/// `TextRasterizer` rasterises per word and not per line.
public struct TextDraw: Sendable, Hashable {
    public var layerID: UUID
    public var words: [Word]
    public var fontCategory: FontCategory
    /// Cap height as a fraction of canvas height.
    public var sizeRatio: Double
    public var color: SIMD4<Float>
    public var hasShadow: Bool
    public var alignment: TextAlignment
    public var frame: NormalizedRect

    public init(
        layerID: UUID, words: [Word], fontCategory: FontCategory, sizeRatio: Double,
        color: SIMD4<Float>, hasShadow: Bool, alignment: TextAlignment, frame: NormalizedRect
    ) {
        self.layerID = layerID
        self.words = words
        self.fontCategory = fontCategory
        self.sizeRatio = sizeRatio
        self.color = color
        self.hasShadow = hasShadow
        self.alignment = alignment
        self.frame = frame
    }

    public struct Word: Sendable, Hashable {
        public var text: String
        public var opacity: Double
        /// Vertical offset in canvas fractions, for slide-in.
        public var offsetY: Double
        /// Scale about the word's own centre, for pop-in.
        public var scale: Double

        public init(text: String, opacity: Double, offsetY: Double, scale: Double) {
            self.text = text
            self.opacity = opacity
            self.offsetY = offsetY
            self.scale = scale
        }
    }
}

extension SIMD4<Float> {
    /// Parses `#RRGGBB` / `#RRGGBBAA`. Falls back to opaque white — an unreadable colour string
    /// should produce visible text, not invisible text.
    public static func fromHex(_ hex: String) -> SIMD4<Float> {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt32(cleaned, radix: 16) else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        if cleaned.count == 6 {
            return SIMD4<Float>(
                Float((value >> 16) & 0xFF) / 255,
                Float((value >> 8) & 0xFF) / 255,
                Float(value & 0xFF) / 255,
                1
            )
        }
        return SIMD4<Float>(
            Float((value >> 24) & 0xFF) / 255,
            Float((value >> 16) & 0xFF) / 255,
            Float((value >> 8) & 0xFF) / 255,
            Float(value & 0xFF) / 255
        )
    }
}
