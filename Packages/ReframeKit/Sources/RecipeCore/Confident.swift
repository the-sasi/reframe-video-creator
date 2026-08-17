import Foundation

/// A value the analyser inferred rather than measured, carrying how sure it is and why.
///
/// Every inferred property in `EditRecipe` is wrapped in this. There is deliberately no way to
/// store a bare inferred value — if the analyser guessed, the schema forces it to say so.
///
/// `basis` is not decoration. It is what makes a wrong result debuggable six months later, and
/// it is what the "Guessed" badge shows when tapped:
///
///     "similarity fit scale 1.00->1.17, residual 0.031, n=6"
///     -> "I think this is a push-in because the frame scaled up 17% over six sampled frames."
public struct Confident<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var value: Value
    /// 0...1. See `ConfidenceBand` for what each range means behaviourally.
    public var confidence: Double
    /// Terse, machine-generated explanation of how `value` was derived.
    public var basis: String

    public init(_ value: Value, confidence: Double, basis: String) {
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
        self.basis = basis
    }

    /// For values that were read directly rather than inferred — frame rate, dimensions.
    public static func measured(_ value: Value, _ basis: String = "measured") -> Confident<Value> {
        Confident(value, confidence: 1.0, basis: basis)
    }

    public var band: ConfidenceBand { ConfidenceBand(confidence) }

    /// Whether the binder should use `value` or reach for the declared fallback.
    public var isTrustworthy: Bool { confidence >= ConfidenceBand.fallbackThreshold }

    public func map<T>(_ transform: (Value) -> T) -> Confident<T> {
        Confident<T>(transform(value), confidence: confidence, basis: basis)
    }
}

/// Confidence drives behaviour, not just presentation.
public enum ConfidenceBand: String, Codable, Sendable, Hashable {
    /// >= 0.80 — stated plainly, applied.
    case confident
    /// 0.55..<0.80 — badged "Guessed", still applied.
    case likely
    /// 0.30..<0.55 — badged, offered for review, **fallback substituted**.
    case uncertain
    /// < 0.30 — hidden from the summary, discarded in favour of a safe default.
    case speculative

    /// Below this, the binder substitutes the declared safe fallback.
    public static let fallbackThreshold = 0.55
    /// Below this, the value is not shown to the user at all.
    public static let displayThreshold = 0.30

    public init(_ confidence: Double) {
        switch confidence {
        case 0.80...: self = .confident
        case 0.55..<0.80: self = .likely
        case 0.30..<0.55: self = .uncertain
        default: self = .speculative
        }
    }

    /// Whether the UI should mark this as an inference rather than a fact.
    public var needsGuessedBadge: Bool { self != .confident }
}

/// Roll-up of how much of a recipe was inferred versus measured. Surfaced on the analysis
/// summary so the user knows which parts to check.
public struct ConfidenceReport: Codable, Sendable, Hashable {
    public var overall: Double
    public var scenes: Double
    public var motion: Double
    public var text: Double
    public var audio: Double
    /// Key path of the least-certain inference, e.g. `"text.style.category"`. Drives the
    /// "check this first" hint on the summary screen.
    public var weakest: String

    public init(
        overall: Double, scenes: Double, motion: Double,
        text: Double, audio: Double, weakest: String
    ) {
        self.overall = overall
        self.scenes = scenes
        self.motion = motion
        self.text = text
        self.audio = audio
        self.weakest = weakest
    }

    /// Weighted so that scene detection — the thing we are actually good at and the thing the
    /// whole recipe hangs off — dominates, and text styling, which is genuinely hard, does not
    /// drag the headline number down disproportionately.
    public static func rollUp(scenes: Double, motion: Double, text: Double, audio: Double) -> ConfidenceReport {
        let weights: [(String, Double, Double)] = [
            ("scenes", scenes, 0.40),
            ("motion", motion, 0.25),
            ("audio", audio, 0.20),
            ("text", text, 0.15),
        ]
        let overall = weights.reduce(0) { $0 + $1.1 * $1.2 }
        let weakest = weights.min { $0.1 < $1.1 }?.0 ?? "scenes"
        return ConfidenceReport(
            overall: overall, scenes: scenes, motion: motion,
            text: text, audio: audio, weakest: weakest
        )
    }
}
