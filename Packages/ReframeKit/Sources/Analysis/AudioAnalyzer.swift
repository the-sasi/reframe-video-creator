import Accelerate
import AVFoundation
import Foundation
import MediaIO
import RecipeCore

/// Beat, tempo and speech analysis — entirely deterministic, no model, no licence.
///
/// The obvious libraries here are licence-hostile (aubio is GPL, essentia AGPL) or Python-only
/// (librosa). The algorithm, though, is textbook and short, and every step of it is one
/// `Accelerate` call:
///
///     decode -> mono 22.05 kHz -> STFT (1024/512, Hann)
///            -> log magnitude -> spectral flux (positive differences)
///            -> adaptive-mean normalisation -> onset envelope
///            -> autocorrelation over 60-200 BPM, octave-corrected -> tempo
///            -> comb-filter phase search -> beat grid -> snap to onset peaks
///
/// Same audio in, same beat grid out, every run. That determinism is not incidental: the
/// recipe's cut timings hang off this grid, and a beat grid that wobbled between runs would
/// make the whole recipe non-reproducible.
public struct AudioAnalyzer: Sendable {

    private static let fftSize = 1024
    private static let hopSize = 512
    /// 22 050 / 512 = 43.07 onset-envelope samples per second.
    private static var envelopeRate: Double { AudioDecoder.analysisSampleRate / Double(hopSize) }

    private static let minBPM = 60.0
    private static let maxBPM = 200.0

    public init() {}

    public func analyze(source: MediaSource) async throws -> AudioAnalysis? {
        guard source.info.hasAudio else { return nil }
        guard let decoded = try await AudioDecoder.decodeMono(asset: source.asset) else {
            return nil
        }
        let audio = AudioDecoder.normalized(decoded)
        guard audio.samples.count > Self.fftSize * 4 else { return nil }

        let spectrogram = computeSpectrogram(audio.samples)
        guard spectrogram.frameCount > 8 else { return nil }

        let onset = onsetEnvelope(from: spectrogram)
        let (bpm, tempoConfidence, tempoBasis) = estimateTempo(onset: onset)
        let beats = beatGrid(onset: onset, bpm: bpm, duration: audio.duration)
        let downbeats = estimateDownbeats(beats: beats, onset: onset)
        let energy = energyCurve(audio.samples, sampleRate: audio.sampleRate)
        let speech = detectSpeech(spectrogram: spectrogram, onset: onset)

        return AudioAnalysis(
            bpm: bpm,
            bpmConfidence: tempoConfidence,
            bpmBasis: tempoBasis,
            beats: beats,
            downbeats: downbeats,
            onsetStrength: onset.map(Double.init),
            energyCurve: energy,
            hasSpeech: speech.present,
            speechConfidence: speech.confidence,
            speechBasis: speech.basis
        )
    }

    // MARK: - STFT

    struct Spectrogram {
        var magnitudes: [[Float]]   // [frame][bin]
        var frameCount: Int { magnitudes.count }
        var binCount: Int { magnitudes.first?.count ?? 0 }
        var binWidth: Double
    }

    func computeSpectrogram(_ samples: [Float]) -> Spectrogram {
        let n = Self.fftSize
        let halfN = n / 2
        let log2n = vDSP_Length(log2(Double(n)))

        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return Spectrogram(magnitudes: [], binWidth: 0)
        }

        // Hann window: without it, every frame boundary is a discontinuity and the spectrum
        // smears across all bins, which buries the onsets we are looking for.
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var magnitudes: [[Float]] = []
        magnitudes.reserveCapacity(max(0, (samples.count - n) / Self.hopSize))

        var windowed = [Float](repeating: 0, count: n)
        var realIn = [Float](repeating: 0, count: halfN)
        var imagIn = [Float](repeating: 0, count: halfN)
        var realOut = [Float](repeating: 0, count: halfN)
        var imagOut = [Float](repeating: 0, count: halfN)

        var offset = 0
        while offset + n <= samples.count {
            vDSP_vmul(
                Array(samples[offset..<(offset + n)]), 1,
                window, 1, &windowed, 1, vDSP_Length(n)
            )

            var frameMagnitudes = [Float](repeating: 0, count: halfN)

            realIn.withUnsafeMutableBufferPointer { realInPtr in
            imagIn.withUnsafeMutableBufferPointer { imagInPtr in
            realOut.withUnsafeMutableBufferPointer { realOutPtr in
            imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                var input = DSPSplitComplex(
                    realp: realInPtr.baseAddress!, imagp: imagInPtr.baseAddress!
                )
                var output = DSPSplitComplex(
                    realp: realOutPtr.baseAddress!, imagp: imagOutPtr.baseAddress!
                )
                // Real-to-split-complex: pack the real signal as interleaved pairs.
                windowed.withUnsafeBytes { rawBuffer in
                    let typed = rawBuffer.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(typed.baseAddress!, 2, &input, 1, vDSP_Length(halfN))
                }
                fft.forward(input: input, output: &output)
                vDSP_zvabs(&output, 1, &frameMagnitudes, 1, vDSP_Length(halfN))
            }}}}

