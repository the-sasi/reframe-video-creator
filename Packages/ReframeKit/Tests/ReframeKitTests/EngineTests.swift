import Foundation
import Testing
@testable import ReframeKit

// The engine has no UI dependency, so all of this runs under `swift test` on a Mac — no
// simulator, no device, no checked-in video fixtures. Synthetic input is the point: a clip
// generated with a cut at exactly frame 47 supports an exact assertion, where a real video
// only supports "roughly there".

// MARK: - Schema

@Suite("Schema")
struct SchemaTests {

    @Test("EditRecipe survives a JSON round trip unchanged")
    func recipeRoundTrip() throws {
        let recipe = TestFixtures.recipe()
        let data = try RecipeSchema.encoder.encode(recipe)
        let decoded = try RecipeSchema.decodeRecipe(data)
        #expect(decoded == recipe)
    }

    @Test("A document from a future schema version is refused, not partially decoded")
    func refusesFutureVersion() throws {
        var recipe = TestFixtures.recipe()
        recipe.schemaVersion = RecipeSchema.current + 1
        let data = try RecipeSchema.encoder.encode(recipe)

        #expect(throws: ReframeError.self) {
            _ = try RecipeSchema.decodeRecipe(data)
        }
    }

    @Test("Encoding is stable, so recipe JSON is diffable")
    func encodingIsStable() throws {
        let recipe = TestFixtures.recipe()
        let first = try RecipeSchema.encoder.encode(recipe)
        let second = try RecipeSchema.encoder.encode(recipe)
        #expect(first == second)
    }

    @Test("Deterministic IDs depend only on seed and path")
    func deterministicIDs() {
        let a = DeterministicID(seed: "sha256:abc")
        let b = DeterministicID(seed: "sha256:abc")
        let c = DeterministicID(seed: "sha256:xyz")

        #expect(a.uuid("scene/1") == b.uuid("scene/1"))
        #expect(a.uuid("scene/1") != a.uuid("scene/2"))
        #expect(a.uuid("scene/1") != c.uuid("scene/1"))
        #expect(a.string("asset", 3) == "asset_03")
    }
}

// MARK: - Confidence

@Suite("Confidence")
struct ConfidenceTests {

    @Test("Bands map to the documented behaviour")
    func bands() {
        #expect(ConfidenceBand(0.91) == .confident)
        #expect(ConfidenceBand(0.60) == .likely)
        #expect(ConfidenceBand(0.40) == .uncertain)
        #expect(ConfidenceBand(0.10) == .speculative)

        #expect(!ConfidenceBand(0.91).needsGuessedBadge)
        #expect(ConfidenceBand(0.60).needsGuessedBadge)
    }

    @Test("An untrusted transition degrades to its declared fallback, not to nothing")
    func transitionFallback() {
        let template = TransitionTemplate(
            kind: Confident(.whip, confidence: 0.4, basis: "test"),
            duration: 0.3,
            safeFallback: .cut
        )
        #expect(template.effectiveKind == .cut)
        #expect(template.effectiveDuration == 0)
    }

    @Test("A confident transition is applied as detected")
    func transitionApplied() {
        let template = TransitionTemplate(
            kind: Confident(.dissolve, confidence: 0.83, basis: "test"),
            duration: 0.3
        )
        #expect(template.effectiveKind == .dissolve)
        #expect(template.effectiveDuration == 0.3)
    }
}

// MARK: - Scene detection

@Suite("Scene detection")
struct SceneDetectionTests {

    /// Builds metrics with cuts at exact indices, so assertions can be exact.
    private func metrics(frameCount: Int, cutsAt: Set<Int>, baseline: Float = 0.004) -> [FrameMetric] {
        (0..<frameCount).map { index in
            FrameMetric(
                index: index,
                time: Double(index) / 30.0,
                contentValue: cutsAt.contains(index) ? 0.42 : baseline,
                lumaMean: 0.5,
                lumaStdDev: 0.25
            )
        }
    }

