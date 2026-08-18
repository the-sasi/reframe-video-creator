import Foundation
import MediaIO
import RecipeCore

/// Per-frame measurements. Pass 1 produces these by streaming; pass 2 reasons over them
/// without touching I/O, which is what makes boundary detection unit-testable against
/// synthetic input with known cut positions.
public struct FrameMetric: Sendable, Hashable {
    public var index: Int
    public var time: Double
    /// Weighted HSV difference from the previous frame, 0...1.
    public var contentValue: Float
    public var lumaMean: Float
    public var lumaStdDev: Float

    public init(index: Int, time: Double, contentValue: Float, lumaMean: Float, lumaStdDev: Float) {
        self.index = index
        self.time = time
        self.contentValue = contentValue
        self.lumaMean = lumaMean
        self.lumaStdDev = lumaStdDev
    }
}

/// Shot-boundary detection.
///
/// The cut detector is a Swift reimplementation of the approach PySceneDetect calls
/// `AdaptiveDetector`: weighted mean absolute HSV difference between adjacent frames, compared
/// against a *rolling average* of neighbouring differences rather than a fixed threshold. The
/// rolling comparison is what stops fast camera motion from reading as a cut on every frame.
///
/// Gradual transitions get a separate pass, because cuts and dissolves need different
/// detectors — the literature is consistent that abrupt cuts are easy and gradual transitions
/// are hard, and a single threshold cannot do both.
public struct SceneDetector: Sendable {

    public struct Parameters: Sendable {
        /// Weights for hue, saturation and value in the content difference.
        public var hueWeight: Float
        public var saturationWeight: Float
        public var valueWeight: Float

        /// A frame difference below this is never a cut, however it compares to its neighbours.
        /// Without this floor, a static shot's tiny noise-level differences produce a huge
        /// ratio against an even tinier rolling average, and the detector fires on nothing.
        public var minContentValue: Float
        /// A cut needs to exceed the rolling average by this factor.
        public var adaptiveRatio: Float
        /// Frames either side used for the rolling average.
        public var rollingWindow: Int
        /// Shots shorter than this are merged. Below ~4 frames a "shot" is usually a flash or a
        /// one-frame artefact, not an edit.
        public var minimumShotDuration: Double

        /// Elevated-but-not-a-cut differences above this may form a gradual transition.
        public var gradualMinValue: Float
        /// Mean blend residual below this confirms a dissolve.
        public var dissolveResidualThreshold: Float
        /// Luma standard deviation below this means the frame is essentially flat — a fade.
        public var flatFrameStdDev: Float
        /// A flat frame also has to be *dark* or *bright* to be a fade. A dim, low-contrast shot
        /// (a night scene, a plain wall) is flat but is not fading anywhere.
        public var fadeExtremeLuma: Float
        /// Longest run, in seconds, that can still be a gradual transition. Anything longer is
        /// camera motion or action, however elevated the frame difference.
        public var maxGradualDuration: Double
        /// A gradual transition has to *arrive* somewhere: the frames either side of the run must
        /// differ by at least this much, or the run was a wobble inside one shot.
        public var gradualEndpointMinDifference: Float

        public init(
            hueWeight: Float = 1.0,
            saturationWeight: Float = 1.0,
            valueWeight: Float = 1.0,
            minContentValue: Float = 0.055,
            adaptiveRatio: Float = 3.0,
            rollingWindow: Int = 2,
            minimumShotDuration: Double = 0.15,
            gradualMinValue: Float = 0.016,
            dissolveResidualThreshold: Float = 0.028,
            flatFrameStdDev: Float = 0.035,
            fadeExtremeLuma: Float = 0.14,
            maxGradualDuration: Double = 1.6,
            gradualEndpointMinDifference: Float = 0.06
        ) {
            self.hueWeight = hueWeight
            self.saturationWeight = saturationWeight
            self.valueWeight = valueWeight
            self.minContentValue = minContentValue
            self.adaptiveRatio = adaptiveRatio
            self.rollingWindow = rollingWindow
            self.minimumShotDuration = minimumShotDuration
            self.gradualMinValue = gradualMinValue
            self.dissolveResidualThreshold = dissolveResidualThreshold
            self.flatFrameStdDev = flatFrameStdDev
            self.fadeExtremeLuma = fadeExtremeLuma
            self.maxGradualDuration = maxGradualDuration
            self.gradualEndpointMinDifference = gradualEndpointMinDifference
        }

