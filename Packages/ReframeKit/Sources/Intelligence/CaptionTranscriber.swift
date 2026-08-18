import AVFoundation
import Foundation
import MediaIO
import RecipeCore

#if canImport(Speech)
import Speech
#endif

/// A timed run of speech.
public struct TranscribedSegment: Sendable, Hashable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Per-word start times, when the recogniser supplied them. Same count as words in `text`.
    public var wordStarts: [Double]?

    public init(text: String, start: Double, end: Double, wordStarts: [Double]? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.wordStarts = wordStarts
    }
}

/// On-device speech-to-text for captions, through Apple's `SpeechAnalyzer` (iOS 26).
///
/// Optional in the strongest sense: it lives behind an availability check, its language assets
/// are managed by the system, and every failure mode is a plain "captions aren't available"
/// rather than a broken feature. Nothing leaves the device.
public enum CaptionTranscriber {

    public struct Availability: Sendable, Hashable {
        public var isSupported: Bool
        public var isInstalled: Bool
        public var localeIdentifier: String
        public var reason: String?
    }

    /// Whether transcription can run for the current locale, and whether assets are present.
    public static func availability(locale: Locale = .current) async -> Availability {
        #if canImport(Speech)
        if #available(iOS 26.0, macOS 26.0, *) {
            let supported = await SpeechTranscriber.supportedLocales
            let wanted = locale.identifier(.bcp47)
            guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
                return Availability(
                    isSupported: false, isInstalled: false, localeIdentifier: wanted,
                    reason: "On-device transcription doesn't support \(locale.localizedString(forIdentifier: locale.identifier) ?? wanted) yet."
                )
            }
            let installed = await SpeechTranscriber.installedLocales
            let isInstalled = installed.contains { $0.identifier(.bcp47) == wanted }
            return Availability(isSupported: true, isInstalled: isInstalled, localeIdentifier: wanted, reason: nil)
        }
        #endif
        return Availability(
            isSupported: false, isInstalled: false, localeIdentifier: locale.identifier,
            reason: "On-device transcription needs iOS 26."
        )
    }

    /// Downloads the language assets if they are missing. Progress is reported 0…1.
    public static func installAssetsIfNeeded(
        locale: Locale = .current,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        #if canImport(Speech)
        if #available(iOS 26.0, macOS 26.0, *) {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let observation = request.progress.observe(\Progress.fractionCompleted, options: [.new]) { p, _ in
                    progress?(p.fractionCompleted)
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
            return
        }
        #endif
        throw ReframeError.transcriptionUnavailable(reason: "On-device transcription needs iOS 26.")
    }

    /// Transcribes an audio file. Returns sentence-ish segments with word timings.
    public static func transcribe(fileURL: URL, locale: Locale = .current) async throws -> [TranscribedSegment] {
        #if canImport(Speech)
        if #available(iOS 26.0, macOS 26.0, *) {
            let availability = await availability(locale: locale)
            guard availability.isSupported else {
                throw ReframeError.transcriptionUnavailable(reason: availability.reason ?? "Unsupported language.")
            }
            if !availability.isInstalled {
                try await installAssetsIfNeeded(locale: locale)
            }

            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: fileURL)
            } catch {
                throw ReframeError.transcriptionUnavailable(reason: "The audio couldn't be read.")
            }

            // Collect results concurrently with the analysis, then finish through the end of
            // the file so the last words are finalised.
            let collector = Task<[TranscribedSegment], Error> {
                var segments: [TranscribedSegment] = []
                for try await result in transcriber.results where result.isFinal {
                    if let segment = Self.segment(from: result.text) {
                        segments.append(segment)
                    }
                }
                return segments
            }

            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                collector.cancel()
                throw ReframeError.transcriptionUnavailable(reason: "Transcription stopped: \(error.localizedDescription)")
            }

            let segments = try await collector.value
            DiagnosticsLog.shared.info("captions", "transcribed \(segments.count) segment(s) from \(fileURL.lastPathComponent)")
            return segments
        }
        #endif
        throw ReframeError.transcriptionUnavailable(reason: "On-device transcription needs iOS 26.")
    }

    #if canImport(Speech)
    @available(iOS 26.0, macOS 26.0, *)
    private static func segment(from text: AttributedString) -> TranscribedSegment? {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }

        var start = Double.infinity
        var end = 0.0
        var wordStarts: [Double] = []
        // Runs are per-word when audioTimeRange was requested; each carries its own range.
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let s = range.start.seconds
            let e = range.end.seconds
            guard s.isFinite, e.isFinite else { continue }
            let runText = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard !runText.isEmpty else { continue }
            start = min(start, s)
            end = max(end, e)
            // A run may hold several words; spread them evenly across the run.
            let words = runText.split(separator: " ").count
            for i in 0..<max(1, words) {
                wordStarts.append(s + (e - s) * Double(i) / Double(max(1, words)))
            }
        }
        guard start.isFinite, end > start else { return nil }

        let wordCount = plain.split(separator: " ").count
        let starts: [Double]? = wordStarts.count == wordCount ? wordStarts : nil
        return TranscribedSegment(text: plain, start: start, end: end, wordStarts: starts)
    }
    #endif
}

