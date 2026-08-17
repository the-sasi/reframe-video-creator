import Foundation
import MediaIO
import RecipeCore

/// Stages of reference analysis, in the order the UI shows them.
public enum AnalysisStage: String, Sendable, Hashable, CaseIterable, Identifiable {
    case readVideo
    case detectScenes
    case trackMotion
    case readText
    case listenAudio
    case buildStyle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readVideo: return "Read video"
        case .detectScenes: return "Find scenes"
        case .trackMotion: return "Track motion"
        case .readText: return "Read text"
        case .listenAudio: return "Listen to audio"
        case .buildStyle: return "Build style"
        }
    }

    /// Whether this stage can report a real fraction.
    ///
    /// The analysis screen shows a determinate bar only where the denominator is genuinely
    /// known. `FrameStream` knows its frame count; OCR does not know how many text regions it
    /// will find. Faking the rest would be the easy thing and the wrong thing.
    public var hasDeterminateProgress: Bool {
        switch self {
        case .detectScenes, .trackMotion, .readText: return true
        case .readVideo, .listenAudio, .buildStyle: return false
        }
    }
}

public struct StageState: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case pending
        case running(fraction: Double?)
        case done(summary: String)
        case failed
    }

    public var stage: AnalysisStage
    public var status: Status

    public var id: String { stage.rawValue }

    public init(stage: AnalysisStage, status: Status) {
        self.stage = stage
        self.status = status
    }
}

public struct AnalysisProgress: Sendable, Hashable {
    public var stages: [StageState]

    public init(stages: [StageState]) {
        self.stages = stages
    }

    public static let initial = AnalysisProgress(
        stages: AnalysisStage.allCases.map { StageState(stage: $0, status: .pending) }
    )

    public var currentStage: AnalysisStage? {
        stages.first { if case .running = $0.status { return true } else { return false } }?.stage
    }

    /// Results already available, for the "results appear as they land" behaviour — by the time
    /// the last stage finishes, the user has already read most of the summary.
    public var completedSummaries: [(AnalysisStage, String)] {
        stages.compactMap { state in
            if case .done(let summary) = state.status { return (state.stage, summary) }
            return nil
        }
    }
}

