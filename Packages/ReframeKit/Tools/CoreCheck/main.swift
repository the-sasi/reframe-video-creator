import Foundation
import RecipeCore

// A tiny assertion harness. Every check here has a real counterpart in ReframeKitTests; this
// exists so the same logic can be exercised on Windows in seconds. Exit code is non-zero on any
// failure so it can gate a commit.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("  ✗ \(message)  (\(file):\(line))")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { failures += 1; print("  ✗ threw \(error)") }
}

func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

// MARK: - Fixtures

func sampleRecipe(sceneCount: Int = 4, withBeats: Bool = false) -> EditRecipe {
    let ids = DeterministicID(seed: "fixture")
    let scenes: [SceneTemplate] = (0..<sceneCount).map { i in
        SceneTemplate(
            id: ids.string("scene", i + 1), index: i,
            start: Double(i) * 1.0, end: Double(i + 1) * 1.0,
            sourceKind: .image,
            role: Confident(.body, confidence: 0.6, basis: "fixture"),
            slot: AssetSlot(
                id: ids.string("asset", i + 1),
                framing: Confident(i == 1 ? .closeUp : .medium, confidence: 0.72, basis: "fixture"),
                motionEnergy: 0.1,
                subjectRect: Confident(NormalizedRect(x: 0.3, y: 0.2, width: 0.4, height: 0.3), confidence: 0.7, basis: "fixture")
            ),
            move: i == 0
                ? CameraMove(kind: Confident(.zoomIn, confidence: 0.9, basis: "fixture"),
                             startRect: .full, endRect: NormalizedRect.full.scaled(by: 0.85), easing: .easeInOut)
                : .still,
            transitionIn: i == 0 ? nil : TransitionTemplate(kind: Confident(.dissolve, confidence: 0.8, basis: "fixture"), duration: 0.3)
        )
    }
    // 120 BPM, phase-shifted 30 ms so quantisation has something to do and stays within tolerance.
    let beats: [Double] = withBeats ? stride(from: 0.03, through: Double(sceneCount) + 0.5, by: 0.5).map { $0 } : []
    let grid: BeatGrid? = withBeats ? BeatGrid(
        bpm: Confident(127.6, confidence: 0.8, basis: "fixture"), beats: beats, downbeats: [],
        cutsAlignedToBeats: Confident(true, confidence: 0.8, basis: "fixture")
    ) : nil
    return EditRecipe(
        id: ids.uuid("recipe"), title: "Fixture", createdAt: Date(timeIntervalSince1970: 0),
        source: SourceInfo(duration: Double(sceneCount), fps: 30, width: 1080, height: 1920, aspect: .portrait9x16, hasAudio: withBeats, fingerprint: "fixture"),
        canvas: .reel1080, duration: Double(sceneCount), beatGrid: grid, scenes: scenes,
        textSlots: [
            TextSlotTemplate(id: "text_01", role: .title, start: 0.2, end: 2.0,
                             frame: NormalizedRect(x: 0.1, y: 0.15, width: 0.8, height: 0.12),
                             alignment: .center, style: .defaultTitle, animation: .fade,
                             sampleText: "REFERENCE COPY", charCountHint: 14)
        ],
        audio: AudioPlan(hasMusic: withBeats, hasSpeech: Confident(false, confidence: 0.8, basis: "fixture"),
                         energyCurve: [], suggestedCutStyle: withBeats ? .onBeat : .literal),
        palette: .neutral,
        stats: RecipeStats(sceneCount: sceneCount, medianSceneDuration: 1, cutsPerSecond: 1, transitionCount: sceneCount - 1, textSlotCount: 1),
        confidence: ConfidenceReport(overall: 0.8, scenes: 0.8, motion: 0.8, text: 0.8, audio: 0.8, weakest: "text")
    )
}

func samplePool(count: Int) -> (AssetPool, [AssetReference]) {
    var pool = AssetPool()
    var refs: [AssetReference] = []
    for i in 0..<count {
        let landscape = i % 2 == 0
        let ref = AssetReference(
            kind: i == 2 ? .video : .image,
            origin: .sandboxRelativePath("fixture/\(i).jpg"),
            displayName: "asset\(i)",
            pixelWidth: landscape ? 4000 : 3000,
            pixelHeight: landscape ? 3000 : 4000,
            duration: i == 2 ? 6 : 0
        )
        pool.add(ref)
        refs.append(ref)
    }
    return (pool, refs)
}

