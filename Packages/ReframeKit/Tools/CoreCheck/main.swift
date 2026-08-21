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

section("Variations: batched, undoable, idempotent") {
    let recipe = sampleRecipe(sceneCount: 6)
    let (pool, refs) = samplePool(count: 6)
    var assignment = AssetAssignment()
    for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i].id }
    let bound = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent())
    for variation in EditVariation.allCases {
        var timeline = bound
        guard let command = variation.command(for: timeline) else { check(false, "\(variation.rawValue) produced a command"); continue }
        if case .batch(let name, let commands) = command {
            check(name == variation.displayName && !commands.isEmpty, "\(variation.rawValue) is a named batch of \(commands.count)")
        } else { check(false, "\(variation.rawValue) is a batch") }
        try command.apply(to: &timeline)
        check(timeline != bound, "\(variation.rawValue) changed the document")
        check(timeline.clips.map(\.duration) == bound.clips.map(\.duration), "\(variation.rawValue) kept every duration")
        check(timeline.clips.map(\.assetID) == bound.clips.map(\.assetID), "\(variation.rawValue) kept every asset")
        // Idempotent: applying again is a no-op.
        check(variation.command(for: timeline) == nil, "\(variation.rawValue) is idempotent")
        try command.revert(from: &timeline)
        check(timeline == bound, "\(variation.rawValue) reverts exactly")
    }
    // Cinematic ends on a fade to black and has film grain everywhere.
    var cine = bound
    try EditVariation.cinematic.command(for: cine)!.apply(to: &cine)
    check(cine.clips.last?.transitionIn?.kind == .fadeToBlack, "cinematic fades out")
    check(cine.clips.allSatisfy { $0.grain > 0 }, "cinematic grain")
    // Batch survives JSON (persisted history).
    let data = try RecipeSchema.encoder.encode(EditVariation.punchy.command(for: bound)!)
    let decoded = try RecipeSchema.decoder.decode(EditCommand.self, from: data)
    check(decoded == EditVariation.punchy.command(for: bound)!, "batch command round-trips JSON")
}

section("Beat retimer: cuts move onto the new grid, one undo step") {
    var timeline = Timeline(canvas: .reel1080)
    timeline.clips = (0..<6).map { i in VideoClip(assetID: UUID(), start: Double(i), duration: 1.0) }
    timeline.relayout()
    let original = timeline
    // 124 BPM grid: 0.4839 s apart, so 1.0 -> 0.968, 2.0 -> 1.935, 3.0 -> 2.903 ...
    let period = 60.0 / 124.0
    let beats = stride(from: 0.0, through: 7.0, by: period).map { $0 }
    guard let result = BeatRetimer.retime(timeline, toBeats: beats, tolerance: 0.14) else {
        check(false, "retimer produced a result"); return
    }
    check(result.movedBoundaries >= 4, "moved several boundaries (\(result.movedBoundaries))")
    if case .batch(let name, _) = result.command { check(name == "Snap Cuts to Music", "named batch") } else { check(false, "batch") }
    try result.command.apply(to: &timeline)
    check(timeline.clips.count == 6 && timeline.clips.map(\.assetID) == original.clips.map(\.assetID), "clips intact")
    let alignedAfter = BeatRetimer.alignment(of: timeline, toBeats: beats, tolerance: 0.04)
    let alignedBefore = BeatRetimer.alignment(of: original, toBeats: beats, tolerance: 0.04)
    check(alignedAfter > alignedBefore && alignedAfter >= 0.8, "alignment improved \(alignedBefore) -> \(alignedAfter)")
    for clip in timeline.clips { check(clip.duration >= timeline.canvas.frameDuration * 3, "no clip collapsed") }
    try result.command.revert(from: &timeline)
    check(timeline == original, "reverts exactly")
    // Already aligned -> nothing to do.
    check(BeatRetimer.retime(timeline, toBeats: [0, 1, 2, 3, 4, 5, 6]) == nil, "no-op when already on grid")
}

section("Starter templates bind cleanly") {
    check(StarterTemplates.all.count >= 8, "have starters (\(StarterTemplates.all.count))")
    for recipe in StarterTemplates.all {
        check(recipe.isBuiltIn == true && !(recipe.tags ?? []).isEmpty, "\(recipe.title) tagged built-in")
        check(abs(recipe.duration - recipe.scenes.last!.end) < 1e-6, "\(recipe.title) duration matches scenes")
        let (pool, refs) = samplePool(count: 4)
        var assignment = AssetAssignment()
        for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i % refs.count].id }
        var content = UserContent()
        for slot in recipe.textSlots { content.textBySlot[slot.id] = "hello" }
        let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: content)
        check(timeline.clips.count == recipe.scenes.count, "\(recipe.title) binds all scenes")
        check(timeline.textLayers.count == recipe.textSlots.count, "\(recipe.title) binds all text")
        check(abs(timeline.duration - recipe.duration) < 0.05, "\(recipe.title) duration preserved (\(timeline.duration) vs \(recipe.duration))")
        // Deterministic: same recipe twice.
        let again = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: content)
        check(again == timeline, "\(recipe.title) deterministic bind")
        // Round-trips through JSON.
        let data = try RecipeSchema.encoder.encode(recipe)
        let decoded = try RecipeSchema.decodeRecipe(data)
        check(decoded == recipe, "\(recipe.title) codable round trip")
    }
}

