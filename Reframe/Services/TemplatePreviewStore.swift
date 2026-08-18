import AVFoundation
import Observation
import ReframeKit
import SwiftUI
import UIKit

/// Renders a short looping preview of a style — the real timeline, through the real binder
/// and exporter — using procedural placeholder stills, so a template card shows the actual
/// cuts, moves, transitions and text of the style instead of an abstract swatch.
///
/// Why not bundle sample footage: Reframe ships no media. Placeholder art is generated on the
/// device in a few milliseconds and the preview is a ~300 KB, 360 px H.264 file in Caches, so
/// nothing is copied into the app bundle and nothing is somebody else's footage. Previews are
/// rendered lazily (first time a card is seen), one at a time, and survive relaunches until iOS
/// evicts Caches — at which point they are simply rendered again.
@MainActor
@Observable
final class TemplatePreviewStore {

    enum State: Equatable {
        case queued
        case rendering
        case ready(URL)
        case unavailable(String)
    }

    private(set) var states: [UUID: State] = [:]
    private(set) var posters: [UUID: UIImage] = [:]

    private let renderer: MetalRenderer?
    private let resolver: AssetResolver
    private var queue: [EditRecipe] = []
    private var worker: Task<Void, Never>?

    /// Bump when the placeholder art or preview settings change, so stale files re-render.
    private static let version = "v1"
    /// Anything longer than this is a full reference edit, not a style you browse — the swatch
    /// is enough for those and a render would take real time.
    private static let maxPreviewDuration: Double = 45

    init(renderer: MetalRenderer?, resolver: AssetResolver) {
        self.renderer = renderer
        self.resolver = resolver
    }

    // MARK: - Public