// MARK: - Checks

section("Binder: subject-aware crop keeps the subject inside the crop") {
    let recipe = sampleRecipe()
    let (pool, refs) = samplePool(count: 4)
    var assignment = AssetAssignment()
    for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i].id }
    // Landscape photo with its subject far right.
    let subject = NormalizedRect(x: 0.72, y: 0.3, width: 0.2, height: 0.3)
    let options = RecipeBinder.Options(subjectRects: [refs[0].id: subject])
    let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent(), options: options)
    let clip = timeline.clips[0]
    // The fill window for a 4:3 source in a 9:16 canvas is 0.42 wide. It must contain the subject centre.
    check(clip.cropStart.x <= subject.centerX && clip.cropStart.x + clip.cropStart.width >= subject.centerX,
          "crop start x range \(clip.cropStart.x)…\(clip.cropStart.x + clip.cropStart.width) contains subject centre \(subject.centerX)")
    check(clip.cropStart.width < 0.5, "landscape source into portrait canvas crops horizontally (w=\(clip.cropStart.width))")
    // Without a subject: centred.
    let plain = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent())
    check(approx(plain.clips[0].cropStart.centerX, 0.5, 0.01), "no subject → centred crop")
    // Zoom-in composes inside the window: end rect is smaller than start rect.
    check(clip.cropEnd.width < clip.cropStart.width, "zoom-in composed inside window")
}

section("Binder: close-up slot tightens around a small subject") {
    let recipe = sampleRecipe()
    let (pool, refs) = samplePool(count: 4)
    var assignment = AssetAssignment()
    for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i].id }
    // Slot 2 is a close-up. Portrait asset with a tiny subject.
    let tiny = NormalizedRect(x: 0.45, y: 0.4, width: 0.1, height: 0.1)
    let options = RecipeBinder.Options(subjectRects: [refs[1].id: tiny])
    let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent(), options: options)
    let clip = timeline.clips[1]
    check(clip.cropStart.width < 0.99, "close-up slot tightened the crop (w=\(clip.cropStart.width))")
    // The fill window for a 3:4 source in a 9:16 canvas is 0.75 wide; tightening is bounded to 62% of that.
    check(clip.cropStart.width >= 0.75 * 0.62 - 1e-9, "never tighter than 62% of the fill window (w=\(clip.cropStart.width))")
    check(clip.cropStart.x <= tiny.centerX && clip.cropStart.x + clip.cropStart.width >= tiny.centerX, "subject still inside")
}

section("Binder: fidelity modes") {
    let recipe = sampleRecipe()
    let (pool, refs) = samplePool(count: 4)
    var assignment = AssetAssignment()
    for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i].id }
    let content = UserContent(textBySlot: ["text_01": "MY WORDS"])

    let close = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: content, options: .init(fidelity: .closeMatch))
    check(close.textLayers.count == 1, "close match binds text slot")
    check(close.clips[1].transitionIn?.kind == .dissolve, "close match keeps transitions")
    check(close.clips[0].cropEnd.width < close.clips[0].cropStart.width, "close match keeps moves")

    let style = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: content, options: .init(fidelity: .styleOnly))
    check(style.textLayers.isEmpty, "style only binds no reference text slots")
    check(style.clips[1].transitionIn?.kind == .dissolve, "style only keeps transitions")

    let structure = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: content, options: .init(fidelity: .structureOnly))
    check(structure.textLayers.isEmpty, "structure only: no text")
    check(structure.clips[1].transitionIn == nil, "structure only: cuts")
    check(structure.clips[0].cropStart == structure.clips[0].cropEnd, "structure only: no motion")
    check(structure.clips.count == 4 && approx(structure.duration, 4), "structure only keeps durations")
}