    @Test("Finds cuts at exactly the planted frames")
    func findsPlantedCuts() {
        let detector = SceneDetector()
        let planted: Set<Int> = [47, 96, 150]
        let input = metrics(frameCount: 200, cutsAt: planted)
        let thumbs = Array(repeating: [Float](repeating: 0.5, count: 24 * 42), count: 200)

        let boundaries = detector.detectBoundaries(
            metrics: input, thumbs: thumbs, duration: 200 / 30.0
        )
        let cutFrames = Set(
            boundaries.filter { $0.kind == .cut }.map { Int(($0.time * 30).rounded()) }
        )
        #expect(cutFrames == planted)
    }

    @Test("A static shot produces no cuts, however small its noise floor")
    func noFalsePositivesOnStatic() {
        let detector = SceneDetector()
        let input = metrics(frameCount: 120, cutsAt: [], baseline: 0.003)
        let thumbs = Array(repeating: [Float](repeating: 0.5, count: 24 * 42), count: 120)

        let boundaries = detector.detectBoundaries(
            metrics: input, thumbs: thumbs, duration: 4
        )
        #expect(boundaries.filter { $0.kind == .cut }.isEmpty)
    }

    @Test("A synthetic cross-fade is classified as a dissolve, not a cut")
    func detectsDissolve() {
        let detector = SceneDetector()
        let frameCount = 60
        let dissolveStart = 20
        let dissolveEnd = 28

        // Two distinct flat images, cross-faded between the two indices.
        let imageA = [Float](repeating: 0.2, count: 24 * 42)
        let imageB = [Float](repeating: 0.8, count: 24 * 42)

        var thumbs: [[Float]] = []
        var input: [FrameMetric] = []
        for index in 0..<frameCount {
            let thumb: [Float]
            var contentValue: Float = 0.003
            if index < dissolveStart {
                thumb = imageA
            } else if index > dissolveEnd {
                thumb = imageB
            } else {
                let alpha = Float(index - dissolveStart) / Float(dissolveEnd - dissolveStart)
                thumb = zip(imageA, imageB).map { $0 * (1 - alpha) + $1 * alpha }
                contentValue = 0.03  // elevated, but below the cut threshold
            }
            thumbs.append(thumb)
            input.append(
                FrameMetric(
                    index: index, time: Double(index) / 30.0,
                    contentValue: contentValue, lumaMean: 0.5, lumaStdDev: 0.25
                )
            )
        }

        let boundaries = detector.detectBoundaries(
            metrics: input, thumbs: thumbs, duration: 2
        )
        #expect(boundaries.contains { $0.kind == .dissolve })
        #expect(!boundaries.contains { $0.kind == .cut })
    }
}

// MARK: - Motion

@Suite("Motion fitting")
struct MotionTests {

    @Test("Recovers a synthetic 1.17x zoom to within 2%")
    func recoversZoom() {
        let expected = 1.17
        var source: [SIMD2<Double>] = []
        var target: [SIMD2<Double>] = []
        for x in stride(from: 0.1, through: 0.9, by: 0.1) {
            for y in stride(from: 0.1, through: 0.9, by: 0.1) {
                let point = SIMD2(x, y)
                source.append(point)
                // Scale about the frame centre.
                target.append(SIMD2(0.5, 0.5) + (point - SIMD2(0.5, 0.5)) * expected)
            }
        }

        let fit = SimilarityFit.fit(source: source, target: target)
        #expect(abs(fit.scale - expected) < 0.02)
        #expect(fit.residual < 0.001)
        #expect(abs(fit.rotation) < 0.01)
    }

    @Test("Recovers a synthetic pan and reports no zoom")
    func recoversPan() {
        let dx = 0.08
        var source: [SIMD2<Double>] = []
        var target: [SIMD2<Double>] = []
        for x in stride(from: 0.1, through: 0.9, by: 0.1) {
            for y in stride(from: 0.1, through: 0.9, by: 0.1) {
                source.append(SIMD2(x, y))
                target.append(SIMD2(x + dx, y))
            }
        }

        let fit = SimilarityFit.fit(source: source, target: target)
        #expect(abs(fit.translationX - dx) < 0.005)
        #expect(abs(fit.scale - 1) < 0.01)
    }

