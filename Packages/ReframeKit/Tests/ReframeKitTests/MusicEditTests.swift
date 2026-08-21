import Foundation
import Testing

@testable import RecipeCore

// MARK: - Fixtures

/// 4 Hz energy envelope shaped quiet → rise → loud → fall → quiet.
private func archEnergy(seconds: Double) -> [Double] {
    let n = Int(seconds * 4)
    return (0..<n).map { i in
        let t = Double(i) / Double(max(1, n - 1))
        switch t {
        case ..<0.2: return 0.1
        case ..<0.4: return 0.1 + 0.85 * (t - 0.2) / 0.2
        case ..<0.7: return 0.95
        case ..<0.9: return 0.95 - 0.8 * (t - 0.7) / 0.2
        default: return 0.12
        }
    }
}

private func profile(bpm: Double = 120, seconds: Double = 40) -> MusicEditPlanner.MusicProfile {
    let interval = 60.0 / bpm
    let beats = stride(from: 0.0, through: seconds, by: interval).map { $0 }
    let downbeats = stride(from: 0.0, through: seconds, by: interval * 4).map { $0 }
    return MusicEditPlanner.MusicProfile(
        bpm: bpm, bpmConfidence: 0.9, beats: beats, downbeats: downbeats,
        energyCurve: archEnergy(seconds: seconds), energySamplesPerSecond: 4,
        duration: seconds, fingerprint: "test-track"
    )
}

// MARK: - Sections

@Suite("Music sections")
struct MusicSectionTests {

    @Test("An arch-shaped track segments intro → … → peak → … → outro")
    func archSegmentation() {
        let sections = MusicSectionizer.sections(
            energyCurve: archEnergy(seconds: 60), samplesPerSecond: 4, duration: 60
        )
        #expect(sections.first?.kind == .intro)
        #expect(sections.contains { $0.kind == .peak })
        #expect(sections.last?.kind == .outro)
        // Contiguous, full coverage, and intensities within range.
        for (a, b) in zip(sections, sections.dropFirst()) {
            #expect(abs(a.end - b.start) < 1e-9)
        }
        #expect(abs((sections.last?.end ?? 0) - 60) < 1e-9)
        #expect(sections.allSatisfy { $0.intensity >= 0 && $0.intensity <= 1 })
    }

    @Test("Flat and empty envelopes degrade to one covering section")
    func degenerateEnvelopes() {
        let flat = MusicSectionizer.sections(
            energyCurve: Array(repeating: 0.4, count: 200), samplesPerSecond: 4, duration: 50
        )
        #expect(flat.count == 1 && flat[0].kind == .steady)

        let empty = MusicSectionizer.sections(energyCurve: [], samplesPerSecond: 4, duration: 12)
        #expect(empty.count == 1)
        #expect(abs(empty[0].end - 12) < 1e-9)
    }
}

// MARK: - Planner

@Suite("Music planner")
struct MusicPlannerTests {

    @Test("Every interior cut lands on a beat and scenes stay contiguous")
    func cutsOnBeats() {
        let music = profile()
        let recipe = MusicEditPlanner.plan(music: music, options: .init(maxDuration: 40, assetCount: 10))
        #expect(recipe.scenes.count >= 6)
        let beatSet = Set(music.beats.map { Int(($0 * 1000).rounded()) })
        for scene in recipe.scenes.dropLast() {
            #expect(beatSet.contains(Int((scene.end * 1000).rounded())), "cut at \(scene.end) off grid")
        }
        for (a, b) in zip(recipe.scenes, recipe.scenes.dropFirst()) {
            #expect(abs(a.end - b.start) < 1e-9)
            #expect(a.duration >= 0.35)
        }
        #expect(recipe.beatGrid?.cutsAlignedToBeats.value == true)
        #expect(recipe.audio.suggestedCutStyle == .onBeat)
    }

    @Test("Loud sections cut faster than the quiet opening")
    func energyPacesCuts() {
        let recipe = MusicEditPlanner.plan(music: profile(), options: .init(maxDuration: 40, assetCount: 12))
        let opening = recipe.scenes.first { $0.start < 8 }
        let peakShots = recipe.scenes.filter { $0.start >= 18 && $0.start < 26 }
        let shortestPeak = peakShots.map(\.duration).min()
        #expect(opening != nil && shortestPeak != nil)
        if let opening, let shortestPeak {
            #expect(opening.duration > shortestPeak)
        }
    }