    /// The preview file if it exists (in memory or already on disk from a previous launch).
    /// Pure — safe to call from a view body; `request` is what records state.
    func previewURL(for recipe: EditRecipe) -> URL? {
        if case .ready(let url) = states[recipe.id] { return url }
        let url = Self.previewFile(for: recipe)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func state(for recipe: EditRecipe) -> State? { states[recipe.id] }

    /// Ensures a preview exists or is on its way. Cheap to call from `.task` on every card.
    func request(_ recipe: EditRecipe) {
        if let state = states[recipe.id] {
            switch state {
            case .ready(let url):
                loadPosterIfNeeded(recipe: recipe, url: url)
                return
            case .queued, .rendering, .unavailable:
                return
            }
        }
        if let url = previewURL(for: recipe) {
            // Left over from a previous launch — adopt it.
            states[recipe.id] = .ready(url)
            loadPosterIfNeeded(recipe: recipe, url: url)
            return
        }
        guard renderer != nil else {
            states[recipe.id] = .unavailable("Metal unavailable")
            return
        }
        guard recipe.duration <= Self.maxPreviewDuration, !recipe.scenes.isEmpty else {
            states[recipe.id] = .unavailable("style too long for a preview")
            return
        }
        states[recipe.id] = .queued
        queue.append(recipe)
        startWorkerIfNeeded()
    }

    /// Drops a preview so it renders again (after a rename it does not need to; after a
    /// duplicate the copy has its own id and renders on its own).
    func invalidate(recipeID: UUID) {
        states[recipeID] = nil
        posters[recipeID] = nil
        queue.removeAll { $0.id == recipeID }
    }

    /// Frees the in-memory posters; the files on disk stay.
    func handleMemoryPressure() {
        posters.removeAll()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let recipe = self.queue.removeFirst()
                await self.render(recipe)
            }
            self?.worker = nil
        }
    }

    private func render(_ recipe: EditRecipe) async {
        guard let renderer else { return }
        states[recipe.id] = .rendering
        let started = Date()
        do {
            let url = try await Self.renderPreview(recipe: recipe, renderer: renderer, resolver: resolver)
            states[recipe.id] = .ready(url)
            loadPosterIfNeeded(recipe: recipe, url: url)
            DiagnosticsLog.shared.info(
                "templates",
                "preview rendered for \(recipe.title) in \(String(format: "%.1fs", Date().timeIntervalSince(started)))"
            )
        } catch {
            let detail = (error as? ReframeError)?.logDetail ?? "\(error)"
            states[recipe.id] = .unavailable(detail)
            DiagnosticsLog.shared.warning("templates", "preview failed for \(recipe.title): \(detail)")
        }
    }

    private func loadPosterIfNeeded(recipe: EditRecipe, url: URL) {
        guard posters[recipe.id] == nil else { return }
        let id = recipe.id
        let at = min(1.0, max(0, recipe.duration * 0.15))
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            guard let result = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)) else { return }
            self?.posters[id] = UIImage(cgImage: result.image)
        }
    }

    // MARK: - Rendering

    private static func renderPreview(recipe: EditRecipe, renderer: MetalRenderer, resolver: AssetResolver) async throws -> URL {
        // 1. Placeholder stills, one per distinct slot (capped — a 30-cut reel reuses art,
        //    which is exactly what a user with eight photos gets too).
        let slotCount = min(max(recipe.scenes.count, 1), 8)
        let canvas = recipe.canvas
        var pool = AssetPool()
        var assetIDs: [UUID] = []
        for index in 0..<slotCount {
            let framing = recipe.scenes[index].slot.framing.value
            let (relativePath, size) = try await PlaceholderArt.ensureImage(index: index, framing: framing, canvas: canvas)
            let reference = AssetReference(
                id: DeterministicID(seed: "template-preview/\(relativePath)").uuid("asset"),
                kind: .image,
                origin: .sandboxRelativePath(relativePath),
                displayName: "Placeholder \(index + 1)",
                pixelWidth: Int(size.width),
                pixelHeight: Int(size.height)
            )
            pool.add(reference)
            assetIDs.append(reference.id)
        }

        // 2. Sequential assignment — scene i gets art i (mod count), so the rhythm reads.
        var assignment = AssetAssignment()
        for (index, scene) in recipe.scenes.enumerated() {
            assignment.assetBySlot[scene.slot.id] = assetIDs[index % assetIDs.count]
        }

        // 3. Text: starters carry our own hint copy, which is fine to show. Analysed styles
        //    carry the *reference's* words, which are never rendered (docs/02) — a role label
        //    stands in so the layout still shows.
        var content = UserContent()
        for slot in recipe.fillableTextSlots {
            let text: String
            if recipe.isBuiltIn == true, let hint = slot.sampleText, !hint.isEmpty {
                text = hint
            } else {
                switch slot.role {
                case .title: text = "Your Title"
                case .subtitle: text = "A line under it"
                case .cta: text = "Tap the link"
                case .caption: text = "Caption goes here"
                case .watermark: continue
                }
            }
            content.textBySlot[slot.id] = text
        }

        let timeline = RecipeBinder().bind(
            recipe: recipe, assets: pool, assignment: assignment, content: content,
            options: RecipeBinder.Options(fidelity: .closeMatch)
        )
        guard timeline.duration > 0 else {
            throw ReframeError.exportFailed(detail: "style has no duration")
        }

        // 4. Export small. H.264 rather than HEVC so the poster generator and AVPlayer are
        //    trivially happy on every device.
        let settings = ExportSettings.matching(canvas: canvas, shortSide: 360, preferHEVC: false, quality: .standard)
        let output = previewFile(for: recipe)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let request = VideoExporter.Request(timeline: timeline, assets: pool, settings: settings, outputURL: output)
        let exporter = VideoExporter(renderer: renderer)
        return try await exporter.export(request, resolver: resolver) { _ in }
    }

    private static func previewFile(for recipe: EditRecipe) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Content-addressed enough: a style's id is stable, and its structure only changes
        // through save paths that also change the id (duplicate) or nothing visual (rename).
        let name = "\(recipe.id.uuidString)-\(recipe.scenes.count)-\(Int(recipe.duration * 10))-\(version).mp4"
        return caches.appendingPathComponent("TemplatePreviews", isDirectory: true).appendingPathComponent(name)
    }
}

// MARK: - Placeholder art

/// Procedural stand-in photos: a two-colour gradient with a soft "subject" whose size follows
/// the slot's framing, so a close-up slot shows a big shape and a wide slot a small one and the
/// smart crop has something to bite on. Written once to Documents (the resolver's sandbox
/// origin) and reused by every preview with the same aspect.
enum PlaceholderArt {