        public static let `default` = Parameters()
    }

    public let parameters: Parameters

    public init(parameters: Parameters = .default) {
        self.parameters = parameters
    }

    // MARK: - Pass 1: streaming measurement

    /// Streams the reference once, producing per-frame metrics and retained luma thumbnails.
    ///
    /// Thumbnails are 24x42 floats — 4 KB a frame — so a 60 s reference costs ~7 MB to keep all
    /// of them. That buys a second pass over the whole timeline for gradual-transition
    /// detection, which a streaming-only design could not do without a much fiddlier ring
    /// buffer and a worse detector.
    public func measure(
        source: MediaSource,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (metrics: [FrameMetric], thumbs: [[Float]]) {
        let stream = FrameStream(source: source, configuration: .sceneDetection)
        let expected = stream.estimatedFrameCount

        var metrics: [FrameMetric] = []
        var thumbs: [[Float]] = []
        metrics.reserveCapacity(expected)
        thumbs.reserveCapacity(expected)

        var previous: FrameSignature?

        for try await frame in stream.frames() {
            guard let signature = PixelAccess.signature(from: frame.pixelBuffer) else { continue }

            let contentValue: Float
            if let previous, previous.pixelCount == signature.pixelCount {
                let dh = PixelAccess.meanCircularHueDifference(previous.hue, signature.hue)
                let ds = PixelAccess.meanAbsoluteDifference(previous.saturation, signature.saturation)
                let dv = PixelAccess.meanAbsoluteDifference(previous.value, signature.value)
                let totalWeight = parameters.hueWeight + parameters.saturationWeight + parameters.valueWeight
                contentValue = (dh * parameters.hueWeight
                                + ds * parameters.saturationWeight
                                + dv * parameters.valueWeight) / totalWeight
            } else {
                contentValue = 0
            }

            metrics.append(
                FrameMetric(
                    index: frame.index,
                    time: frame.time,
                    contentValue: contentValue,
                    lumaMean: signature.lumaMean,
                    lumaStdDev: signature.lumaStdDev
                )
            )
            thumbs.append(signature.lumaThumb)
            previous = signature

            if frame.index % 15 == 0 {
                progress?(frame.index, expected)
            }
        }

        return (metrics, thumbs)
    }

    // MARK: - Pass 2: boundary detection (pure)

    /// Finds shot boundaries. Pure function of the metrics — no I/O, no framework calls, so
    /// tests can feed it a synthetic sequence with a cut at exactly frame 47 and assert exactly
    /// frame 47.
    public func detectBoundaries(
        metrics: [FrameMetric],
        thumbs: [[Float]],
        duration: Double
    ) -> [DetectedBoundary] {
        guard metrics.count > 2 else { return [.atStart()] }

        var boundaries: [DetectedBoundary] = [.atStart()]
        var cutIndices = Set<Int>()

        // --- Abrupt cuts, adaptive threshold ---
        for i in metrics.indices {
            let value = metrics[i].contentValue
            guard value >= parameters.minContentValue else { continue }

            let average = rollingAverage(metrics: metrics, excluding: i)
            guard average > 1e-6 else { continue }
            let ratio = value / average
            guard ratio >= parameters.adaptiveRatio else { continue }

            cutIndices.insert(i)
            // Ratio maps to confidence: at exactly the threshold we are barely sure; at 3x the
            // threshold the frame is unambiguously a different shot.
            let confidence = min(0.98, 0.62 + Double((ratio - parameters.adaptiveRatio) / 8))
            boundaries.append(
                DetectedBoundary(
                    kind: .cut,
                    time: metrics[i].time,
                    duration: 0,
                    confidence: confidence,
                    basis: String(
                        format: "frame delta %.3f, %.1fx rolling average %.3f",
                        value, ratio, average
                    )
                )
            )
        }

        // --- Gradual transitions ---
        boundaries.append(
            contentsOf: detectGradualTransitions(
                metrics: metrics, thumbs: thumbs, excluding: cutIndices
            )
        )

        boundaries.sort { $0.time < $1.time }
        return mergeTooCloseBoundaries(boundaries, duration: duration)
    }

    /// Mean of neighbouring frame differences, excluding the frame under test so a genuine cut
    /// does not inflate its own baseline.
    private func rollingAverage(metrics: [FrameMetric], excluding index: Int) -> Float {
        let window = parameters.rollingWindow
        let lower = max(0, index - window)
        let upper = min(metrics.count - 1, index + window)
        var sum: Float = 0
        var count: Float = 0
        for j in lower...upper where j != index {
            sum += metrics[j].contentValue
            count += 1
        }
        return count > 0 ? sum / count : 0
    }

    /// Dissolves and fades.
    ///
    /// Finds runs of moderately-elevated frame difference, then asks two questions of each run:
    ///
    /// 1. **Is it a fade?** Luma standard deviation collapsing toward zero means the frame is
    ///    becoming flat, and the luma mean says whether it is going to black or to white.
    /// 2. **Is it a dissolve?** A true cross-fade satisfies `F(t) ≈ (1−α)·F(t₀) + α·F(t₁)`. If
    ///    the mean residual of that linear-blend model is small, it is a dissolve; if it is
    ///    large, the elevated difference was camera motion or action, not an edit.
    ///
    /// A run that fits neither model produces **no boundary**. Elevated frame difference that is
    /// not a fade and not a blend is camera motion or action inside one shot; asserting an edit
    /// there would be a phantom cut. Runs longer than `maxGradualDuration`, or whose endpoints
    /// look alike, are rejected before either test for the same reason.
    public func detectGradualTransitions(
        metrics: [FrameMetric],
        thumbs: [[Float]],
        excluding cutIndices: Set<Int>
    ) -> [DetectedBoundary] {
        guard metrics.count == thumbs.count, metrics.count > 6 else { return [] }

        var results: [DetectedBoundary] = []
        var i = 1

        while i < metrics.count {
            guard metrics[i].contentValue >= parameters.gradualMinValue,
                  !cutIndices.contains(i) else {
                i += 1
                continue
            }

            // Extend the run while difference stays elevated.
            var j = i
            while j + 1 < metrics.count,
                  metrics[j + 1].contentValue >= parameters.gradualMinValue,
                  !cutIndices.contains(j + 1) {
                j += 1
            }

            let runLength = j - i + 1
            // Fewer than 3 frames is not a gradual transition, it is noise or a fast pan.
            guard runLength >= 3 else {
                i = j + 1
                continue
            }

            let startIdx = max(0, i - 1)
            let endIdx = min(metrics.count - 1, j + 1)
            let from = thumbs[startIdx]
            let to = thumbs[endIdx]
            let span = Float(endIdx - startIdx)
            let runSeconds = metrics[endIdx].time - metrics[startIdx].time

            // A run longer than any plausible transition is motion, not an edit. Skipping it
            // wholesale — rather than reporting an "unknown gradual" boundary at its end — is
            // what stops a two-second pan from splitting one shot into two.
            guard runSeconds <= parameters.maxGradualDuration else {
                i = j + 1
                continue
            }

            // Fade test first: a fade is a special case of a dissolve where one end is flat,
            // and naming it correctly is more useful than calling everything a dissolve.
            let middle = (startIdx + endIdx) / 2
            let minStdDev = metrics[startIdx...endIdx].map(\.lumaStdDev).min() ?? 1
            if minStdDev < parameters.flatFrameStdDev {
                let flatIndex = metrics[startIdx...endIdx]
                    .min { $0.lumaStdDev < $1.lumaStdDev }?.index ?? middle
                let flatMean = metrics[min(flatIndex, metrics.count - 1)].lumaMean
                let goingDark = flatMean < 0.5
                let isExtreme = flatMean <= parameters.fadeExtremeLuma
                    || flatMean >= 1 - parameters.fadeExtremeLuma

                if isExtreme {
                    let isFadeIn = flatIndex <= middle
                    let kind: DetectedBoundary.Kind = goingDark
                        ? (isFadeIn ? .fadeFromBlack : .fadeToBlack)
                        : (isFadeIn ? .fadeFromWhite : .fadeToWhite)

                    results.append(
                        DetectedBoundary(
                            kind: kind,
                            time: metrics[isFadeIn ? endIdx : startIdx].time,
                            duration: runSeconds,
                            confidence: min(0.92, 0.60 + Double((parameters.flatFrameStdDev - minStdDev) * 6)),
                            basis: String(
                                format: "luma std dev fell to %.3f over %d frames, mean %.2f",
                                minStdDev, runLength, flatMean
                            )
                        )
                    )
                    i = j + 1
                    continue
                }
                // Flat but mid-grey: a dim, low-contrast shot. Fall through to the dissolve
                // test rather than calling it a fade.
            }

            // A transition ends somewhere different from where it began. If the frames either
            // side of the run are nearly the same picture, the elevated difference was a wobble
            // — a flash, a hand pass, a small camera bump — inside one shot.
            let endpointDifference = PixelAccess.meanAbsoluteDifference(from, to)
            guard endpointDifference >= parameters.gradualEndpointMinDifference else {
                i = j + 1
                continue
            }

            // Dissolve test: how well does the linear blend model explain the middle frames?
            var residualSum: Float = 0
            var residualCount: Float = 0
            for k in (startIdx + 1)..<endIdx {
                let alpha = Float(k - startIdx) / span
                residualSum += PixelAccess.blendResidual(
                    frame: thumbs[k], from: from, to: to, alpha: alpha
                )
                residualCount += 1
            }
            let meanResidual = residualCount > 0 ? residualSum / residualCount : .infinity

            if meanResidual <= parameters.dissolveResidualThreshold {
                let confidence = min(
                    0.94,
                    0.58 + Double((parameters.dissolveResidualThreshold - meanResidual) * 12)
                )
                results.append(
                    DetectedBoundary(
                        kind: .dissolve,
                        time: metrics[endIdx].time,
                        duration: runSeconds,
                        confidence: confidence,
                        basis: String(
                            format: "blend residual %.3f over %d frames", meanResidual, runLength
                        )
                    )
                )
            }
            // Elevated difference that fits neither model is left alone. An earlier version
            // reported it as an "unknown gradual" boundary at 0.34 confidence, which the binder
            // then rendered as a cut — so every burst of camera motion became a phantom edit.
            // Nothing is asserted that was not fitted.

            i = j + 1
        }

        return results
    }

    /// Drops boundaries that would produce a shot shorter than `minimumShotDuration`, keeping
    /// the higher-confidence one of each pair.
    private func mergeTooCloseBoundaries(
        _ boundaries: [DetectedBoundary], duration: Double
    ) -> [DetectedBoundary] {
        var result: [DetectedBoundary] = []
        for boundary in boundaries {
            guard let last = result.last else {
                result.append(boundary)
                continue
            }
            if boundary.time - last.time < parameters.minimumShotDuration {
                if boundary.confidence > last.confidence, last.kind != .start {
                    result[result.count - 1] = boundary
                }
            } else {
                result.append(boundary)
            }
        }
        // A boundary in the last fraction of a second creates a runt final shot.
        return result.filter { $0.kind == .start || duration - $0.time >= parameters.minimumShotDuration }
    }

    /// Turns boundaries into shots.
    public func shots(from boundaries: [DetectedBoundary], duration: Double) -> [DetectedShot] {
        guard !boundaries.isEmpty else {
            return [DetectedShot(index: 0, start: 0, end: duration, boundaryIn: .atStart())]
        }
        return boundaries.enumerated().map { index, boundary in
            let end = index + 1 < boundaries.count ? boundaries[index + 1].time : duration
            return DetectedShot(
                index: index,
                start: boundary.time,
                end: end,
                boundaryIn: boundary
            )
        }
    }
}