section("Binder: cumulative beat quantisation preserves total length") {
    let recipe = sampleRecipe(sceneCount: 6, withBeats: true)
    let (pool, refs) = samplePool(count: 6)
    var assignment = AssetAssignment()
    for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i].id }
    let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent())
    check(abs(timeline.duration - 6) < 0.25, "quantised timeline stays within a beat of the reference (\(timeline.duration))")
    for (i, clip) in timeline.clips.enumerated() where i > 0 {
        check(clip.start > timeline.clips[i - 1].start, "monotonic")
    }
    // Every clip end lands within 20 ms of a beat (except possibly the last, clamped to duration).
    let beats = recipe.beatGrid!.beats
    for clip in timeline.clips.dropLast() {
        let nearest = beats.map { abs($0 - clip.end) }.min() ?? 1
        check(nearest < 0.04, "clip end \(clip.end) near a beat (Δ\(nearest))")
    }
}

section("Binder: audio roles from content") {
    let recipe = sampleRecipe()
    var pool = AssetPool()
    let music = AssetReference(kind: .audio, origin: .sandboxRelativePath("m.m4a"), displayName: "music", pixelWidth: 0, pixelHeight: 0, duration: 30)
    let voice = AssetReference(kind: .audio, origin: .sandboxRelativePath("v.m4a"), displayName: "voice", pixelWidth: 0, pixelHeight: 0, duration: 2.5)
    let ref = AssetReference(kind: .audio, origin: .sandboxRelativePath("r.m4a"), displayName: "ref", pixelWidth: 0, pixelHeight: 0, duration: 4)
    pool.add(music); pool.add(voice); pool.add(ref)
    let content = UserContent(musicAssetID: music.id, voiceoverAssetID: voice.id, referenceAudioAssetID: ref.id)
    let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: AssetAssignment(), content: content)
    check(timeline.audio.count == 3, "three audio clips")
    check(timeline.audio.contains { $0.role == .voice && approx($0.duration, 2.5) }, "voice trimmed to its own length")
    check(timeline.audio.contains { $0.role == .music && approx($0.duration, 4) }, "music trimmed to timeline")
    check(timeline.audio.first { $0.role == .reference }?.volume == 0.5, "reference audio lowered when music present")
}

section("Commands: split then undo restores crop end") {
    var timeline = Timeline(canvas: .reel1080)
    timeline.clips = [
        VideoClip(assetID: UUID(), start: 0, duration: 2, cropStart: .full, cropEnd: NormalizedRect.full.scaled(by: 0.8)),
        VideoClip(assetID: UUID(), start: 2, duration: 1),
    ]
    timeline.relayout()
    let original = timeline
    let clip = timeline.clips[0]
    let command = EditCommand.splitClip(id: clip.id, atLocalTime: 1.0, newClipID: UUID(), wasDuration: clip.duration, wasCropEnd: clip.cropEnd)
    try command.apply(to: &timeline)
    check(timeline.clips.count == 3, "split produced a clip")
    check(timeline.clips[0].cropEnd.width < 1 && timeline.clips[0].cropEnd.width > 0.8, "first half ends mid-move")
    check(approx(timeline.clips[1].cropStart.width, timeline.clips[0].cropEnd.width), "second half starts where first ended")
    try command.revert(from: &timeline)
    check(timeline == original, "undo restores the exact document (including cropEnd)")
}

section("Commands: every new case round-trips") {
    var timeline = Timeline(canvas: .reel1080)
    timeline.clips = [VideoClip(assetID: UUID(), start: 0, duration: 2)]
    timeline.audio = [AudioClip(assetID: UUID(), start: 0, duration: 2, role: .music)]
    timeline.textLayers = [TextLayer(text: "hello world", role: .caption, start: 0, end: 1, frame: .full)]
    timeline.relayout()
    let original = timeline
    let clip = timeline.clips[0]
    let audio = timeline.audio[0]
    let text = timeline.textLayers[0]
    let commands: [EditCommand] = [
        .setClipFit(id: clip.id, fitMode: .fit, wasFitMode: clip.fitMode),
        .setTextWordTimings(id: text.id, timings: [0, 0.4], wasTimings: nil),
        .setAudioFades(id: audio.id, fadeIn: 0.5, fadeOut: 1, wasFadeIn: audio.fadeIn, wasFadeOut: audio.fadeOut),
        .setAudioMuted(id: audio.id, isMuted: true, wasMuted: false),
        .retimeAudioClip(id: audio.id, start: 0.5, duration: 1, sourceStart: 2, wasStart: 0, wasDuration: 2, wasSourceStart: 0),
        .setDucking(enabled: false, wasEnabled: true),
        .setBackground(hex: "#112233", wasHex: "#000000"),
        .setTextStyle(id: text.id, style: TextLayerStyle(fontCategory: .serif, fontName: "Georgia", weight: .black, isItalic: true, allCaps: true, sizeRatio: 0.09, letterSpacing: 0.05, lineSpacing: 1.3, colorHex: "#FF0000", opacity: 0.8, hasShadow: false, outline: TextOutline(), background: TextBackground(), rotation: 0.2, alignment: .leading, entry: .popIn, exit: .popOut), wasStyle: TextLayerStyle(layer: text)),
    ]
    for command in commands {
        var draft = original
        try command.apply(to: &draft)
        check(draft != original, "\(command.name) changed the document")
        try command.revert(from: &draft)
        check(draft == original, "\(command.name) round-trips")
    }
}

