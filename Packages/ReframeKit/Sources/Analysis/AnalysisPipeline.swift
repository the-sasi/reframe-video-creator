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

        DiagnosticsLog.shared.info("analysis", "=== analysing \(url.lastPathComponent) ===")

        // 1. Read
        update(.readVideo, .running(fraction: nil))
        let source = try await MediaSource(url: url)
        update(.readVideo, .done(summary: summarise(source)))
        DiagnosticsLog.shared.info(
            "analysis",
            "source \(source.info.width)x\(source.info.height) @\(Int(source.info.fps))fps, "
                + String(format: "%.1fs", source.info.duration)
                + ", audio=\(source.info.hasAudio)"
        )

        // Audio is independent of every visual stage, so it runs alongside them from the
        // start rather than waiting its turn — on a 30 s reference that takes it off the
        // critical path entirely.
        update(.listenAudio, .running(fraction: nil))
        let audioTask = Task.detached(priority: .userInitiated) { [audioAnalyzer] in
            try await PerformanceLog.measure("listenAudio") {
                try await audioAnalyzer.analyze(source: source)
            }
        }
        // Detached tasks are not children: cancelling the analysis would otherwise leave them
        // decoding in the background after the screen has gone.
        defer { audioTask.cancel() }

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

        // A single continuous shot is a legitimate reference — a talking head, a one-take
        // product clip. There is less structure to learn, but the duration, motion, text and
        // audio are all still there. Refusing it (which an earlier version did) threw away the
        // whole talking-head category for no reason.
        if shots.count == 1 {
            DiagnosticsLog.shared.warning("analysis", "single continuous shot — one-slot recipe")
        }
        update(.detectScenes, .done(summary: shots.count == 1 ? "1 continuous shot" : "\(shots.count) scenes"))

        // 3. Text runs concurrently with motion. Both decode the reference, but text reads it
        // at 720 px on a stride while motion seeks per shot; neither contends with the other
        // for the GPU the way two optical-flow passes would.
        update(.readText, .running(fraction: 0))
        // A strong capture of the actor: `weak self` inside a nested `@Sendable` closure is a
        // captured `var`, which Swift 6 refuses. The pipeline outlives its own `analyze` call
        // regardless, so the strong reference costs nothing.
        let pipeline = self
        let textTask = Task.detached(priority: .userInitiated) { [textAnalyzer] in
            try await PerformanceLog.measure("readText") {
                try await textAnalyzer.analyze(source: source) { done, total in
                    Task { await pipeline.update(.readText, .running(fraction: Double(done) / Double(max(1, total)))) }
                }
            }
        }
        defer { textTask.cancel() }

        // 4. Motion, saliency and palette — one pass per shot.
        update(.trackMotion, .running(fraction: 0))
        var scenePalettes: [Int: ScenePalette] = [:]
        try await PerformanceLog.measure("trackMotion") {
            for index in shots.indices {
                try Task.checkCancellation()
                if let visuals = await shotAnalyzer.analyze(shot: shots[index], source: source) {
                    shots[index].motion = visuals.motion
                    shots[index].salientAreaFraction = visuals.salientAreaFraction
                    shots[index].subjectRect = visuals.subjectRect
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
        update(.trackMotion, .done(summary: namedMoves == 0 ? "static shots" : "\(namedMoves) camera moves"))

        // 5. Collect text and audio.
        let textTracks: [DetectedTextTrack]
        do {
            textTracks = try await textTask.value
        } catch is CancellationError {
            throw ReframeError.analysisCancelled
        } catch let error as ReframeError {
            if case .analysisCancelled = error { throw error }
            // OCR failing must not sink the whole analysis; a recipe without text slots is
            // still a recipe. Log and carry on.
            DiagnosticsLog.shared.warning("analysis", "text stage failed, continuing: \(error.logDetail)")
            textTracks = []
        } catch {
            DiagnosticsLog.shared.warning("analysis", "text stage failed, continuing: \(error)")
            textTracks = []
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

        let audio: AudioAnalysis?
        do {
            audio = try await audioTask.value
        } catch is CancellationError {
            throw ReframeError.analysisCancelled
        } catch let error as ReframeError {
            if case .analysisCancelled = error { throw error }
            DiagnosticsLog.shared.warning("analysis", "audio stage failed, continuing: \(error.logDetail)")
            audio = nil
        } catch {
            DiagnosticsLog.shared.warning("analysis", "audio stage failed, continuing: \(error)")
            audio = nil
        }
        update(
            .listenAudio,
            .done(
                summary: audio.map {
                    $0.hasSpeech
                        ? "\(Int($0.bpm.rounded())) BPM · speech"
                        : "\(Int($0.bpm.rounded())) BPM · \($0.beats.count) beats"
                } ?? "no audio"
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
        logSummary(recipe)

        return recipe
    }

    /// One compact block per analysis, so a device report says what was found without the
    /// user having to export the recipe JSON. Structure only — no text content beyond counts.
    private func logSummary(_ recipe: EditRecipe) {
        let log = DiagnosticsLog.shared
        log.info(
            "recipe",
            String(
                format: "%d scenes, median %.2fs, %d transitions, %d text, bpm %@, confidence %.2f (weakest %@)",
                recipe.stats.sceneCount, recipe.stats.medianSceneDuration, recipe.stats.transitionCount,
                recipe.stats.textSlotCount,
                recipe.beatGrid.map { String(format: "%.1f", $0.bpm.value) } ?? "-",
                recipe.confidence.overall, recipe.confidence.weakest
            )
        )
        for scene in recipe.scenes.prefix(40) {
            let transition = scene.transitionIn.map {
                "\($0.effectiveKind.rawValue)\($0.effectiveDuration > 0 ? String(format: " %.2fs", $0.effectiveDuration) : "")"
            } ?? "start"
            let subject = scene.slot.subjectRect.map {
                String(format: "subj(%.2f,%.2f %.0f%%)", $0.value.centerX, $0.value.centerY, $0.value.area * 100)
            } ?? "subj -"
            log.info(
                "recipe",
                String(
                    format: "  #%02d %.2f-%.2f %@ %@ %@(%.2f) %@ %@",
                    scene.index + 1, scene.start, scene.end, scene.role.value.rawValue,
                    scene.slot.framing.value.rawValue, scene.move.effectiveKind.rawValue,
                    scene.move.kind.confidence, transition, subject
                )
            )
        }
    }

    // MARK: - Helpers

    private func update(_ stage: AnalysisStage, _ status: StageState.Status) {
        guard let index = progress.stages.firstIndex(where: { $0.stage == stage }) else { return }
        progress.stages[index].status = status
        continuation?.yield(progress)

        // Record transitions only, not the per-frame `.running(fraction:)` churn — a log that
        // is 99% progress ticks buries the one line that matters.
        switch status {
        case .done(let summary):
            DiagnosticsLog.shared.info("analysis", "\(stage.rawValue) done — \(summary)")
        case .failed:
            DiagnosticsLog.shared.failure("analysis", "\(stage.rawValue) FAILED")
        case .running(let fraction) where fraction == nil || fraction == 0:
            DiagnosticsLog.shared.info("analysis", "\(stage.rawValue) started")
        default:
            break
        }
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