    @Test("A moving subject does not drag the fit into a phantom pan")
    func robustToOutliers() {
        var source: [SIMD2<Double>] = []
        var target: [SIMD2<Double>] = []
        for x in stride(from: 0.1, through: 0.9, by: 0.1) {
            for y in stride(from: 0.1, through: 0.9, by: 0.1) {
                source.append(SIMD2(x, y))
                // 15% of points move independently — a person walking through a locked-off shot.
                let isOutlier = (x + y) > 1.55
                target.append(isOutlier ? SIMD2(x + 0.25, y + 0.25) : SIMD2(x, y))
            }
        }

        let fit = SimilarityFit.fit(source: source, target: target)
        #expect(abs(fit.translationX) < 0.03)
        #expect(abs(fit.translationY) < 0.03)
    }
}

// MARK: - Beat detection

@Suite("Audio analysis")
struct AudioTests {

    @Test("Estimates the BPM of a synthetic click track within 2 BPM", arguments: [96.0, 128.0, 140.0])
    func estimatesTempo(expectedBPM: Double) {
        let analyzer = AudioAnalyzer()
        let sampleRate = 22_050.0
        let duration = 12.0
        let clickInterval = 60.0 / expectedBPM

        var samples = [Float](repeating: 0, count: Int(sampleRate * duration))
        // Short exponentially-decaying bursts, plus a low noise bed so the adaptive-mean
        // normalisation has something to work against.
        var clickTime = 0.0
        while clickTime < duration {
            let start = Int(clickTime * sampleRate)
            for i in 0..<Int(sampleRate * 0.02) where start + i < samples.count {
                let decay = exp(-Double(i) / (sampleRate * 0.004))
                samples[start + i] += Float(decay * sin(Double(i) * 0.35))
            }
            clickTime += clickInterval
        }
        for i in samples.indices {
            samples[i] += Float.random(in: -0.01...0.01)
        }

        let spectrogram = analyzer.computeSpectrogram(samples)
        let onset = analyzer.onsetEnvelope(from: spectrogram)
        let (bpm, confidence, _) = analyzer.estimateTempo(onset: onset)

        #expect(abs(bpm - expectedBPM) < 2.0)
        #expect(confidence > 0.3)
    }

    @Test("Places beats on the click track within 30ms")
    func placesBeats() {
        let analyzer = AudioAnalyzer()
        let sampleRate = 22_050.0
        let bpm = 120.0
        let interval = 60.0 / bpm
        let duration = 8.0

        var samples = [Float](repeating: 0, count: Int(sampleRate * duration))
        var clickTime = 0.0
        while clickTime < duration {
            let start = Int(clickTime * sampleRate)
            for i in 0..<Int(sampleRate * 0.02) where start + i < samples.count {
                let decay = exp(-Double(i) / (sampleRate * 0.004))
                samples[start + i] += Float(decay * sin(Double(i) * 0.35))
            }
            clickTime += interval
        }

        let spectrogram = analyzer.computeSpectrogram(samples)
        let onset = analyzer.onsetEnvelope(from: spectrogram)
        let beats = analyzer.beatGrid(onset: onset, bpm: bpm, duration: duration)

        #expect(beats.count > 10)
        // Every beat should sit close to a multiple of the interval.
        for beat in beats.prefix(10) {
            let nearestMultiple = (beat / interval).rounded() * interval
            #expect(abs(beat - nearestMultiple) < 0.03)
        }
    }
}

// MARK: - Assignment

@Suite("Asset assignment")
struct AssignmentTests {

    @Test("Hungarian solver matches brute force on random 6x6 matrices")
    func matchesBruteForce() {
        let solver = HungarianSolver()
        var generator = SeededGenerator(seed: 42)

        for _ in 0..<20 {
            let n = 6
            let cost = (0..<n).map { _ in
                (0..<n).map { _ in Double.random(in: 0...10, using: &generator) }
            }

            let solved = solver.solve(cost: cost)
            let solvedCost = solver.totalCost(of: solved, in: cost)

            var bestBruteForce = Double.infinity
            for permutation in permutations(of: Array(0..<n)) {
                let total = permutation.enumerated().reduce(0.0) { $0 + cost[$1.offset][$1.element] }
                bestBruteForce = min(bestBruteForce, total)
            }

            #expect(abs(solvedCost - bestBruteForce) < 1e-6)
        }
    }