/// Orchestrates reference analysis.
///
/// An actor because it owns mutable progress state that the UI reads while the work runs.
/// Cancellation is cooperative and checked every frame, so dismissing the analysis screen
/// actually stops the work rather than orphaning it.
public actor AnalysisPipeline {

    private var progress = AnalysisProgress.initial
    private var continuation: AsyncStream<AnalysisProgress>.Continuation?

    private let sceneDetector: SceneDetector
    private let shotAnalyzer: ShotAnalyzer
    private let textAnalyzer: TextAnalyzer
    private let audioAnalyzer: AudioAnalyzer
    private let compiler: RecipeCompiler

    public init(
        sceneDetector: SceneDetector = SceneDetector(),
        shotAnalyzer: ShotAnalyzer = ShotAnalyzer(),
        textAnalyzer: TextAnalyzer = TextAnalyzer(),
        audioAnalyzer: AudioAnalyzer = AudioAnalyzer(),
        compiler: RecipeCompiler = RecipeCompiler()
    ) {
        self.sceneDetector = sceneDetector
        self.shotAnalyzer = shotAnalyzer
        self.textAnalyzer = textAnalyzer
        self.audioAnalyzer = audioAnalyzer
        self.compiler = compiler
    }

    /// Progress updates. The view layer consumes this rather than polling.
    public func progressStream() -> AsyncStream<AnalysisProgress> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(progress)
        }
    }

    public func analyze(url: URL, title: String? = nil) async throws -> EditRecipe {
        defer { continuation?.finish() }

        // 1. Read
        update(.readVideo, .running(fraction: nil))
        let source = try await MediaSource(url: url)
        update(.readVideo, .done(summary: summarise(source)))

        // 2. Scenes
        update(.detectScenes, .running(fraction: 0))
        let (metrics, thumbs) = try await PerformanceLog.measure("detectScenes") {
            try await sceneDetector.measure(source: source) { [weak self] done, total in
                guard let self else { return }
                Task { await self.update(.detectScenes, .running(fraction: Double(done) / Double(max(1, total)))) }
            }
        }
        let boundaries = sceneDetector.detectBoundaries(
            metrics: metrics, thumbs: thumbs, duration: source.info.duration
        )
        var shots = sceneDetector.shots(from: boundaries, duration: source.info.duration)

        guard shots.count > 1 else {
            update(.detectScenes, .failed)
            throw ReframeError.noScenesDetected
        }
        update(.detectScenes, .done(summary: "\(shots.count) scenes"))

        // 3. Motion, saliency and palette — one pass per shot.
        update(.trackMotion, .running(fraction: 0))
        var scenePalettes: [Int: ScenePalette] = [:]
        try await PerformanceLog.measure("trackMotion") {
            for index in shots.indices {
                try Task.checkCancellation()
                if let visuals = await shotAnalyzer.analyze(shot: shots[index], source: source) {
                    shots[index].motion = visuals.motion
                    shots[index].salientAreaFraction = visuals.salientAreaFraction
                    shots[index].motionEnergy = motionEnergy(visuals.motion)
                    scenePalettes[index] = visuals.palette
                }
                update(
                    .trackMotion,
                    .running(fraction: Double(index + 1) / Double(shots.count))
                )
            }
        }
        let namedMoves = shots.compactMap(\.motion).filter { $0.kind != .none }.count
        update(.trackMotion, .done(summary: "\(namedMoves) camera moves"))

        // 4. Text
        update(.readText, .running(fraction: 0))
        let textTracks = try await PerformanceLog.measure("readText") {
            try await textAnalyzer.analyze(source: source) { [weak self] done, total in
                guard let self else { return }
                Task { await self.update(.readText, .running(fraction: Double(done) / Double(max(1, total)))) }
            }
        }
        let usableText = textTracks.filter { !$0.isLikelyWatermark }
        let droppedWatermarks = textTracks.count - usableText.count
        update(
            .readText,
            .done(
                summary: usableText.isEmpty
                    ? "no text"
                    : "\(usableText.count) text layer\(usableText.count == 1 ? "" : "s")"
                        + (droppedWatermarks > 0 ? " · \(droppedWatermarks) watermark ignored" : "")
            )
        )

        // 5. Audio
        update(.listenAudio, .running(fraction: nil))
        let audio = try await PerformanceLog.measure("listenAudio") {
            try await audioAnalyzer.analyze(source: source)
        }
        update(
            .listenAudio,
            .done(
                summary: audio.map { "\(Int($0.bpm.rounded())) BPM · \($0.beats.count) beats" }
                    ?? "no audio"
            )
        )

        // 6. Compile
        update(.buildStyle, .running(fraction: nil))
        let analysis = ReferenceAnalysis(
            source: source.info,
            shots: shots,
            textTracks: textTracks,
            palette: overallPalette(scenePalettes),
            scenePalettes: scenePalettes,
            audio: audio
        )
        let recipe = compiler.compile(
            analysis,
            title: title ?? defaultTitle(for: source),
            // Explicitly injected rather than taken inside the compiler, so the compiler stays
            // a pure function and its output stays diffable in tests.
            createdAt: Date()
        )
        update(.buildStyle, .done(summary: "\(recipe.stats.sceneCount) slots ready"))

        return recipe
    }

    // MARK: - Helpers

    private func update(_ stage: AnalysisStage, _ status: StageState.Status) {
        guard let index = progress.stages.firstIndex(where: { $0.stage == stage }) else { return }
        progress.stages[index].status = status
        continuation?.yield(progress)
    }

    private func summarise(_ source: MediaSource) -> String {
        String(
            format: "%.1fs · %dx%d · %dfps",
            source.info.duration, source.info.width, source.info.height,
            Int(source.info.fps.rounded())
        )
    }

    private func defaultTitle(for source: MediaSource) -> String {
        let name = source.url.deletingPathExtension().lastPathComponent
        let seconds = Int(source.info.duration.rounded())
        return name.isEmpty ? "Reference · \(seconds)s" : "\(name) · \(seconds)s"
    }

    /// Collapses a fitted motion into a 0...1 "how much did this move" scalar.
    private func motionEnergy(_ motion: FittedMotion) -> Double {
        let zoom = abs(motion.scale - 1)
        let pan = (motion.translationX * motion.translationX
                   + motion.translationY * motion.translationY).squareRoot()
        return min(1, zoom * 3 + pan * 4)
    }

    private func overallPalette(_ scenePalettes: [Int: ScenePalette]) -> Palette {
        let values = scenePalettes.values
        guard !values.isEmpty else { return .neutral }
        let count = Double(values.count)
        return Palette(
            dominant: Array(values.flatMap(\.dominant).prefix(5)),
            meanBrightness: values.map(\.brightness).reduce(0, +) / count,
            meanSaturation: values.map(\.saturation).reduce(0, +) / count,
            contrast: values.map(\.contrast).reduce(0, +) / count
        )
    }
}