            magnitudes.append(frameMagnitudes)
            offset += Self.hopSize
        }

        return Spectrogram(
            magnitudes: magnitudes,
            binWidth: AudioDecoder.analysisSampleRate / Double(n)
        )
    }

    // MARK: - Onset envelope

    /// Spectral flux with logarithmic compression and adaptive-mean normalisation.
    ///
    /// Only *positive* differences count. A note starting is an onset; a note ending is not,
    /// and counting both would put a spurious peak on every note release.
    ///
    /// Log compression matters more than it looks: without it, loud passages dominate the
    /// envelope entirely and a quiet intro contributes no detectable beats at all.
    func onsetEnvelope(from spectrogram: Spectrogram) -> [Float] {
        let frames = spectrogram.frameCount
        guard frames > 1 else { return [] }
        let bins = spectrogram.binCount

        var flux = [Float](repeating: 0, count: frames)
        var previous = [Float](repeating: 0, count: bins)

        for f in 0..<frames {
            var current = [Float](repeating: 0, count: bins)
            for b in 0..<bins {
                current[b] = log1pf(spectrogram.magnitudes[f][b] * 100)
            }
            if f > 0 {
                var sum: Float = 0
                for b in 0..<bins {
                    let d = current[b] - previous[b]
                    if d > 0 { sum += d }
                }
                flux[f] = sum / Float(bins)
            }
            previous = current
        }

        // Subtract a local mean, then rectify. This is what makes the detector work on music
        // that gets louder — an absolute threshold would fire constantly in the chorus and
        // never in the verse.
        let windowFrames = max(3, Int(Self.envelopeRate * 0.35))
        var normalized = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let lower = max(0, f - windowFrames)
            let upper = min(frames - 1, f + windowFrames)
            var localMean: Float = 0
            vDSP_meanv(
                Array(flux[lower...upper]), 1, &localMean, vDSP_Length(upper - lower + 1)
            )
            normalized[f] = max(0, flux[f] - localMean)
        }

        // Peak-normalise so tempo scoring is comparable across references.
        var peak: Float = 0
        vDSP_maxv(normalized, 1, &peak, vDSP_Length(frames))
        if peak > 1e-6 {
            var scale = 1 / peak
            vDSP_vsmul(normalized, 1, &scale, &normalized, 1, vDSP_Length(frames))
        }
        return normalized
    }

    // MARK: - Tempo

    /// Autocorrelation of the onset envelope, with an octave prior.
    ///
    /// The octave problem is the whole difficulty in tempo estimation: 70 BPM and 140 BPM
    /// explain the same onsets equally well, and raw autocorrelation cannot choose. We apply a
    /// log-normal prior centred at 120 BPM — the standard fix, and empirically right for the
    /// kind of music that soundtracks a Reel.
    func estimateTempo(onset: [Float]) -> (bpm: Double, confidence: Double, basis: String) {
        let rate = Self.envelopeRate
        let minLag = max(2, Int(60.0 / Self.maxBPM * rate))
        let maxLag = min(onset.count / 2, Int(60.0 / Self.minBPM * rate))

        guard maxLag > minLag, onset.count > maxLag * 2 else {
            return (120, 0.1, "envelope too short for tempo estimation")
        }

        // Precompute the normalised autocorrelation once per lag. Recomputing it for the
        // confidence pass, as an earlier version did, roughly doubled the cost for nothing.
        var correlations = [Double](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var sum = 0.0
            let count = onset.count - lag
            guard count > 0 else { continue }
            for i in 0..<count {
                sum += Double(onset[i]) * Double(onset[i + lag])
            }
            correlations[lag] = sum / Double(count)
        }

        var bestLag = minLag
        var bestScore = -Double.infinity
        var rawBestLag = minLag
        var rawBestScore = -Double.infinity

        for lag in minLag...maxLag {
            let normalized = correlations[lag]

            if normalized > rawBestScore {
                rawBestScore = normalized
                rawBestLag = lag
            }

            // Log-normal prior over BPM, centred at 120 with a wide sigma so unusual-but-real
            // tempos are penalised rather than excluded.
            let bpm = 60.0 * rate / Double(lag)
            let logRatio = log(bpm / 120.0)
            let prior = exp(-(logRatio * logRatio) / (2 * 0.42 * 0.42))
            let score = normalized * prior

            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        // Parabolic interpolation around the peak, for sub-frame lag resolution.
        //
        // Integer lags quantise the tempo badly at the fast end: the envelope runs at ~43 Hz,
        // so near 140 BPM two adjacent lags are about 4 BPM apart and no integer lag can land
        // within 2 BPM of the truth. Fitting a parabola through the peak and its two
        // neighbours recovers the true maximum to a fraction of a frame.
        var refinedLag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let before = correlations[bestLag - 1]
            let peak = correlations[bestLag]
            let after = correlations[bestLag + 1]
            let denominator = before - 2 * peak + after
            if abs(denominator) > 1e-12 {
                let offset = 0.5 * (before - after) / denominator
                // A well-formed peak puts the vertex within half a sample either side;
                // anything beyond that means the fit is not describing a peak at all.
                refinedLag += min(max(offset, -0.5), 0.5)
            }
        }

        let bpm = 60.0 * rate / refinedLag

        // Confidence: how much the chosen peak stands out from the mean correlation.
        var meanCorrelation = 0.0
        var samples = 0
        for lag in Swift.stride(from: minLag, through: maxLag, by: max(1, (maxLag - minLag) / 40)) {
            meanCorrelation += correlations[lag]
            samples += 1
        }
        meanCorrelation /= Double(max(1, samples))

        let prominence = meanCorrelation > 1e-9 ? rawBestScore / meanCorrelation : 1
        var confidence = min(0.94, max(0.15, (prominence - 1) / 2.5))

        // If the prior overrode the raw peak, say so and take a confidence hit — we made a
        // judgement call the data did not make for us.
        let overrodeOctave = abs(bestLag - rawBestLag) > 2
        if overrodeOctave { confidence *= 0.82 }

        let onsetCount = onset.filter { $0 > 0.25 }.count
        let basis = String(
            format: "autocorrelation peak %.3fs, prominence %.1fx, %d onsets%@",
            Double(bestLag) / rate, prominence, onsetCount,
            overrodeOctave ? ", octave-corrected" : ""
        )
        return (bpm, confidence, basis)
    }

    /// Places beats by searching for the phase that best explains the onsets, then nudging each
    /// beat onto the nearest local peak.
    ///
    /// The nudge matters: a perfectly periodic grid drifts off real music within a few bars
    /// because human performances are not metronomic. Snapping to onsets keeps the grid honest
    /// while the period keeps it regular.
    func beatGrid(onset: [Float], bpm: Double, duration: Double) -> [Double] {
        let rate = Self.envelopeRate
        let period = 60.0 / bpm * rate
        guard period >= 2, onset.count > Int(period) else { return [] }

        // Comb-filter phase search.
        var bestOffset = 0.0
        var bestScore = -Double.infinity
        let offsetSteps = max(1, Int(period))
        for step in 0..<offsetSteps {
            let offset = Double(step)
            var score = 0.0
            var position = offset
            while position < Double(onset.count) {
                score += Double(onset[Int(position)])
                position += period
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }

        var beats: [Double] = []
        var position = bestOffset
        let snapRadius = max(1, Int(period * 0.08))

        while position < Double(onset.count) {
            let center = Int(position)
            var peakIndex = center
            var peakValue = onset[min(center, onset.count - 1)]
            let lower = max(0, center - snapRadius)
            let upper = min(onset.count - 1, center + snapRadius)
            for i in lower...upper where onset[i] > peakValue {
                peakValue = onset[i]
                peakIndex = i
            }

            let time = Double(peakIndex) / rate
            if time <= duration { beats.append(time) }

            // Re-anchor to the peak actually found rather than advancing from the original
            // offset. Stepping by an ideal period from a fixed origin lets small per-beat
            // deviations accumulate, so the grid slides progressively out of phase across a
            // track — and real performances are never exactly metronomic, so the drift is
            // guaranteed rather than hypothetical.
            position = Double(peakIndex) + period
        }
        return beats
    }

    /// Every fourth beat, phased to whichever of the first four carries the most onset energy.
    /// A 4/4 assumption, which is correct for essentially all short-form soundtrack music and
    /// is why this is offered as a hint rather than a claim.
    func estimateDownbeats(beats: [Double], onset: [Float]) -> [Double] {
        guard beats.count >= 4 else { return beats }
        let rate = Self.envelopeRate

        var bestPhase = 0
        var bestEnergy = -Float.infinity
        for phase in 0..<4 {
            var energy: Float = 0
            var index = phase
            while index < beats.count {
                let frame = Int(beats[index] * rate)
                if frame < onset.count { energy += onset[frame] }
                index += 4
            }
            if energy > bestEnergy {
                bestEnergy = energy
                bestPhase = phase
            }
        }

        return Swift.stride(from: bestPhase, to: beats.count, by: 4).map { beats[$0] }
    }

    // MARK: - Energy

    /// RMS at 4 Hz. Drives the energy readout and could later drive intensity-matched effects.
    func energyCurve(_ samples: [Float], sampleRate: Double) -> [Double] {
        let windowSize = Int(sampleRate * 0.25)
        guard windowSize > 0, samples.count > windowSize else { return [] }

        var curve: [Double] = []
        curve.reserveCapacity(samples.count / windowSize)
        var offset = 0
        while offset + windowSize <= samples.count {
            var rms: Float = 0
            vDSP_rmsqv(Array(samples[offset..<(offset + windowSize)]), 1, &rms, vDSP_Length(windowSize))
            curve.append(Double(rms))
            offset += windowSize
        }
        return curve
    }

    // MARK: - Speech

    /// Deterministic speech-presence heuristic.
    ///
    /// Two signals, both cheap and both already computed:
    ///
    /// 1. **Band ratio.** Speech energy concentrates in 300–3400 Hz. Music spreads much wider.
    /// 2. **Syllabic modulation.** Speech has a strong 3–8 Hz amplitude rhythm (syllables);
    ///    music's onset periodicity sits at the beat, typically 1.5–3.5 Hz.
    ///
    /// This is honestly a heuristic and is reported at moderate confidence. Apple's
    /// `SpeechDetector` (iOS 26) would be more accurate, and it lives behind
    /// `IntelligenceProvider` where optional things belong — the recipe does not depend on it
    /// being available, and this keeps the Analysis module free of the Speech framework.
    func detectSpeech(spectrogram: Spectrogram, onset: [Float]) -> (present: Bool, confidence: Double, basis: String) {
        guard spectrogram.frameCount > 8, spectrogram.binWidth > 0 else {
            return (false, 0.2, "insufficient audio for speech heuristic")
        }

        let lowBin = Int(300 / spectrogram.binWidth)
        let highBin = min(spectrogram.binCount - 1, Int(3400 / spectrogram.binWidth))
        guard highBin > lowBin else {
            return (false, 0.2, "spectrogram too coarse for band analysis")
        }

        var bandRatioSum = 0.0
        for frame in spectrogram.magnitudes {
            let total = frame.reduce(0, +)
            guard total > 1e-6 else { continue }
            let band = frame[lowBin...highBin].reduce(0, +)
            bandRatioSum += Double(band / total)
        }
        let bandRatio = bandRatioSum / Double(spectrogram.frameCount)

        // Dominant modulation frequency of the onset envelope.
        let rate = Self.envelopeRate
        var peakFrequency = 0.0
        var peakScore = -Double.infinity
        for lagFrames in Swift.stride(from: max(2, Int(rate / 10)), through: Int(rate / 1.5), by: 1) {
            var correlation = 0.0
            for i in 0..<(onset.count - lagFrames) {
                correlation += Double(onset[i]) * Double(onset[i + lagFrames])
            }
            let normalized = correlation / Double(max(1, onset.count - lagFrames))
            if normalized > peakScore {
                peakScore = normalized
                peakFrequency = rate / Double(lagFrames)
            }
        }

        let bandSuggestsSpeech = bandRatio > 0.62
        let modulationSuggestsSpeech = peakFrequency > 3.0 && peakFrequency < 8.0
        let present = bandSuggestsSpeech && modulationSuggestsSpeech

        // Both signals agreeing is worth more than either alone, and neither is strong enough
        // to be confident on its own.
        let confidence: Double = {
            switch (bandSuggestsSpeech, modulationSuggestsSpeech) {
            case (true, true): return 0.74
            case (false, false): return 0.71
            default: return 0.45
            }
        }()

        return (
            present,
            confidence,
            String(
                format: "300-3400Hz band ratio %.2f, modulation peak %.1fHz",
                bandRatio, peakFrequency
            )
        )
    }
}