    @Test("Solver handles more columns than rows")
    func rectangular() {
        let solver = HungarianSolver()
        let cost: [[Double]] = [
            [4, 1, 9, 7],
            [8, 3, 2, 6],
        ]
        let assignment = solver.solve(cost: cost)
        #expect(assignment.count == 2)
        #expect(assignment[0] == 1)
        #expect(assignment[1] == 2)
    }

    private func permutations(of array: [Int]) -> [[Int]] {
        guard array.count > 1 else { return [array] }
        var result: [[Int]] = []
        for (index, element) in array.enumerated() {
            var rest = array
            rest.remove(at: index)
            for sub in permutations(of: rest) {
                result.append([element] + sub)
            }
        }
        return result
    }
}

/// Reproducible randomness — a test that fails only sometimes is barely a test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Commands

@Suite("Edit commands")
struct CommandTests {

    private func timeline() -> Timeline {
        var timeline = Timeline(canvas: .reel1080)
        timeline.clips = (0..<4).map { index in
            VideoClip(
                assetID: UUID(), slotID: "asset_0\(index + 1)",
                start: Double(index), duration: 1.0
            )
        }
        timeline.relayout()
        return timeline
    }

    @Test("Every command round-trips: apply then revert restores the document")
    func applyRevertRoundTrip() throws {
        let original = timeline()
        let clipID = original.clips[1].id
        let textLayer = TextLayer(
            text: "Blush Rose Elegance", role: .title, start: 0, end: 3,
            frame: NormalizedRect(x: 0.1, y: 0.15, width: 0.8, height: 0.12)
        )

        let commands: [EditCommand] = [
            .trimClip(id: clipID, duration: 0.5, sourceStart: 0.2, wasDuration: 1.0, wasSourceStart: 0),
            .deleteClip(index: 2, clip: original.clips[2]),
            .moveClip(from: 0, to: 3),
            .setClipSpeed(id: clipID, speed: 2.0, wasSpeed: 1.0),
            .setClipGrade(id: clipID, grade: ColorGrade(exposure: 0.2, contrast: 1.1, saturation: 1.2, temperature: 0), wasGrade: .neutral),
            .setTransition(clipID: clipID, transition: Transition(kind: .dissolve, duration: 0.3), wasTransition: nil),
            .addTextLayer(layer: textLayer),
        ]

        for command in commands {
            var draft = original
            try command.apply(to: &draft)
            #expect(draft != original, "\(command.name) did not change anything")
            try command.revert(from: &draft)
            #expect(draft == original, "\(command.name) did not restore the document")
        }
    }

    @Test("Splitting a clip preserves total duration")
    func splitPreservesDuration() throws {
        var timeline = self.timeline()
        let before = timeline.duration
        let clipID = timeline.clips[1].id

        let command = EditCommand.splitClip(
            id: clipID, atLocalTime: 0.4, newClipID: UUID(), wasDuration: 1.0
        )
        try command.apply(to: &timeline)

        #expect(timeline.clips.count == 5)
        #expect(abs(timeline.duration - before) < 0.001)
    }

    @Test("Continuous gestures coalesce into one undo step")
    @MainActor
    func gestureCoalescing() {
        let document = TimelineDocument(timeline: timeline())
        let clipID = document.timeline.clips[0].id

        document.beginGesture(key: "trim:\(clipID)")
        for step in 1...10 {
            document.perform(
                .trimClip(
                    id: clipID, duration: 1.0 - Double(step) * 0.05, sourceStart: 0,
                    wasDuration: 1.0 - Double(step - 1) * 0.05, wasSourceStart: 0
                )
            )
        }
        document.endGesture()

        #expect(document.undoStack.count == 1)

        document.undo()
        #expect(abs(document.timeline.clips[0].duration - 1.0) < 0.001)
    }
}

// MARK: - Render planning

@Suite("Render planning")
struct RenderPlanningTests {

    private func timeline(transition: Transition?) -> Timeline {
        var timeline = Timeline(canvas: .reel1080)
        timeline.clips = [
            VideoClip(assetID: UUID(), start: 0, duration: 1.0),
            VideoClip(assetID: UUID(), start: 1.0, duration: 1.0, transitionIn: transition),
        ]
        timeline.relayout()
        return timeline
    }

    @Test("A cut produces a single stage, never a transition")
    func cutIsSingleStage() {
        let planner = RenderPlanner()
        let plan = planner.plan(timeline(transition: .cut), at: 1.0)
        guard case .single = plan.stage else {
            Issue.record("expected a single stage for a cut")
            return
        }
    }