section("Music sections: quiet-loud-quiet segments as intro/peak/outro") {
    // 60 s at 4 Hz: 15 s low, 10 s rising, 15 s high, 10 s falling, 10 s low.
    var curve: [Double] = []
    curve += Array(repeating: 0.1, count: 60)
    curve += (0..<40).map { 0.1 + 0.8 * Double($0) / 39 }
    curve += Array(repeating: 0.95, count: 60)
    curve += (0..<40).map { 0.9 - 0.7 * Double($0) / 39 }
    curve += Array(repeating: 0.12, count: 40)
    let sections = MusicSectionizer.sections(energyCurve: curve, samplesPerSecond: 4, duration: 60)
    check(!sections.isEmpty, "produced sections (\(sections.count))")
    check(sections.first?.kind == .intro, "starts with intro (\(sections.first?.kind.rawValue ?? "none"))")
    check(sections.contains { $0.kind == .peak }, "found the peak")
    check(sections.last?.kind == .outro, "ends with outro (\(sections.last?.kind.rawValue ?? "none"))")
    check(abs((sections.last?.end ?? 0) - 60) < 1e-6, "covers the full duration")
    for (a, b) in zip(sections, sections.dropFirst()) { check(abs(a.end - b.start) < 1e-6, "contiguous") }
    // Deterministic.
    check(sections == MusicSectionizer.sections(energyCurve: curve, samplesPerSecond: 4, duration: 60), "deterministic")
    // Degenerate inputs do not crash and still cover the track.
    let flat = MusicSectionizer.sections(energyCurve: Array(repeating: 0.5, count: 100), samplesPerSecond: 4, duration: 25)
    check(flat.count == 1 && flat[0].kind == .steady, "flat curve is one steady section")
    let empty = MusicSectionizer.sections(energyCurve: [], samplesPerSecond: 4, duration: 10)
    check(empty.count == 1 && abs(empty[0].end - 10) < 1e-6, "empty curve still covers duration")
}

section("Music planner: sections pace the cut density") {
    // 120 BPM for 40 s: beat every 0.5 s. Energy: 10 s low, 10 s rise, 12 s high, 8 s fall.
    let bpm = 120.0
    let beats = stride(from: 0.0, through: 40.0, by: 0.5).map { $0 }
    let downbeats = stride(from: 0.0, through: 40.0, by: 2.0).map { $0 }
    var curve: [Double] = []
    curve += Array(repeating: 0.1, count: 40)
    curve += (0..<40).map { 0.1 + 0.8 * Double($0) / 39 }
    curve += Array(repeating: 0.95, count: 48)
    curve += (0..<32).map { 0.9 - 0.75 * Double($0) / 31 }
    let profile = MusicEditPlanner.MusicProfile(
        bpm: bpm, bpmConfidence: 0.9, beats: beats, downbeats: downbeats,
        energyCurve: curve, energySamplesPerSecond: 4, duration: 40, fingerprint: "check-track"
    )
    let recipe = MusicEditPlanner.plan(music: profile, options: .init(maxDuration: 40, assetCount: 12))
    check(recipe.scenes.count >= 6, "planned scenes (\(recipe.scenes.count))")
    check(recipe.beatGrid?.cutsAlignedToBeats.value == true, "declares beat alignment")
    check(recipe.audio.suggestedCutStyle == .onBeat, "suggests on-beat cutting")
    check(abs(recipe.duration - (recipe.scenes.last?.end ?? 0)) < 1e-6, "duration matches scenes")
    for (a, b) in zip(recipe.scenes, recipe.scenes.dropFirst()) {
        check(abs(a.end - b.start) < 1e-6, "scenes contiguous")
        check(a.duration > 0.3, "no micro-scene (\(a.duration))")
    }
    // Every interior boundary lands on a planned beat.
    let beatSet = Set(beats.map { Int(($0 * 1000).rounded()) })
    for scene in recipe.scenes.dropLast() {
        check(beatSet.contains(Int((scene.end * 1000).rounded())), "cut on beat (\(scene.end))")
    }
    // The loud stretch cuts faster than the quiet opening.
    let early = recipe.scenes.filter { $0.start < 10 }.map(\.duration)
    let peak = recipe.scenes.filter { $0.start >= 20 && $0.start < 32 }.map(\.duration)
    if let e = early.first, let p = peak.min() {
        check(e > p, "intro shot (\(e)s) longer than peak shot (\(p)s)")
    } else {
        check(false, "expected scenes in both regions")
    }
    // Deterministic, and the recipe binds through the normal pipeline.
    check(MusicEditPlanner.plan(music: profile, options: .init(maxDuration: 40, assetCount: 12)) == recipe, "deterministic plan")
    let (pool, refs) = samplePool(count: 6)
    var assignment = AssetAssignment()
    for (i, scene) in recipe.scenes.enumerated() { assignment[scene.slot.id] = refs[i % refs.count].id }
    let timeline = RecipeBinder().bind(recipe: recipe, assets: pool, assignment: assignment, content: UserContent())
    check(timeline.clips.count == recipe.scenes.count, "binds all scenes")
    // Codable round trip like any other recipe.
    let data = try RecipeSchema.encoder.encode(recipe)
    let decoded = try RecipeSchema.decodeRecipe(data)
    check(decoded == recipe, "codable round trip")
    // No beats at all: still plans a usable edit.
    let dry = MusicEditPlanner.plan(
        music: .init(bpm: 0, bpmConfidence: 0, beats: [], downbeats: [], energyCurve: [],
                     duration: 20, fingerprint: "no-beats"),
        options: .init(maxDuration: 20, assetCount: 5)
    )
    check(dry.scenes.count >= 4, "beatless track still plans (\(dry.scenes.count) scenes)")
}