section("Codable: v1-shaped documents decode with defaults") {
    // A TextLayer/AudioClip/VideoClip encoded by the previous schema — no new keys.
    let json = """
    {"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","canvas":{"width":1080,"height":1920,"fps":30},
     "clips":[{"id":"00000000-0000-0000-0000-000000000002","start":0,"duration":1,"sourceStart":0,
       "cropStart":{"x":0,"y":0,"width":1,"height":1},"cropEnd":{"x":0,"y":0,"width":1,"height":1},"easing":"linear",
       "grade":{"exposure":0,"contrast":1,"saturation":1,"temperature":0},"speed":1,"opacity":1,"volume":0,"vignette":0,"grain":0}],
     "textLayers":[{"id":"00000000-0000-0000-0000-000000000003","text":"hi","role":"title","start":0,"end":1,
       "frame":{"x":0,"y":0,"width":1,"height":0.2},"alignment":"center","fontCategory":"serif","sizeRatio":0.05,
       "colorHex":"#FFFFFF","hasShadow":true,"entry":"fadeIn","exit":"fadeOut"}],
     "overlays":[],
     "audio":[{"id":"00000000-0000-0000-0000-000000000004","assetID":"00000000-0000-0000-0000-000000000005",
       "start":0,"duration":1,"sourceStart":0,"volume":1,"fadeIn":0,"fadeOut":0.5}]}
    """
    let timeline = try RecipeSchema.decodeTimeline(Data(json.utf8))
    check(timeline.duckMusicUnderVoice == true, "ducking default")
    check(timeline.backgroundHex == "#000000", "background default")
    check(timeline.clips[0].fitMode == .fill, "fit default")
    check(timeline.textLayers[0].weight == .bold && timeline.textLayers[0].lineSpacing == 1.18, "text defaults")
    check(timeline.audio[0].role == .music && timeline.audio[0].isMuted == false, "audio defaults")
    // And it re-encodes and decodes identically.
    let data = try RecipeSchema.encoder.encode(timeline)
    let again = try RecipeSchema.decodeTimeline(data)
    check(again == timeline, "round trip after upgrade")
}

