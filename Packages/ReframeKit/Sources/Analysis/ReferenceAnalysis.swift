import Foundation
import RecipeCore

/// Raw output of the analysis pipeline, before compilation into an `EditRecipe`.
///
/// Kept separate from the recipe because these are *observations* — what was seen in the
/// reference — whereas a recipe is a *plan*. Keeping the two apart means `RecipeCompiler` is a
/// pure, testable function from observations to plan, and the observations can be re-compiled
/// under different assumptions without re-analysing.
public struct ReferenceAnalysis: Sendable {
    public var source: SourceInfo
    public var shots: [DetectedShot]
    public var textTracks: [DetectedTextTrack]
    public var palette: Palette
    public var scenePalettes: [Int: ScenePalette]
    public var audio: AudioAnalysis?

    public init(
        source: SourceInfo,
        shots: [DetectedShot],
        textTracks: [DetectedTextTrack] = [],
        palette: Palette = .neutral,
        scenePalettes: [Int: ScenePalette] = [:],
        audio: AudioAnalysis? = nil
    ) {
        self.source = source
        self.shots = shots
        self.textTracks = textTracks
        self.palette = palette
        self.scenePalettes = scenePalettes
        self.audio = audio
    }
}

/// One continuous shot between two boundaries.
public struct DetectedShot: Sendable, Hashable {
    public var index: Int
    public var start: Double
    public var end: Double
    /// How this shot was entered.
    public var boundaryIn: DetectedBoundary
    /// Fitted camera motion, if motion analysis ran and converged.
    public var motion: FittedMotion?
    /// 0...1 summary of how much the frame moved. Drives `AssetSlot.motionEnergy`.
    public var motionEnergy: Double
    /// Mean salient-region area across sampled frames, for shot-scale classification.
    public var salientAreaFraction: Double?

    public var duration: Double { max(0, end - start) }

    public init(
        index: Int, start: Double, end: Double, boundaryIn: DetectedBoundary,
        motion: FittedMotion? = nil, motionEnergy: Double = 0,
        salientAreaFraction: Double? = nil
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.boundaryIn = boundaryIn
        self.motion = motion
        self.motionEnergy = motionEnergy
        self.salientAreaFraction = salientAreaFraction
    }
}

/// A detected shot boundary, with the evidence that produced it.
public struct DetectedBoundary: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case start          // beginning of the reference, not a real boundary
        case cut
        case dissolve
        case fadeFromBlack
        case fadeToBlack
        case fadeFromWhite
        case fadeToWhite
        /// Elevated frame difference that fitted neither the cut nor the blend model.
        case unknownGradual
    }

    public var kind: Kind
    public var time: Double
    /// Seconds the transition occupies. Zero for a cut.
    public var duration: Double
    public var confidence: Double
    public var basis: String

    public init(kind: Kind, time: Double, duration: Double, confidence: Double, basis: String) {
        self.kind = kind
        self.time = time
        self.duration = duration
        self.confidence = confidence
        self.basis = basis
    }

    public static func atStart() -> DetectedBoundary {
        DetectedBoundary(kind: .start, time: 0, duration: 0, confidence: 1, basis: "start of reference")
    }

    /// Maps observation to plan. Conservative on purpose: an unclassifiable gradual transition
    /// becomes a dissolve at reduced confidence rather than being asserted as something
    /// specific, and the recipe's `safeFallback` catches it if that confidence is too low.
    public var transitionKind: TransitionKind {
        switch kind {
        case .start, .cut: return .cut
        case .dissolve, .unknownGradual: return .dissolve
        case .fadeFromBlack, .fadeToBlack: return .fadeToBlack
        case .fadeFromWhite, .fadeToWhite: return .fadeToWhite
        }
    }
}

/// A similarity transform fitted to the optical-flow field between two frames, aggregated
/// across a shot.
public struct FittedMotion: Sendable, Hashable {
    /// Scale factor over the shot. >1 means the frame content grew, i.e. the camera pushed in.
    public var scale: Double
    /// Normalised translation over the shot, in frame widths/heights.
    public var translationX: Double
    public var translationY: Double
    public var rotationRadians: Double
    /// Mean residual of the fit. Low means the motion really was a simple similarity transform.
    public var residual: Double
    /// Number of frame pairs the fit aggregates. More pairs, more trust.
    public var sampleCount: Int