/// Turns segments into caption text layers: short lines, bottom third, pill background, word
/// timing carried through so words appear as they are spoken.
public enum CaptionLayout {

    public struct Style: Sendable {
        public var maxWordsPerLayer: Int
        public var maxLayerDuration: Double
        public var frame: NormalizedRect
        public var sizeRatio: Double
        public var background: TextBackground?
        public var fontCategory: FontCategory
        public var weight: TextWeight
        public var colorHex: String
        public var allCaps: Bool

        public init(
            maxWordsPerLayer: Int = 5, maxLayerDuration: Double = 3.0,
            frame: NormalizedRect = NormalizedRect(x: 0.08, y: 0.68, width: 0.84, height: 0.16),
            sizeRatio: Double = 0.042, background: TextBackground? = TextBackground(),
            fontCategory: FontCategory = .sansSerif, weight: TextWeight = .heavy,
            colorHex: String = "#FFFFFF", allCaps: Bool = false
        ) {
            self.maxWordsPerLayer = maxWordsPerLayer
            self.maxLayerDuration = maxLayerDuration
            self.frame = frame
            self.sizeRatio = sizeRatio
            self.background = background
            self.fontCategory = fontCategory
            self.weight = weight
            self.colorHex = colorHex
            self.allCaps = allCaps
        }

        public static let `default` = Style()
        public static let bold = Style(sizeRatio: 0.05, background: nil, weight: .black, allCaps: true)
        public static let minimal = Style(sizeRatio: 0.036, background: nil, weight: .semibold)
    }

    /// Splits segments into caption layers of at most `maxWordsPerLayer` words, offset by
    /// `timeOffset` (where the transcribed audio sits on the timeline).
    public static func layers(
        from segments: [TranscribedSegment],
        timeOffset: Double,
        style: Style = .default,
        canvasDuration: Double
    ) -> [TextLayer] {
        var layers: [TextLayer] = []
        for segment in segments {
            let words = segment.text.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }
            let starts: [Double] = segment.wordStarts?.count == words.count
                ? segment.wordStarts!
                : (0..<words.count).map { segment.start + (segment.end - segment.start) * Double($0) / Double(words.count) }

            var index = 0
            while index < words.count {
                let chunkEnd = min(words.count, index + style.maxWordsPerLayer)
                let chunkWords = Array(words[index..<chunkEnd])
                let chunkStart = starts[index]
                let chunkStop = chunkEnd < words.count ? starts[chunkEnd] : segment.end
                let start = timeOffset + chunkStart
                let end = min(canvasDuration, timeOffset + max(chunkStop, chunkStart + 0.4))
                guard end > start + 0.05 else { index = chunkEnd; continue }

                layers.append(
                    TextLayer(
                        text: chunkWords.joined(separator: " "),
                        role: .caption,
                        start: start,
                        end: end,
                        frame: style.frame,
                        alignment: .center,
                        fontCategory: style.fontCategory,
                        weight: style.weight,
                        allCaps: style.allCaps,
                        sizeRatio: style.sizeRatio,
                        colorHex: style.colorHex,
                        hasShadow: style.background == nil,
                        background: style.background,
                        entry: .none,
                        exit: .none,
                        wordTimings: chunkWords.indices.map { starts[index + $0] - chunkStart }
                    )
                )
                index = chunkEnd
            }
        }
        return layers
    }
}