section("Edit quality: catches empty slots, repeats and off-grid cuts") {
    let canvas = CanvasSpec.reel1080
    let a = UUID(), b = UUID(), c = UUID()
    func clip(_ id: UUID?, _ start: Double, _ duration: Double) -> VideoClip {
        VideoClip(assetID: id, slotID: "s\(Int(start * 100))", start: start, duration: duration)
    }
    var timeline = Timeline(id: UUID(), canvas: canvas, recipeID: nil)
    timeline.clips = [clip(a, 0, 1), clip(b, 1, 1), clip(c, 2, 1), clip(a, 3, 1)]
    let good = EditQuality.score(timeline: timeline)
    check(good.isAcceptable && good.issues.isEmpty, "clean edit scores clean (\(good.summary))")

    // Same asset back to back.
    timeline.clips = [clip(a, 0, 1), clip(a, 1, 1), clip(b, 2, 1), clip(c, 3, 1)]
    let repeated = EditQuality.score(timeline: timeline)
    check(repeated.issues.contains { $0.kind == .adjacentRepeat }, "flags adjacent repeat")
    check(repeated.total < good.total, "repeat scores lower")

    // Empty slot and a two-frame clip.
    timeline.clips = [clip(a, 0, 1), clip(nil, 1, 1), clip(b, 2, canvas.frameDuration * 2)]
    let broken = EditQuality.score(timeline: timeline)
    check(broken.issues.contains { $0.kind == .emptySlot }, "flags empty slot")
    check(broken.issues.contains { $0.kind == .tooShortClip }, "flags too-short clip")
    check(!broken.isAcceptable, "broken edit rejected (\(broken.summary))")

    // One asset everywhere.
    timeline.clips = [clip(a, 0, 1), clip(b, 1, 1), clip(a, 2, 1), clip(b, 3, 1), clip(a, 4, 1), clip(a, 5, 1)]
    let lopsided = EditQuality.score(timeline: timeline)
    check(lopsided.issues.contains { $0.kind == .overusedAsset }, "flags overused asset")

    // Beat-planned edit whose cuts miss the grid.
    let grid = BeatGrid(
        bpm: .measured(120), beats: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 },
        downbeats: [0, 2, 4, 6, 8], cutsAlignedToBeats: .measured(true)
    )
    timeline.clips = [clip(a, 0, 0.73), clip(b, 0.73, 0.91), clip(c, 1.64, 0.77), clip(a, 2.41, 1.0)]
    let offGrid = EditQuality.score(timeline: timeline, beatGrid: grid)
    check(offGrid.issues.contains { $0.kind == .offGridCut }, "flags off-grid cuts")
    timeline.clips = [clip(a, 0, 1.0), clip(b, 1.0, 0.5), clip(c, 1.5, 1.0), clip(a, 2.5, 1.0)]
    let onGrid = EditQuality.score(timeline: timeline, beatGrid: grid)
    check(onGrid.rhythm == 1.0, "on-grid cuts score full rhythm")

    // A photo dragged across 17 s of timeline is flagged; the same duration on video is not.
    let (pool, refs) = samplePool(count: 4)
    let photo = refs[0], video = refs[2]
    timeline.clips = [clip(photo.id, 0, 16.9), clip(video.id, 16.9, 0.7)]
    let still = EditQuality.score(timeline: timeline, assets: pool)
    check(still.issues.contains { $0.kind == .longStillScene }, "flags a long still scene")
    timeline.clips = [clip(video.id, 0, 16.9), clip(photo.id, 16.9, 0.7)]
    let motion = EditQuality.score(timeline: timeline, assets: pool)
    check(!motion.issues.contains { $0.kind == .longStillScene }, "long video scene is fine")
}

print("")
print(failures == 0 ? "ALL \(passes) CHECKS PASSED" : "\(failures) FAILED, \(passes) passed")
exit(failures == 0 ? 0 : 1)