    @Test("Deterministic: same profile, same recipe")
    func deterministic() {
        let music = profile()
        let a = MusicEditPlanner.plan(music: music)
        let b = MusicEditPlanner.plan(music: music)
        #expect(a == b)
    }

    @Test("A beatless track still plans a usable, evenly cut edit")
    func beatlessFallback() {
        let music = MusicEditPlanner.MusicProfile(
            bpm: 0, bpmConfidence: 0, beats: [], downbeats: [],
            energyCurve: [], duration: 24, fingerprint: "spoken-word"
        )
        let recipe = MusicEditPlanner.plan(music: music, options: .init(maxDuration: 24, assetCount: 6))
        #expect(recipe.scenes.count >= 4)
        #expect(abs(recipe.duration - (recipe.scenes.last?.end ?? 0)) < 1e-9)
    }

    @Test("The plan round-trips through recipe JSON")
    func codable() throws {
        let recipe = MusicEditPlanner.plan(music: profile())
        let data = try RecipeSchema.encoder.encode(recipe)
        let decoded = try RecipeSchema.decodeRecipe(data)
        #expect(decoded == recipe)
    }
}

// MARK: - Quality

@Suite("Edit quality")
struct EditQualityTests {

    private func clip(_ id: UUID?, _ start: Double, _ duration: Double) -> VideoClip {
        VideoClip(assetID: id, slotID: nil, start: start, duration: duration)
    }

    @Test("A clean edit is acceptable; an empty slot is a hard failure")
    func hardFailures() {
        let a = UUID(), b = UUID(), c = UUID()
        var timeline = Timeline(id: UUID(), canvas: .reel1080, recipeID: nil)
        timeline.clips = [clip(a, 0, 1), clip(b, 1, 1), clip(c, 2, 1)]
        #expect(EditQuality.score(timeline: timeline).isAcceptable)

        timeline.clips = [clip(a, 0, 1), clip(nil, 1, 1), clip(c, 2, 1)]
        let holed = EditQuality.score(timeline: timeline)
        #expect(!holed.isAcceptable)
        #expect(holed.issues.contains { $0.kind == .emptySlot })
    }

    @Test("Adjacent repeats and dominance are flagged and lower the score")
    func repetition() {
        let a = UUID(), b = UUID()
        var timeline = Timeline(id: UUID(), canvas: .reel1080, recipeID: nil)
        timeline.clips = [clip(a, 0, 1), clip(a, 1, 1), clip(b, 2, 1), clip(a, 3, 1), clip(a, 4, 1), clip(a, 5, 1)]
        let quality = EditQuality.score(timeline: timeline)
        #expect(quality.issues.contains { $0.kind == .adjacentRepeat })
        #expect(quality.issues.contains { $0.kind == .overusedAsset })
    }

    @Test("Expected reuse with few assets is not punished")
    func fairReuse() {
        // 3 assets over 6 slots, evenly interleaved: as good as it can be.
        let a = UUID(), b = UUID(), c = UUID()
        var timeline = Timeline(id: UUID(), canvas: .reel1080, recipeID: nil)
        timeline.clips = [clip(a, 0, 1), clip(b, 1, 1), clip(c, 2, 1), clip(a, 3, 1), clip(b, 4, 1), clip(c, 5, 1)]
        let quality = EditQuality.score(timeline: timeline)
        #expect(quality.issues.isEmpty, "\(quality.summary)")
        #expect(quality.isAcceptable)
    }

    @Test("A planner's own output scores acceptably once bound")
    func plannerOutputScores() {
        let music = profile()
        let recipe = MusicEditPlanner.plan(music: music, options: .init(maxDuration: 40, assetCount: 8))
        var pool = AssetPool()
        var refs: [AssetReference] = []
        for i in 0..<8 {
            let ref = AssetReference(
                kind: .image, origin: .sandboxRelativePath("t/\(i).jpg"),
                displayName: "p\(i)", pixelWidth: 3000, pixelHeight: 4000
            )
            pool.add(ref)
            refs.append(ref)
        }
        var assignment = AssetAssignment()
        for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i % refs.count].id }
        let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent())
        let quality = EditQuality.score(timeline: timeline, beatGrid: recipe.beatGrid)
        #expect(quality.isAcceptable, "\(quality.summary)")
        #expect(quality.rhythm > 0.7, "planned cuts should sit on their own grid (\(quality.rhythm))")
    }
}