section("Mix planner: fades, ducking, clip audio") {
    var timeline = Timeline(canvas: .reel1080)
    let videoAsset = AssetReference(kind: .video, origin: .sandboxRelativePath("v.mov"), displayName: "v", pixelWidth: 1920, pixelHeight: 1080, duration: 10)
    let musicAsset = AssetReference(kind: .audio, origin: .sandboxRelativePath("m.m4a"), displayName: "m", pixelWidth: 0, pixelHeight: 0, duration: 30)
    let voiceAsset = AssetReference(kind: .audio, origin: .sandboxRelativePath("vo.m4a"), displayName: "vo", pixelWidth: 0, pixelHeight: 0, duration: 3)
    var pool = AssetPool()
    pool.add(videoAsset); pool.add(musicAsset); pool.add(voiceAsset)

    timeline.clips = [
        VideoClip(assetID: videoAsset.id, start: 0, duration: 4, sourceStart: 1, speed: 2, volume: 0.6),
        VideoClip(assetID: videoAsset.id, start: 4, duration: 2, volume: 0),
    ]
    timeline.audio = [
        AudioClip(assetID: musicAsset.id, start: 0, duration: 6, volume: 0.8, fadeIn: 1, fadeOut: 1, role: .music),
        AudioClip(assetID: voiceAsset.id, start: 2, duration: 2, volume: 1, fadeIn: 0, fadeOut: 0, role: .voice),
    ]
    timeline.relayout()

    let plan = AudioMixPlanner().plan(timeline, assets: pool)
    check(plan.tracks.count == 3, "music + voice + one audible clip track (got \(plan.tracks.count))")
    let music = plan.tracks.first { $0.role == .music }!
    let voice = plan.tracks.first { $0.role == .voice }!
    let clip = plan.tracks.first { $0.role == .clipAudio }!

    check(approx(music.gain(at: 0), 0), "music fades in from 0")
    check(approx(music.gain(at: 1.0), 0.8, 0.02), "music reaches full after fade-in")
    check(music.gain(at: 3.0) < 0.8 * 0.3, "music ducked under voice (\(music.gain(at: 3.0)))")
    check(music.gain(at: 1.85) < 0.79 && music.gain(at: 1.85) > 0.8 * 0.22, "music ramping down before voice starts (\(music.gain(at: 1.85)))")
    check(approx(music.gain(at: 6.0), 0, 0.01), "music fades out to 0")
    check(approx(voice.gain(at: 3), 1), "voice at full")
    check(approx(clip.speed, 2) && approx(clip.sourceStart, 1) && approx(clip.duration, 4), "clip track carries speed/source offset")
    check(approx(clip.gain(at: 1), 0.6, 0.02), "clip audio at its volume before voice")
    check(clip.gain(at: 3) < 0.6 * 0.3, "clip audio ducked under voice too")

    // Ducking off → music unaffected mid-voice.
    timeline.duckMusicUnderVoice = false
    let flat = AudioMixPlanner().plan(timeline, assets: pool)
    check(approx(flat.tracks.first { $0.role == .music }!.gain(at: 3), 0.8, 0.02), "no ducking when disabled")

    // Muted → dropped.
    timeline.audio[0].isMuted = true
    let muted = AudioMixPlanner().plan(timeline, assets: pool)
    check(!muted.tracks.contains { $0.role == .music }, "muted music dropped")
}

section("Assignment locks survive encoding") {
    var assignment = AssetAssignment()
    assignment["asset_01"] = UUID()
    assignment.setLocked(true, slotID: "asset_01")
    let data = try RecipeSchema.encoder.encode(assignment)
    let decoded = try RecipeSchema.decoder.decode(AssetAssignment.self, from: data)
    check(decoded.isLocked("asset_01"), "lock round-trips")
    let legacy = try RecipeSchema.decoder.decode(AssetAssignment.self, from: Data("{\"assetBySlot\":{},\"reasonBySlot\":{}}".utf8))
    check(legacy.lockedSlots.isEmpty, "legacy assignment decodes")
}

section("AssetFeatures: codable + distance") {
    let a = AssetFeatures(assetID: UUID(), aestheticScore: 0.5, featurePrint: [0, 0, 1])
    let b = AssetFeatures(assetID: UUID(), aestheticScore: -0.2, isUtility: true, featurePrint: [0, 0, 0])
    check(approx(a.featureDistance(to: b) ?? -1, 1), "euclidean distance")
    let data = try RecipeSchema.encoder.encode(a)
    let back = try RecipeSchema.decoder.decode(AssetFeatures.self, from: data)
    check(back == a, "round-trips")
    check(b.qualityScore < a.qualityScore, "utility drags quality down")
}

section("TextLayer.displayWords honours line breaks and caps") {
    let layer = TextLayer(text: "hello world\nsecond line", role: .caption, start: 0, end: 1, frame: .full, allCaps: true)
    let words = layer.displayWords
    check(words == ["HELLO", "WORLD", TextLayer.lineBreakMarker, "SECOND", "LINE"], "words: \(words)")
}

print("")
print(failures == 0 ? "ALL \(passes) CHECKS PASSED" : "\(failures) FAILED, \(passes) passed")
exit(failures == 0 ? 0 : 1)
