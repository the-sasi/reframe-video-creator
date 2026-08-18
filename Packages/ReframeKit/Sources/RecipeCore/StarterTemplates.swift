import Foundation

/// Built-in styles for the template library, so the app is useful before the first reference
/// has been analysed and so "Start From Scratch" is a choice of feel rather than a blank slate.
///
/// Generated deterministically from a compact description rather than checked in as JSON:
/// forty lines of Swift beat a thousand lines of fixture, and every one of these goes through
/// the same binder as an analysed recipe. Their confidence values are 1.0 — nothing here was
/// inferred; it was chosen.
public enum StarterTemplates {

    /// A scene in shorthand.
    private struct Beat {
        var duration: Double
        var move: CameraMoveKind = .none
        var transition: TransitionKind = .cut
        var transitionDuration: Double = 0
        var framing: ShotFraming = .medium
        var role: SceneRole = .body
    }

    private struct TextSpec {
        var role: TextRole
        var start: Double
        var end: Double
        var frame: NormalizedRect
        var sizeRatio: Double
        var category: FontCategory = .sansSerif
        var entry: TextEntryAnimation = .fadeIn
        var alignment: TextAlignment = .center
        var hint: String
    }

    private struct Spec {
        var key: String
        var title: String
        var tags: [String]
        var canvas: CanvasSpec
        var beats: [Beat]
        var text: [TextSpec] = []
        var palette: [String] = []
    }

    public static let all: [EditRecipe] = specs.map(build)

    public static func recipe(key: String) -> EditRecipe? {
        all.first { $0.title == specs.first { $0.key == key }?.title }
    }

    // MARK: - Catalogue

    private static let specs: [Spec] = [
        fastReel, photoMontage, cinematic, productAd, minimal,
        slideshow, squarePost, travel, quote, portraitFeed,
    ]

    private static let fastReel: Spec = {
        let beats: [Beat] = (0..<12).map { (i: Int) -> Beat in
            Beat(duration: 0.55, move: i.isMultiple(of: 2) ? .zoomIn : .zoomOut,
                 transition: .cut, framing: i.isMultiple(of: 3) ? .wide : .closeUp)
        }
        let text: [TextSpec] = [
            TextSpec(role: .title, start: 0.2, end: 1.9,
                     frame: NormalizedRect(x: 0.08, y: 0.14, width: 0.84, height: 0.14),
                     sizeRatio: 0.07, category: .displayBold, entry: .popIn, hint: "BIG BOLD TITLE"),
            TextSpec(role: .cta, start: 5.4, end: 6.6,
                     frame: NormalizedRect(x: 0.1, y: 0.74, width: 0.8, height: 0.1),
                     sizeRatio: 0.05, category: .displayBold, entry: .wordByWord, hint: "TAP THE LINK"),
        ]
        return Spec(key: "fast-reel", title: "Fast Reel", tags: ["Fast Reel", "Beat Sync"],
                    canvas: .reel1080, beats: beats, text: text, palette: ["#111111", "#F5F5F5", "#E9448B"])
    }()

    private static let photoMontage: Spec = {
        let beats: [Beat] = (0..<8).map { (i: Int) -> Beat in
            Beat(duration: 2.0, move: i.isMultiple(of: 2) ? .zoomIn : .panRight,
                 transition: i == 0 ? .cut : .dissolve, transitionDuration: 0.45,
                 framing: .medium, role: i == 0 ? .opening : (i == 7 ? .closing : .body))
        }
        let text: [TextSpec] = [
            TextSpec(role: .title, start: 0.4, end: 3.6,
                     frame: NormalizedRect(x: 0.1, y: 0.42, width: 0.8, height: 0.16),
                     sizeRatio: 0.06, category: .serif, entry: .fadeIn, hint: "A little story"),
        ]
        return Spec(key: "photo-montage", title: "Photo Montage", tags: ["Photo Montage", "Emotional"],
                    canvas: .reel1080, beats: beats, text: text, palette: ["#F3E9DD", "#8A6A52", "#FFFFFF"])
    }()