    @Test("A dissolve is centred on the boundary")
    func dissolveIsCentred() {
        let planner = RenderPlanner()
        let timeline = timeline(transition: Transition(kind: .dissolve, duration: 0.4))

        // Boundary at 1.0, duration 0.4 -> window [0.8, 1.2].
        guard case .single = planner.plan(timeline, at: 0.75).stage else {
            Issue.record("0.75 should be before the transition window")
            return
        }
        guard case .transition(let stage) = planner.plan(timeline, at: 1.0).stage else {
            Issue.record("1.0 should be mid-transition")
            return
        }
        #expect(abs(stage.progress - 0.5) < 0.01)
        guard case .single = planner.plan(timeline, at: 1.25).stage else {
            Issue.record("1.25 should be after the transition window")
            return
        }
    }

    @Test("Ken Burns interpolates the crop across the clip")
    func kenBurns() {
        var timeline = Timeline(canvas: .reel1080)
        timeline.clips = [
            VideoClip(
                assetID: UUID(), start: 0, duration: 2.0,
                cropStart: .full,
                cropEnd: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                easing: .linear
            )
        ]

        let clip = timeline.clips[0]
        #expect(clip.crop(atLocalTime: 0).width == 1.0)
        #expect(abs(clip.crop(atLocalTime: 1.0).width - 0.9) < 0.001)
        #expect(abs(clip.crop(atLocalTime: 2.0).width - 0.8) < 0.001)
    }

    @Test("Word-by-word reveal staggers word opacity")
    func wordByWordStagger() {
        let planner = RenderPlanner()
        let layer = TextLayer(
            text: "Blush Rose Elegance", role: .title, start: 0, end: 3,
            frame: NormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.15),
            entry: .wordByWord
        )

        // Early in the reveal the first word is visible and the last is not.
        guard let draw = planner.textDraw(for: layer, at: 0.05) else {
            Issue.record("expected a text draw")
            return
        }
        #expect(draw.words.count == 3)
        #expect(draw.words[0].opacity > draw.words[2].opacity)

        // After the entry window everything is fully visible.
        guard let settled = planner.textDraw(for: layer, at: 1.5) else {
            Issue.record("expected a text draw")
            return
        }
        #expect(settled.words.allSatisfy { $0.opacity > 0.99 })
    }
}

// MARK: - Binding

@Suite("Recipe binding")
struct BindingTests {

    @Test("Reference text is never bound into the output")
    func referenceTextIsNotCopied() {
        let recipe = TestFixtures.recipe()
        #expect(recipe.textSlots.first?.sampleText == "SPRING COLLECTION")

        // No user text supplied for that slot.
        let timeline = RecipeBinder().bind(
            recipe: recipe,
            assets: AssetPool(),
            assignment: AssetAssignment(),
            content: UserContent()
        )

        #expect(timeline.textLayers.isEmpty)
        #expect(!timeline.textLayers.contains { $0.text.contains("SPRING") })
    }

    @Test("The user's own text is bound")
    func userTextIsBound() {
        let recipe = TestFixtures.recipe()
        let slotID = recipe.textSlots[0].id
        let content = UserContent(textBySlot: [slotID: "Blush Rose Elegance"])

        let timeline = RecipeBinder().bind(
            recipe: recipe, assets: AssetPool(),
            assignment: AssetAssignment(), content: content
        )

        #expect(timeline.textLayers.count == 1)
        #expect(timeline.textLayers[0].text == "Blush Rose Elegance")
    }

    @Test("Binding is gapless")
    func bindingIsGapless() {
        let recipe = TestFixtures.recipe()
        let timeline = RecipeBinder().bind(
            recipe: recipe, assets: AssetPool(),
            assignment: AssetAssignment(), content: UserContent()
        )

        for index in 1..<timeline.clips.count {
            let gap = timeline.clips[index].start
                - (timeline.clips[index - 1].start + timeline.clips[index - 1].duration)
            #expect(abs(gap) < 0.001, "gap of \(gap)s before clip \(index)")
        }
    }
}

// MARK: - Watermark rejection

@Suite("Watermark rejection")
struct WatermarkTests {