    public init(
        scale: Double, translationX: Double, translationY: Double,
        rotationRadians: Double, residual: Double, sampleCount: Int
    ) {
        self.scale = scale
        self.translationX = translationX
        self.translationY = translationY
        self.rotationRadians = rotationRadians
        self.residual = residual
        self.sampleCount = sampleCount
    }

    public static let identity = FittedMotion(
        scale: 1, translationX: 0, translationY: 0,
        rotationRadians: 0, residual: 0, sampleCount: 0
    )

    /// Classifies the fit into a named move. Thresholds are deliberately generous — a 3% zoom
    /// over a one-second shot is not a push-in, it is noise in the fit.
    public var kind: CameraMoveKind {
        let zoomMagnitude = abs(scale - 1)
        let panMagnitude = max(abs(translationX), abs(translationY))
        let rotationMagnitude = abs(rotationRadians)

        // Several things happening at once is not a nameable move.
        let significant = [zoomMagnitude > 0.06, panMagnitude > 0.05, rotationMagnitude > 0.05]
            .filter { $0 }.count
        if significant > 1 { return .complex }

        if zoomMagnitude > 0.06 {
            return scale > 1 ? .zoomIn : .zoomOut
        }
        if panMagnitude > 0.05 {
            if abs(translationX) >= abs(translationY) {
                return translationX > 0 ? .panRight : .panLeft
            }
            return translationY > 0 ? .panDown : .panUp
        }
        if rotationMagnitude > 0.05 { return .rotate }
        return .none
    }

    /// Confidence from fit quality and sample count. A clean fit over many pairs is trustworthy;
    /// a clean fit over two pairs might be luck.
    public var confidence: Double {
        guard sampleCount > 0 else { return 0 }
        let residualScore = max(0, 1 - residual * 8)
        let sampleScore = min(1, Double(sampleCount) / 5)
        return min(0.97, residualScore * 0.7 + sampleScore * 0.3)
    }

    public var basis: String {
        String(
            format: "similarity fit scale %.2f, translation (%.3f, %.3f), residual %.3f, n=%d",
            scale, translationX, translationY, residual, sampleCount
        )
    }
}

/// Text that persisted across a run of frames, grouped into one logical layer.
public struct DetectedTextTrack: Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double
    public var frame: NormalizedRect
    public var meanConfidence: Double
    /// Cap height as a fraction of frame height.
    public var sizeRatio: Double
    public var colorHex: String
    public var isLikelyWatermark: Bool
    public var observationCount: Int
    /// Number of distinct OCR extents seen during the entry window. Monotonic growth is the
    /// signature of word-by-word reveal.
    public var entryExtentGrowth: Int

    public var duration: Double { max(0, end - start) }

    public init(
        text: String, start: Double, end: Double, frame: NormalizedRect,
        meanConfidence: Double, sizeRatio: Double, colorHex: String,
        isLikelyWatermark: Bool, observationCount: Int, entryExtentGrowth: Int
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.frame = frame
        self.meanConfidence = meanConfidence
        self.sizeRatio = sizeRatio
        self.colorHex = colorHex
        self.isLikelyWatermark = isLikelyWatermark
        self.observationCount = observationCount
        self.entryExtentGrowth = entryExtentGrowth
    }
}

public struct ScenePalette: Sendable, Hashable {
    public var dominant: [String]
    public var brightness: Double
    public var saturation: Double
    public var contrast: Double

    public init(dominant: [String], brightness: Double, saturation: Double, contrast: Double) {
        self.dominant = dominant
        self.brightness = brightness
        self.saturation = saturation
        self.contrast = contrast
    }
}

public struct AudioAnalysis: Sendable {
    public var bpm: Double
    public var bpmConfidence: Double
    public var bpmBasis: String
    public var beats: [Double]
    public var downbeats: [Double]
    public var onsetStrength: [Double]
    public var energyCurve: [Double]
    public var hasSpeech: Bool
    public var speechConfidence: Double
    public var speechBasis: String

    public init(
        bpm: Double, bpmConfidence: Double, bpmBasis: String,
        beats: [Double], downbeats: [Double], onsetStrength: [Double],
        energyCurve: [Double], hasSpeech: Bool,
        speechConfidence: Double, speechBasis: String
    ) {
        self.bpm = bpm
        self.bpmConfidence = bpmConfidence
        self.bpmBasis = bpmBasis
        self.beats = beats
        self.downbeats = downbeats
        self.onsetStrength = onsetStrength
        self.energyCurve = energyCurve
        self.hasSpeech = hasSpeech
        self.speechConfidence = speechConfidence
        self.speechBasis = speechBasis
    }
}