    private static let cinematic: Spec = {
        let moves: [CameraMoveKind] = [.zoomIn, .panLeft, .zoomOut, .panRight, .zoomIn, .none]
        let beats: [Beat] = (0..<6).map { (i: Int) -> Beat in
            Beat(duration: 2.5, move: moves[i],
                 transition: i == 0 ? .cut : (i == 3 ? .fadeToBlack : .dissolve),
                 transitionDuration: i == 3 ? 0.7 : 0.5, framing: .wide,
                 role: i == 0 ? .opening : (i == 5 ? .closing : .wide))
        }
        let text: [TextSpec] = [
            TextSpec(role: .title, start: 5.4, end: 8.4,
                     frame: NormalizedRect(x: 0.15, y: 0.4, width: 0.7, height: 0.2),
                     sizeRatio: 0.09, category: .serif, entry: .fadeIn, hint: "TITLE"),
        ]
        return Spec(key: "cinematic", title: "Cinematic", tags: ["Cinematic", "Luxury"],
                    canvas: CanvasSpec(width: 1920, height: 1080, fps: 24), beats: beats, text: text,
                    palette: ["#0B0B0F", "#C9A96E", "#E8E8E8"])
    }()

    private static let productAd: Spec = {
        let beats: [Beat] = [
            Beat(duration: 1.6, move: .zoomIn, framing: .wide, role: .opening),
            Beat(duration: 0.9, move: .zoomIn, transition: .cut, framing: .closeUp, role: .detail),
            Beat(duration: 0.9, move: .panLeft, transition: .cut, framing: .closeUp, role: .detail),
            Beat(duration: 1.4, move: .zoomOut, transition: .push, transitionDuration: 0.3, framing: .medium, role: .hero),
            Beat(duration: 0.9, move: .zoomIn, transition: .cut, framing: .closeUp, role: .detail),
            Beat(duration: 0.9, move: .panRight, transition: .cut, framing: .closeUp, role: .detail),
            Beat(duration: 2.0, move: .zoomIn, transition: .dissolve, transitionDuration: 0.35, framing: .medium, role: .closing),
        ]
        let text: [TextSpec] = [
            TextSpec(role: .title, start: 0.3, end: 2.2,
                     frame: NormalizedRect(x: 0.08, y: 0.12, width: 0.84, height: 0.14),
                     sizeRatio: 0.066, category: .displayBold, entry: .slideUp, hint: "PRODUCT NAME"),
            TextSpec(role: .subtitle, start: 4.9, end: 6.4,
                     frame: NormalizedRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1),
                     sizeRatio: 0.042, entry: .fadeIn, hint: "One line about it"),
            TextSpec(role: .cta, start: 6.9, end: 8.5,
                     frame: NormalizedRect(x: 0.1, y: 0.44, width: 0.8, height: 0.12),
                     sizeRatio: 0.06, category: .displayBold, entry: .popIn, hint: "DM TO ORDER"),
        ]
        return Spec(key: "product-ad", title: "Product Ad", tags: ["Product", "Business"],
                    canvas: .reel1080, beats: beats, text: text, palette: ["#FFFFFF", "#1C1C1E", "#E9448B"])
    }()

    private static let minimal: Spec = {
        let beats: [Beat] = (0..<5).map { (_: Int) -> Beat in
            Beat(duration: 1.6, move: .none, transition: .cut, framing: .medium)
        }
        let text: [TextSpec] = [
            TextSpec(role: .caption, start: 0.5, end: 7.5,
                     frame: NormalizedRect(x: 0.1, y: 0.82, width: 0.8, height: 0.08),
                     sizeRatio: 0.032, entry: .fadeIn, hint: "a quiet caption"),
        ]
        return Spec(key: "minimal", title: "Minimal", tags: ["Minimal"],
                    canvas: .reel1080, beats: beats, text: text, palette: ["#FAFAFA", "#222222"])
    }()

    private static let slideshow: Spec = {
        let moves: [CameraMoveKind] = [.zoomIn, .zoomOut, .panLeft, .panRight]
        let beats: [Beat] = (0..<10).map { (i: Int) -> Beat in
            Beat(duration: 3.0, move: moves[i % 4],
                 transition: i == 0 ? .cut : .dissolve, transitionDuration: 0.6, framing: .medium)
        }
        return Spec(key: "slideshow", title: "Slideshow", tags: ["Photo Montage", "Wedding", "Birthday"],
                    canvas: .reel1080, beats: beats, palette: ["#FFF7F0", "#D8A7B1", "#6B4E71"])
    }()

    private static let squarePost: Spec = {
        let beats: [Beat] = (0..<6).map { (i: Int) -> Beat in
            Beat(duration: 1.2, move: i.isMultiple(of: 2) ? .zoomIn : .zoomOut,
                 transition: i == 0 ? .cut : .slide, transitionDuration: 0.3, framing: .closeUp)
        }
        let text: [TextSpec] = [
            TextSpec(role: .title, start: 0.2, end: 2.0,
                     frame: NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.14),
                     sizeRatio: 0.075, category: .displayBold, entry: .popIn, hint: "NEW IN"),
        ]
        return Spec(key: "square-post", title: "Square Post", tags: ["Product", "Fashion", "Food"],
                    canvas: .square1080, beats: beats, text: text, palette: ["#F2EDE4", "#2B2B2B", "#C46A4A"])
    }()

    private static let travel: Spec = {
        let moves: [CameraMoveKind] = [.zoomIn, .panRight, .zoomOut, .panLeft, .zoomIn, .panRight, .zoomIn, .panLeft, .zoomOut]
        let beats: [Beat] = (0..<9).map { (i: Int) -> Beat in
            Beat(duration: i == 0 ? 1.8 : 1.1, move: moves[i],
                 transition: i == 0 ? .cut : (i % 3 == 0 ? .whip : .cut), transitionDuration: 0.22,
                 framing: i % 3 == 0 ? .wide : .medium, role: i == 0 ? .opening : .body)
        }
        let text: [TextSpec] = [
            TextSpec(role: .title, start: 0.3, end: 1.9,
                     frame: NormalizedRect(x: 0.08, y: 0.72, width: 0.84, height: 0.14),
                     sizeRatio: 0.064, category: .handwritten, entry: .slideUp, alignment: .leading, hint: "Somewhere new"),
        ]
        return Spec(key: "travel", title: "Travel Story", tags: ["Travel", "Fast Reel"],
                    canvas: .reel1080, beats: beats, text: text, palette: ["#1E2A38", "#F4C15D", "#FFFFFF"])
    }()

    private static let quote: Spec = {
        let beats: [Beat] = (0..<4).map { (i: Int) -> Beat in
            Beat(duration: 3.0, move: .zoomIn, transition: i == 0 ? .cut : .fadeToBlack,
                 transitionDuration: 0.5, framing: .wide)
        }
        let text: [TextSpec] = (0..<4).map { (i: Int) -> TextSpec in
            TextSpec(role: i == 0 ? .title : .caption, start: Double(i) * 3.0 + 0.4, end: Double(i) * 3.0 + 2.7,
                     frame: NormalizedRect(x: 0.1, y: 0.36, width: 0.8, height: 0.28),
                     sizeRatio: i == 0 ? 0.062 : 0.05, category: .serif, entry: .wordByWord,
                     hint: i == 0 ? "The first line of the thought" : "and the next")
        }
        return Spec(key: "quote", title: "Words First", tags: ["Text Heavy", "Emotional", "Business"],
                    canvas: .reel1080, beats: beats, text: text, palette: ["#101010", "#EDEDED"])
    }()

    private static let portraitFeed: Spec = {
        let beats: [Beat] = (0..<7).map { (i: Int) -> Beat in
            Beat(duration: 1.3, move: i.isMultiple(of: 2) ? .zoomIn : .none,
                 transition: i == 0 ? .cut : .dissolve, transitionDuration: 0.3, framing: .medium)
        }
        return Spec(key: "portrait-45", title: "Portrait Feed", tags: ["Product", "Fashion", "Minimal"],
                    canvas: CanvasSpec(width: 1080, height: 1350, fps: 30), beats: beats,
                    palette: ["#F7F7F5", "#2E2E2E"])
    }()

    // MARK: - Builder

    private static func build(_ spec: Spec) -> EditRecipe {
        let ids = DeterministicID(seed: "starter/\(spec.key)")
        var cursor = 0.0
        var scenes: [SceneTemplate] = []
        for (index, beat) in spec.beats.enumerated() {
            let start = cursor
            let end = cursor + beat.duration
            cursor = end

            let move: CameraMove
            switch beat.move {
            case .none:
                move = .still
            case .zoomIn:
                move = CameraMove(kind: .measured(.zoomIn, "starter"), startRect: .full,
                                  endRect: NormalizedRect.full.scaled(by: 0.86), easing: .easeInOut)
            case .zoomOut:
                move = CameraMove(kind: .measured(.zoomOut, "starter"), startRect: NormalizedRect.full.scaled(by: 0.86),
                                  endRect: .full, easing: .easeInOut)
            case .panLeft, .panRight, .panUp, .panDown, .rotate, .complex:
                let base = NormalizedRect.full.scaled(by: 0.86)
                let dx = beat.move == .panLeft ? 0.06 : (beat.move == .panRight ? -0.06 : 0)
                let dy = beat.move == .panUp ? 0.06 : (beat.move == .panDown ? -0.06 : 0)
                move = CameraMove(kind: .measured(beat.move, "starter"),
                                  startRect: base.offset(dx: dx, dy: dy).clampedInsideUnitSquare(),
                                  endRect: base.offset(dx: -dx, dy: -dy).clampedInsideUnitSquare(),
                                  easing: .easeInOut)
            }

            let transition: TransitionTemplate? = index == 0 ? nil : TransitionTemplate(
                kind: .measured(beat.transition, "starter"),
                duration: beat.transitionDuration,
                direction: beat.transition.needsDirection ? .left : nil,
                safeFallback: .cut
            )

            scenes.append(
                SceneTemplate(
                    id: ids.string("scene", index + 1), index: index, start: start, end: end,
                    sourceKind: .image,
                    role: .measured(beat.role, "starter"),
                    slot: AssetSlot(
                        id: ids.string("asset", index + 1),
                        framing: .measured(beat.framing, "starter"),
                        motionEnergy: beat.move == .none ? 0 : 0.2
                    ),
                    move: move,
                    transitionIn: transition
                )
            )
        }

        let textSlots = spec.text.enumerated().map { index, text in
            TextSlotTemplate(
                id: ids.string("text", index + 1), role: text.role, start: text.start, end: text.end,
                frame: text.frame, alignment: text.alignment,
                style: TextStyleTemplate(
                    category: .measured(text.category, "starter"), sizeRatio: text.sizeRatio,
                    colorHex: "#FFFFFF", shadow: .measured(true, "starter")
                ),
                animation: TextAnimation(entry: .measured(text.entry, "starter"), exit: .measured(.fadeOut, "starter")),
                sampleText: text.hint, charCountHint: text.hint.count
            )
        }

        let durations = spec.beats.map(\.duration).sorted()
        let median = durations.isEmpty ? 0 : durations[durations.count / 2]
        let transitionCount = scenes.filter { ($0.transitionIn?.effectiveKind ?? .cut) != .cut }.count

        return EditRecipe(
            id: ids.uuid("recipe"),
            title: spec.title,
            createdAt: Date(timeIntervalSince1970: 0),
            source: SourceInfo(
                duration: cursor, fps: Double(spec.canvas.fps), width: spec.canvas.width, height: spec.canvas.height,
                aspect: AspectPreset(width: spec.canvas.width, height: spec.canvas.height),
                hasAudio: false, fingerprint: "starter/\(spec.key)"
            ),
            canvas: spec.canvas,
            duration: cursor,
            beatGrid: nil,
            scenes: scenes,
            textSlots: textSlots,
            audio: .silent,
            palette: Palette(dominant: spec.palette, meanBrightness: 0.5, meanSaturation: 0.4, contrast: 1),
            stats: RecipeStats(
                sceneCount: scenes.count, medianSceneDuration: median,
                cutsPerSecond: cursor > 0 ? Double(max(0, scenes.count - 1)) / cursor : 0,
                transitionCount: transitionCount, textSlotCount: textSlots.count
            ),
            confidence: ConfidenceReport(overall: 1, scenes: 1, motion: 1, text: 1, audio: 1, weakest: "none"),
            tags: spec.tags,
            isBuiltIn: true
        )
    }
}