    @Test("Handles and growth-hack phrases are rejected", arguments: [
        "@bloomstudio",
        "follow for more",
        "LINK IN BIO",
        "made with CapCut",
    ])
    func rejectsWatermarks(text: String) {
        #expect(
            TextAnalyzer.isLikelyWatermark(
                text: text,
                rect: NormalizedRect(x: 0.05, y: 0.92, width: 0.3, height: 0.025),
                coverage: 0.95
            )
        )
    }

    @Test("Real captions are kept", arguments: [
        "Blush Rose Elegance",
        "Handcrafted daily",
        "SPRING COLLECTION",
    ])
    func keepsCaptions(text: String) {
        #expect(
            !TextAnalyzer.isLikelyWatermark(
                text: text,
                rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.09),
                coverage: 0.25
            )
        )
    }
}

// MARK: - Zero-cost invariant

@Suite("Zero-cost architecture")
struct ZeroCostArchitectureTests {

    /// The constraint that motivates the whole architecture, enforced by CI rather than by
    /// intent. If somebody adds a cloud provider, this fails.
    @Test("No API keys or paid-provider hosts anywhere in the engine")
    func noAPIKeysAnywhere() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReframeKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ReframeKit
            .appendingPathComponent("Sources")

        let forbidden = [
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
            "RUNWAY_API_KEY", "REPLICATE_API_TOKEN", "FAL_KEY",
            "api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com",
            "api.replicate.com", "api.runwayml.com",
        ]

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var offenders: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for needle in forbidden where contents.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }

        #expect(offenders.isEmpty, "found provider credentials or hosts: \(offenders)")
    }

    /// The privacy claim in docs/08-quality.md is "ReframeKit contains no networking code —
    /// not disabled, absent". This is what makes that checkable.
    @Test("The engine imports no networking")
    func noNetworkingImports() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var offenders: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if contents.contains("URLSession") || contents.contains("import Network") {
                offenders.append(url.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "engine reached for the network in: \(offenders)")
    }
}

// MARK: - Fixtures

enum TestFixtures {

    static func recipe(sceneCount: Int = 4) -> EditRecipe {
        let ids = DeterministicID(seed: "sha256:test")
        let sceneDuration = 1.2

        let scenes = (0..<sceneCount).map { index in
            SceneTemplate(
                id: ids.string("scene", index + 1),
                index: index,
                start: Double(index) * sceneDuration,
                end: Double(index + 1) * sceneDuration,
                sourceKind: .image,
                role: Confident(index == 0 ? .opening : .body, confidence: 0.8, basis: "fixture"),
                slot: AssetSlot(
                    id: ids.string("asset", index + 1),
                    framing: Confident(.medium, confidence: 0.7, basis: "fixture"),
                    motionEnergy: 0.1
                ),
                move: CameraMove.gentlePushIn(confidence: 0.8, basis: "fixture"),
                transitionIn: index == 0 ? nil : .cut
            )
        }

        return EditRecipe(
            id: ids.uuid("recipe"),
            title: "Fixture",
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            source: SourceInfo(
                duration: Double(sceneCount) * sceneDuration, fps: 30,
                width: 1080, height: 1920, aspect: .portrait9x16,
                hasAudio: true, fingerprint: "sha256:test"
            ),
            canvas: .reel1080,
            duration: Double(sceneCount) * sceneDuration,
            beatGrid: nil,
            scenes: scenes,
            textSlots: [
                TextSlotTemplate(
                    id: ids.string("text", 1),
                    role: .title,
                    start: 0.3, end: 3.1,
                    frame: NormalizedRect(x: 0.1, y: 0.16, width: 0.8, height: 0.14),
                    alignment: .center,
                    style: .defaultTitle,
                    animation: .fade,
                    sampleText: "SPRING COLLECTION",
                    charCountHint: 17
                )
            ],
            audio: .silent,
            palette: .neutral,
            stats: RecipeStats(
                sceneCount: sceneCount, medianSceneDuration: sceneDuration,
                cutsPerSecond: 0.8, transitionCount: 0, textSlotCount: 1
            ),
            confidence: ConfidenceReport.rollUp(scenes: 0.9, motion: 0.8, text: 0.5, audio: 1.0)
        )
    }
}