    private static let palettes: [(UIColor, UIColor, UIColor)] = [
        (rgb(0.16, 0.20, 0.32), rgb(0.42, 0.36, 0.62), rgb(0.93, 0.86, 0.98)),
        (rgb(0.85, 0.55, 0.32), rgb(0.98, 0.80, 0.55), rgb(1.00, 0.96, 0.88)),
        (rgb(0.10, 0.36, 0.38), rgb(0.35, 0.70, 0.66), rgb(0.88, 0.98, 0.95)),
        (rgb(0.30, 0.12, 0.20), rgb(0.75, 0.30, 0.42), rgb(0.99, 0.88, 0.90)),
        (rgb(0.20, 0.28, 0.18), rgb(0.55, 0.68, 0.40), rgb(0.94, 0.98, 0.86)),
        (rgb(0.14, 0.14, 0.16), rgb(0.45, 0.45, 0.50), rgb(0.96, 0.96, 0.97)),
        (rgb(0.60, 0.42, 0.18), rgb(0.95, 0.78, 0.42), rgb(1.00, 0.97, 0.86)),
        (rgb(0.18, 0.28, 0.50), rgb(0.50, 0.72, 0.92), rgb(0.92, 0.97, 1.00)),
    ]

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Returns the Documents-relative path and pixel size, drawing the file if it is missing.
    static func ensureImage(index: Int, framing: ShotFraming, canvas: CanvasSpec) async throws -> (String, CGSize) {
        let aspect = canvas.aspectRatio
        let short: CGFloat = 720
        let size = aspect >= 1
            ? CGSize(width: (short * aspect).rounded(), height: short)
            : CGSize(width: short, height: (short / aspect).rounded())
        let key = String(format: "%dx%d", Int(size.width), Int(size.height))
        let relative = "TemplatePreviews/placeholders/\(key)-\(index % palettes.count)-\(framing.rawValue).png"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) { return (relative, size) }

        let data = await Task.detached(priority: .utility) {
            draw(index: index, framing: framing, size: size)
        }.value
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return (relative, size)
    }

    nonisolated private static func draw(index: Int, framing: ShotFraming, size: CGSize) -> Data {
        let (dark, light, subject) = palettes[index % palettes.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext

            // Ground: diagonal gradient, direction alternating so consecutive frames differ.
            let flip = index.isMultiple(of: 2)
            let colors = [dark.cgColor, light.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let start = flip ? CGPoint(x: 0, y: 0) : CGPoint(x: size.width, y: 0)
                let end = flip ? CGPoint(x: size.width, y: size.height) : CGPoint(x: 0, y: size.height)
                cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }

            // Subject: a soft disc sized by framing, offset a little so crops have somewhere
            // to go. Two rings give the zoom something to reveal.
            let shortSide = min(size.width, size.height)
            let radius: CGFloat
            switch framing {
            case .closeUp: radius = shortSide * 0.34
            case .medium: radius = shortSide * 0.24
            case .wide: radius = shortSide * 0.15
            }
            let dx = shortSide * (index % 3 == 0 ? 0 : (index % 3 == 1 ? 0.10 : -0.10))
            let dy = shortSide * (framing == .wide ? 0.06 : -0.04)
            let center = CGPoint(x: size.width / 2 + dx, y: size.height / 2 + dy)

            // Halo
            if let halo = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [subject.withAlphaComponent(0.55).cgColor, subject.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                cg.drawRadialGradient(halo, startCenter: center, startRadius: radius * 0.6, endCenter: center, endRadius: radius * 1.9, options: [])
            }
            // Disc
            cg.setFillColor(subject.withAlphaComponent(0.92).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            // Inner ring
            cg.setStrokeColor(dark.withAlphaComponent(0.35).cgColor)
            cg.setLineWidth(max(2, radius * 0.06))
            let inner = radius * 0.62
            cg.strokeEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))

            // Horizon line for wide shots — reads as landscape at a glance.
            if framing == .wide {
                cg.setStrokeColor(subject.withAlphaComponent(0.25).cgColor)
                cg.setLineWidth(2)
                let y = center.y + radius * 1.4
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
                cg.strokePath()
            }

            // Vignette
            if let vignette = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.28).cgColor] as CFArray,
                locations: [0.55, 1]
            ) {
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                cg.drawRadialGradient(vignette, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(size.width, size.height) * 0.75, options: [.drawsAfterEndLocation])
            }

            // A quiet label so nobody mistakes the art for content.
            let label = "PHOTO \(index + 1)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: shortSide * 0.028, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.55),
                .kern: 1.5,
            ]
            let textSize = (label as NSString).size(withAttributes: attributes)
            let pad = shortSide * 0.04
            let origin = CGPoint(x: pad, y: size.height - pad - textSize.height)
            (label as NSString).draw(at: origin, withAttributes: attributes)
        }
        return image.pngData() ?? Data()
    }
}
