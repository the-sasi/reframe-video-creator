import Foundation

// MARK: - Sections

/// A track's macro structure, segmented from its energy envelope. This is what separates
/// "cut on every beat" from an edit that breathes with the song: the planner reads these to
/// decide shot length, motion intensity and transitions per region rather than globally.
public struct MusicSection: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// Low energy before the first sustained rise.
        case intro
        /// Energy rising toward a peak.
        case build
        /// Sustained high energy.
        case peak
        /// Energy falling away after a peak.
        case release
        /// Low energy at the end of the track.
        case outro
        /// Mid energy with no strong trend — verses, steady grooves.
        case steady

        public var displayName: String {
            switch self {
            case .intro: return "Intro"
            case .build: return "Build"
            case .peak: return "Peak"
            case .release: return "Release"
            case .outro: return "Outro"
            case .steady: return "Steady"
            }
        }
    }

    public var kind: Kind
    public var start: Double
    public var end: Double
    /// Mean normalised energy over the section, 0...1.
    public var intensity: Double

    public var id: String { "\(kind.rawValue)-\(Int(start * 1000))" }
    public var duration: Double { max(0, end - start) }

    public init(kind: Kind, start: Double, end: Double, intensity: Double) {
        self.kind = kind
        self.start = start
        self.end = end
        self.intensity = min(max(intensity, 0), 1)
    }
}

/// Segments an energy envelope into `MusicSection`s.
///
/// Deterministic and dependency-free on purpose: same envelope in, same sections out, testable
/// on any platform. The algorithm is threshold-and-trend, not ML — it only needs to be right
/// enough to pace an edit, and a wrong "steady vs build" call costs one transition choice, not
/// the edit.
public enum MusicSectionizer {

    /// - Parameters:
    ///   - energyCurve: normalised RMS envelope, 0...1-ish (re-normalised internally).
    ///   - samplesPerSecond: envelope rate. `AudioAnalyzer` emits 4 Hz.
    ///   - duration: track duration in seconds; the last section is clamped to it.
    public static func sections(
        energyCurve: [Double],
        samplesPerSecond: Double = 4,
        duration: Double
    ) -> [MusicSection] {
        guard duration > 0 else { return [] }
        guard energyCurve.count >= 8, samplesPerSecond > 0 else {
            // Too short to structure: one steady section keeps the planner honest instead of
            // making it special-case emptiness.
            let level = energyCurve.isEmpty ? 0.5 : average(energyCurve)
            return [MusicSection(kind: .steady, start: 0, end: duration, intensity: level)]
        }

        // 1. Smooth (moving average over ~1 s) and normalise to the curve's own range, so a
        //    quiet acoustic track and a loud club track segment the same way.
        let window = max(1, Int(samplesPerSecond.rounded()))
        let smoothed = movingAverage(energyCurve, window: window)
        guard let low = smoothed.min(), let high = smoothed.max(), high - low > 1e-6 else {
            return [MusicSection(kind: .steady, start: 0, end: duration, intensity: 0.5)]
        }
        let normalized = smoothed.map { ($0 - low) / (high - low) }

        // 2. Band each sample: low / mid / high by fixed thresholds on the normalised curve.
        //    Then merge runs shorter than `minSection` into their neighbours.
        let minSection = max(2.0, duration * 0.06)
        let minRun = max(1, Int(minSection * samplesPerSecond))
        var bands = normalized.map { level -> Int in
            if level < 0.35 { return 0 }
            if level < 0.72 { return 1 }
            return 2
        }
        bands = mergeShortRuns(bands, minRun: minRun)

        // 3. Runs → sections, classified by band plus trend and position.
        var result: [MusicSection] = []
        var runStart = 0
        for i in 1...bands.count {
            if i == bands.count || bands[i] != bands[runStart] {
                let startTime = Double(runStart) / samplesPerSecond
                let endTime = i == bands.count ? duration : Double(i) / samplesPerSecond
                let slice = Array(normalized[runStart..<i])
                let kind = classify(
                    band: bands[runStart],
                    slice: slice,
                    isFirst: result.isEmpty,
                    isLast: i == bands.count,
                    followsPeak: result.last?.kind == .peak
                )
                result.append(MusicSection(
                    kind: kind, start: startTime, end: min(endTime, duration),
                    intensity: average(slice)
                ))
                runStart = i
            }
        }
        // The envelope can end slightly before the track does; extend the last section.
        if var last = result.last, last.end < duration {
            last.end = duration
            result[result.count - 1] = last
        }
        return result
    }

    // MARK: - Pieces

    private static func classify(
        band: Int, slice: [Double], isFirst: Bool, isLast: Bool, followsPeak: Bool
    ) -> MusicSection.Kind {
        switch band {
        case 2:
            return .peak
        case 0:
            if isFirst { return .intro }
            if isLast { return .outro }
            return followsPeak ? .release : .steady
        default:
            // Mid band: the trend decides. Rising toward something → build; falling out of a
            // peak → release; flat → steady.
            let trend = slope(slice)
            if trend > 0.008 { return .build }
            if trend < -0.008 { return followsPeak ? .release : .steady }
            return followsPeak ? .release : .steady
        }
    }

    /// Least-squares slope per sample.
    static func slope(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }
        let meanX = (n - 1) / 2
        let meanY = average(values)
        var num = 0.0, den = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - meanX
            num += dx * (y - meanY)
            den += dx * dx
        }
        return den > 0 ? num / den : 0
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > window else { return values }
        var result = [Double]()
        result.reserveCapacity(values.count)
        var sum = 0.0
        for i in 0..<values.count {
            sum += values[i]
            if i >= window { sum -= values[i - window] }
            result.append(sum / Double(min(i + 1, window)))
        }
        return result
    }

    static func mergeShortRuns(_ bands: [Int], minRun: Int) -> [Int] {
        guard minRun > 1, bands.count > minRun else { return bands }
        var result = bands
        var changed = true
        // Repeated passes: merging one short run can expose another. Bounded — each pass
        // removes at least one run boundary or stops.
        var guardCount = 0
        while changed && guardCount < bands.count {
            changed = false
            guardCount += 1
            var runStart = 0
            var i = 1
            while i <= result.count {
                if i == result.count || result[i] != result[runStart] {
                    let runLength = i - runStart
                    if runLength < minRun {
                        // Absorb into the longer neighbour (or the only neighbour).
                        let before = runStart > 0 ? result[runStart - 1] : nil
                        let after = i < result.count ? result[i] : nil
                        let fill: Int?
                        switch (before, after) {
                        case (let b?, nil): fill = b
                        case (nil, let a?): fill = a
                        case (let b?, let a?):
                            // Prefer the band closer in level; ties go to the earlier one.
                            fill = abs(b - result[runStart]) <= abs(a - result[runStart]) ? b : a
                        case (nil, nil): fill = nil
                        }
                        if let fill, fill != result[runStart] {
                            for j in runStart..<i { result[j] = fill }
                            changed = true
                        }
                    }
                    runStart = i
                }
                i += 1
            }
        }
        return result
    }

    static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
