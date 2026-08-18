import CoreGraphics
import ImageIO
import Observation
import Photos
import ReframeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// App-wide state and service wiring.
///
/// Holds the in-flight project — recipe, assets, words, assignment — because the primary flow
/// spans several screens and the work-in-progress belongs to the flow rather than to any one of
/// them. The editable document itself lives in `TimelineDocument`, which owns the undo stack.
@MainActor
@Observable
final class AppModel {

    // MARK: Navigation

    var path: [Route] = []
    var presentedError: ErrorWrapper?

    // MARK: Services

    let projectStore = ProjectStore()
    let resolver: AssetResolver
    let intelligence = IntelligenceService()
    private(set) var renderer: MetalRenderer?
    /// Looping previews for the template library, rendered lazily on the device.
    private(set) var templatePreviews: TemplatePreviewStore

    // MARK: In-flight project

    var recipe: EditRecipe?
    var assets = AssetPool()
    var content = UserContent()
    var assignment = AssetAssignment()
    var assetFeatures: [UUID: AssetFeatures] = [:]
    var document: TimelineDocument?
    var exportSettings: ExportSettings = .default

    /// How much of the reference to reproduce. Chosen on the summary screen.
    var fidelity: BindingFidelity = .closeMatch

    /// Whether to apply the reference's inferred colour to your photos.
    ///
    /// Off by default and deliberately so: an automatic grade applied to somebody else's
    /// photographs reads as a bug rather than a style when it is wrong.
    var matchReferenceLook = false

    /// The reference file, kept only for the length of the flow so its soundtrack can be
    /// extracted *if the user asks*. Cleared when the flow ends. Analysis never reads it again.
    var referenceURL: URL?

    /// Beat grid of the user's music, analysed with the same detector the reference went
    /// through. Nil until a track has been added and analysed.
    var musicBeatGrid: BeatGrid?
    var isAnalyzingMusic = false

    /// The grid the timeline snaps to: the user's music when there is one, else the reference's.
    var activeBeatGrid: BeatGrid? { musicBeatGrid ?? recipe?.beatGrid }

    /// Identity of the project being edited.
    ///
    /// Deliberately *not* derived from `timeline.id`. `RecipeBinder` generates that
    /// deterministically from the reference's fingerprint, so two projects made from the same
    /// reference would collide and the second would silently overwrite the first.
    var currentProjectID = UUID()
    var projectTitle: String?
    var projectCreatedAt: Date?
    var projectIsFavorite = false
    var projectThumbnailPath: String?

    /// Recent projects for the home screen.
    var recentProjects: [ProjectSummary] = []
    var savedRecipes: [EditRecipe] = []

    /// A project that was open when the app last stopped without a clean save.
    var recoveryCandidate: ProjectSummary?

    struct ProjectSummary: Identifiable, Hashable {
        let id: UUID
        var title: String
        let createdAt: Date
        let modifiedAt: Date
        let sceneCount: Int
        let duration: Double
        var isFavorite: Bool
        let thumbnailURL: URL?
        let canvasAspect: Double
    }

    private var autosaveTask: Task<Void, Never>?
    private var pendingThumbnail: CGImage?

    private enum Defaults {
        static let openProjectID = "reframe.openProjectID"
        static let cleanExit = "reframe.cleanExit"
    }

    init() {
        let resolver = AssetResolver()
        self.resolver = resolver
        var renderer: MetalRenderer?
        do {
            renderer = try MetalRenderer()
        } catch let error as ReframeError {
            // Surfaced on first use rather than at launch — a Metal failure on the Simulator
            // should not stop the user browsing their projects.
            PerformanceLog.error("Metal unavailable: \(error.logDetail)")
        } catch {
            PerformanceLog.error("Metal unavailable: \(error)")
        }
        self.renderer = renderer
        self.templatePreviews = TemplatePreviewStore(renderer: renderer, resolver: resolver)
    }

    // MARK: - Flow

    func startFromReference() {
        resetFlow()
        path.append(.referenceImport)
    }

    func startFromScratch() {
        resetFlow()
        path.append(.contentImport)
    }

    /// Begins a project from a saved or built-in style.
    func startFromTemplate(_ recipe: EditRecipe) {
        resetFlow()
        self.recipe = recipe
        // Starters carry no reference text worth reproducing; analysed recipes do.
        fidelity = .closeMatch
        path.append(.contentImport)
    }

    func resetFlow() {
        recipe = nil
        assets = AssetPool()
        content = UserContent()
        assignment = AssetAssignment()
        assetFeatures = [:]
        document = nil
        currentProjectID = UUID()
        projectTitle = nil
        projectCreatedAt = nil
        projectIsFavorite = false
        projectThumbnailPath = nil
        fidelity = .closeMatch
        matchReferenceLook = false
        referenceURL = nil
        musicBeatGrid = nil
        autosaveTask?.cancel()
    }

    // MARK: - Music analysis

    /// Runs the beat detector over the user's music track. Called when a track is added; the
    /// result persists with the project so it never runs twice for the same file.
    func analyzeMusic(_ reference: AssetReference) async {
        guard reference.kind == .audio else { return }
        isAnalyzingMusic = true
        defer { isAnalyzingMusic = false }
        guard let resolved = await resolver.resolve(reference), let asset = resolved.asset else { return }
        do {
            guard let analysis = try await AudioAnalyzer().analyze(asset: asset), !analysis.beats.isEmpty else {
                musicBeatGrid = nil
                return
            }
            musicBeatGrid = BeatGrid(
                bpm: Confident(analysis.bpm, confidence: analysis.bpmConfidence, basis: analysis.bpmBasis),
                beats: analysis.beats,
                downbeats: analysis.downbeats,
                cutsAlignedToBeats: Confident(false, confidence: 1, basis: "user track — cuts snapped on request")
            )
            DiagnosticsLog.shared.info(
                "audio", String(format: "music %@: %.1f BPM, %d beats", reference.displayName, analysis.bpm, analysis.beats.count)
            )
        } catch {
            DiagnosticsLog.shared.warning("audio", "music analysis failed: \(error)")
        }
    }

    /// Moves the timeline's cuts onto the music's beats. One undo step. Nil if nothing moved.
    @discardableResult
    func snapCutsToMusic() -> BeatRetimer.Result? {
        guard let document, let grid = musicBeatGrid else { return nil }
        guard let result = BeatRetimer.retime(document.timeline, toBeats: grid.beats) else { return nil }
        document.perform(result.command)
        DiagnosticsLog.shared.info(
            "audio", String(format: "snapped %d cuts to music, mean shift %.0f ms", result.movedBoundaries, result.meanShift * 1000)
        )
        return result
    }

    /// Builds a timeline with no recipe — the "Start From Scratch" path.
    ///
    /// A default structure is a better answer than a blank canvas: even spacing, alternating
    /// gentle moves, hard cuts. Everything is editable afterwards, which is the point of
    /// starting from scratch.
    func buildScratchTimeline(secondsPerClip: Double = 2.0) {
        let canvas = CanvasSpec.reel1080
        var timeline = Timeline(id: UUID(), canvas: canvas, recipeID: nil)

        timeline.clips = assets.visuals.enumerated().map { index, asset in
            let pushesIn = index.isMultiple(of: 2)
            let tight = NormalizedRect.full.scaled(by: 0.88)
            let isVideo = asset.kind == .video
            return VideoClip(
                assetID: asset.id,
                slotID: "scratch_\(index + 1)",
                start: Double(index) * secondsPerClip,
                duration: isVideo && asset.duration > 0 ? min(asset.duration, secondsPerClip * 2) : secondsPerClip,
                cropStart: pushesIn ? .full : tight,
                cropEnd: pushesIn ? tight : .full,
                easing: .easeInOut,
                transitionIn: index == 0 ? nil : ClipTransition(kind: .cut, duration: 0),
                volume: isVideo ? content.clipAudioVolume : 0
            )
        }
        timeline.relayout()

        // Music and voice, if the content screen collected them.
        if let musicID = content.musicAssetID {
            let trackDuration = assets[musicID]?.duration ?? timeline.duration
            timeline.audio.append(
                AudioClip(
                    assetID: musicID, start: 0,
                    duration: min(timeline.duration, trackDuration > 0 ? trackDuration : timeline.duration),
                    fadeIn: 0.15, fadeOut: min(0.8, timeline.duration * 0.1), role: .music
                )
            )
        }
        if let voiceID = content.voiceoverAssetID {
            let trackDuration = assets[voiceID]?.duration ?? timeline.duration
            timeline.audio.append(
                AudioClip(assetID: voiceID, start: 0, duration: min(timeline.duration, trackDuration),
                          fadeIn: 0.02, fadeOut: 0.05, role: .voice)
            )
        }

        document = TimelineDocument(timeline: timeline)
        exportSettings = ExportSettings.matching(canvas: canvas, shortSide: 1080)
        DiagnosticsLog.shared.info(
            "app", "scratch timeline: \(timeline.clips.count) clips, \(String(format: "%.1fs", timeline.duration))"
        )
    }

    func returnHome() {
        path.removeAll()
    }

    // MARK: - Asset mapping

    /// Extracts Vision features for anything new, then solves the assignment.
    ///
    /// Feature extraction is the expensive half and it is per-asset, so it is cached across
    /// re-arranges and persisted with the project — tapping Shuffle re-solves in milliseconds
    /// instead of re-running Vision.
    func autoArrange(shuffleSeed: Int = 0) async {
        guard let recipe else { return }
        await extractMissingFeatures()
        assignment = AssetMapper().map(
            recipe: recipe,
            assets: assets,
            features: assetFeatures,
            shuffleSeed: shuffleSeed,
            locked: assignment
        )
    }

    func extractMissingFeatures() async {
        let missing = assets.visuals.filter { assetFeatures[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let extractor = AssetFeatureExtractor(resolver: resolver)
        for reference in missing {
            if let features = await extractor.extract(from: reference) {
                assetFeatures[reference.id] = features
            }
        }
    }

    /// Pins or unpins a slot. Pinned slots survive Auto Arrange and Shuffle untouched.
    func setSlotLocked(_ locked: Bool, slotID: String) {
        assignment.setLocked(locked, slotID: slotID)
        if locked { assignment.reasonBySlot[slotID] = "pinned by you" }
    }

    /// Where each asset's subject sits, for the binder's smart crop.
    var subjectRects: [UUID: NormalizedRect] {
        var rects: [UUID: NormalizedRect] = [:]
        for (id, features) in assetFeatures {
            if let rect = features.salientRect { rects[id] = rect }
        }
        return rects
    }

    /// Builds the concrete document from the recipe, assets and words.
    func bindTimeline() {
        guard let recipe else { return }
        let timeline = RecipeBinder().bind(
            recipe: recipe,
            assets: assets,
            assignment: assignment,
            content: content,
            options: RecipeBinder.Options(
                canvas: nil,
                respectBeatGrid: true,
                allowAssetReuse: true,
                applyGrade: matchReferenceLook,
                fidelity: fidelity,
                subjectRects: subjectRects
            )
        )
        if let document {
            document.replace(with: timeline)
        } else {
            document = TimelineDocument(timeline: timeline)
        }
        exportSettings = ExportSettings.matching(canvas: timeline.canvas, shortSide: 1080)
    }

    /// The whole "make it" step: bind, save, open the editor. Replaces the old generate screen,
    /// which animated six stages for work that takes a few milliseconds.
    func createVideoAndEdit() async {
        if recipe != nil {
            bindTimeline()
        } else {
            buildScratchTimeline()
        }
        guard document != nil else {
            present(.renderSetupFailed(detail: "binder produced no timeline"))
            return
        }
        // The reference cut on its beat and the user brought their own track: land the cuts on
        // *their* beats. Undoable, so it is a default rather than a decree.
        if recipe?.audio.suggestedCutStyle == .onBeat, musicBeatGrid != nil {
            snapCutsToMusic()
        }
        await saveProject()
        Haptics.success()
        path.append(.editor)
    }

    // MARK: - Reference audio

    /// Pulls the reference's soundtrack into the pool. Only ever runs on an explicit tap.
    func extractReferenceAudio() async -> AssetReference? {
        guard let referenceURL else {
            present(.audioExtractionFailed(detail: "reference no longer available"))
            return nil
        }
        if let existing = content.referenceAudioAssetID, let asset = assets[existing] { return asset }
        do {
            let name = recipe?.title ?? "Reference"
            let (relative, duration) = try await AudioExtractor.extract(from: referenceURL, displayName: name)
            let reference = AssetReference(
                kind: .audio, origin: .sandboxRelativePath(relative),
                displayName: "\(name) — audio", pixelWidth: 0, pixelHeight: 0, duration: duration
            )
            assets.add(reference)
            return reference
        } catch let error as ReframeError {
            present(error)
        } catch {
            present(.audioExtractionFailed(detail: "\(error)"))
        }
        return nil
    }

    // MARK: - Persistence

    /// Saves whether or not a recipe is involved — a scratch project is still a project.
    func saveProject(thumbnail: CGImage? = nil) async {
        guard let document else { return }
        if let thumbnail { pendingThumbnail = thumbnail }

        if let image = pendingThumbnail, let png = Self.pngData(image) {
            if let name = try? await projectStore.saveThumbnail(png, projectID: currentProjectID) {
                projectThumbnailPath = name
            }
            pendingThumbnail = nil
        }

        let project = Project(
            id: currentProjectID,
            title: projectTitle ?? recipe?.title ?? "Untitled",
            createdAt: projectCreatedAt ?? Date(),
            timeline: document.timeline,
            assets: assets,
            content: content,
            assignment: assignment,
            recipeID: recipe?.id,
            exportSettings: exportSettings,
            assetFeatures: assetFeatures,
            fidelity: fidelity,
            isFavorite: projectIsFavorite,
            thumbnailPath: projectThumbnailPath,
            musicBeatGrid: musicBeatGrid
        )
        if projectCreatedAt == nil { projectCreatedAt = project.createdAt }
        do {
            try await projectStore.save(project, history: document.history)
            if let recipe, recipe.isBuiltIn != true { try await projectStore.save(recipe: recipe) }
            markCleanExit(true)
            await refreshLibrary()
        } catch {
            present(.documentCorrupt(detail: "\(error)"))
        }
    }

    /// Called after every meaningful edit. Coalesces bursts into one write about a second and
    /// a half after the last change — a slider drag does not hit the disk 60 times.
    func noteEdit() {
        markCleanExit(false)
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            await self.saveProject()
        }
    }

    /// Immediate save — app going to background, editor closing.
    func flushAutosave() async {
        autosaveTask?.cancel()
        await saveProject()
    }

    func openProject(id: UUID) async {
        do {
            let project = try await projectStore.load(id: id)
            currentProjectID = project.id
            projectTitle = project.title
            projectCreatedAt = project.createdAt
            projectIsFavorite = project.isFavorite
            projectThumbnailPath = project.thumbnailPath
            assets = project.assets
            content = project.content
            assignment = project.assignment
            assetFeatures = project.assetFeatures
            fidelity = project.fidelity
            exportSettings = project.exportSettings
            musicBeatGrid = project.musicBeatGrid
            referenceURL = nil

            // A project can outlive its recipe — the user may have deleted the style. That is
            // survivable: the timeline is self-contained, and only "re-arrange" needs the recipe.
            if let recipeID = project.recipeID {
                recipe = (try? await projectStore.loadRecipe(id: recipeID))
                    ?? StarterTemplates.all.first { $0.id == recipeID }
            } else {
                recipe = nil
            }

            let document = TimelineDocument(timeline: project.timeline)
            if let history = await projectStore.loadHistory(id: id) {
                document.restore(history: history)
            }
            self.document = document
            recoveryCandidate = nil
            UserDefaults.standard.set(id.uuidString, forKey: Defaults.openProjectID)
            path = [.editor]
        } catch let error as ReframeError {
            present(error)
        } catch {
            present(.documentCorrupt(detail: "\(error)"))
        }
    }

    func refreshLibrary() async {
        do {
            let ids = try await projectStore.listProjectIDs()
            var summaries: [ProjectSummary] = []
            for id in ids {
                guard let project = try? await projectStore.load(id: id) else { continue }
                var thumbnail: URL?
                if let name = project.thumbnailPath {
                    thumbnail = await projectStore.thumbnailURL(projectID: id, name: name)
                }
                summaries.append(
                    ProjectSummary(
                        id: project.id,
                        title: project.title,
                        createdAt: project.createdAt,
                        modifiedAt: project.modifiedAt,
                        sceneCount: project.timeline.clips.count,
                        duration: project.timeline.duration,
                        isFavorite: project.isFavorite,
                        thumbnailURL: thumbnail,
                        canvasAspect: project.timeline.canvas.aspectRatio
                    )
                )
            }
            recentProjects = summaries.sorted { $0.modifiedAt > $1.modifiedAt }
            savedRecipes = (try? await projectStore.listRecipes()) ?? []
        } catch {
            recentProjects = []
        }
    }

    /// Saved styles first (newest first), then the built-in starters.
    var templates: [EditRecipe] {
        savedRecipes + StarterTemplates.all
    }

    // MARK: - Project operations

    func deleteProject(id: UUID) async {
        try? await projectStore.delete(id: id)
        if id == currentProjectID { document = nil }
        await refreshLibrary()
    }

    func renameProject(id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if id == currentProjectID {
            projectTitle = trimmed
            if document != nil { await saveProject(); return }
        }
        guard var project = try? await projectStore.load(id: id) else { return }
        project.title = trimmed
        try? await projectStore.save(project)
        await refreshLibrary()
    }

    func toggleFavorite(id: UUID) async {
        if id == currentProjectID {
            projectIsFavorite.toggle()
            if document != nil { await saveProject(); return }
        }
        guard var project = try? await projectStore.load(id: id) else { return }
        project.isFavorite.toggle()
        try? await projectStore.save(project)
        await refreshLibrary()
    }

    func duplicateProject(id: UUID) async {
        _ = try? await projectStore.duplicate(id: id)
        await refreshLibrary()
    }

    // MARK: - Templates

    func deleteRecipe(id: UUID) async {
        try? await projectStore.deleteRecipe(id: id)
        templatePreviews.invalidate(recipeID: id)
        await refreshLibrary()
    }

    func renameRecipe(id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var recipe = try? await projectStore.loadRecipe(id: id) else { return }
        recipe.title = trimmed
        try? await projectStore.save(recipe: recipe)
        if self.recipe?.id == id { self.recipe?.title = trimmed }
        await refreshLibrary()
    }

    func duplicateRecipe(_ recipe: EditRecipe) async {
        var copy = recipe
        copy.id = UUID()
        copy.title = recipe.title.hasSuffix(" copy") ? recipe.title : "\(recipe.title) copy"
        copy.createdAt = Date()
        copy.isBuiltIn = false
        try? await projectStore.save(recipe: copy)
        await refreshLibrary()
    }

    /// The current recipe saved as a reusable style (a starter becomes "yours" on save).
    func saveCurrentAsTemplate(title: String) async {
        guard var recipe else { return }
        if recipe.isBuiltIn == true {
            recipe.id = UUID()
            recipe.isBuiltIn = false
        }
        recipe.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? recipe.title : title
        recipe.createdAt = Date()
        try? await projectStore.save(recipe: recipe)
        self.recipe = recipe
        await refreshLibrary()
    }

    func exportRecipeFile(_ recipe: EditRecipe) async -> URL? {
        try? await projectStore.exportRecipe(recipe)
    }

    func importRecipeFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let recipe = try await projectStore.importRecipe(from: url)
            await refreshLibrary()
            DiagnosticsLog.shared.info("templates", "imported style \(recipe.title)")
            Haptics.success()
        } catch let error as ReframeError {
            present(error)
        } catch {
            present(.documentCorrupt(detail: "\(error)"))
        }
    }

    // MARK: - Opening files from other apps

    /// "Share -> Reframe" and "Open in Reframe" arrive here. Videos become a reference; a
    /// `.reframestyle` file becomes a saved style. Anything else is explained, not swallowed.
    func handleIncomingURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "reframestyle" || ext == "json" {
            Task { await importRecipeFile(url) }
            return
        }
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .movie) || type.conforms(to: .video) else {
            present(.sharedURLNotAFile(host: url.host))
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            resetFlow()
            path = [.referenceImport, .analysis(destination)]
        } catch {
            present(.fileAccessDenied(name: url.lastPathComponent))
        }
    }

    // MARK: - Recovery

    /// On launch: was a project open when the app last stopped, without a clean save?
    func checkForRecovery() async {
        guard let idString = UserDefaults.standard.string(forKey: Defaults.openProjectID),
              let id = UUID(uuidString: idString),
              UserDefaults.standard.object(forKey: Defaults.cleanExit) != nil,
              UserDefaults.standard.bool(forKey: Defaults.cleanExit) == false else { return }
        await refreshLibrary()
        recoveryCandidate = recentProjects.first { $0.id == id }
        if recoveryCandidate == nil { clearRecoveryMarker() }
    }

    func markEditorOpen() {
        UserDefaults.standard.set(currentProjectID.uuidString, forKey: Defaults.openProjectID)
        markCleanExit(true)
    }

    private func markCleanExit(_ clean: Bool) {
        UserDefaults.standard.set(clean, forKey: Defaults.cleanExit)
    }

    func clearRecoveryMarker() {
        UserDefaults.standard.removeObject(forKey: Defaults.openProjectID)
        UserDefaults.standard.set(true, forKey: Defaults.cleanExit)
        recoveryCandidate = nil
    }

    // MARK: - Errors

    func present(_ error: ReframeError) {
        // Recorded even when silent: a cancellation that the user never sees is still the
        // reason a later step did nothing, and that is exactly the gap a diagnostic log fills.
        DiagnosticsLog.shared.failure("app", "\(error.presentation.title) — \(error.logDetail)")
        guard !error.presentation.isSilent else { return }
        PerformanceLog.warn(error.logDetail)
        Haptics.warning()
        presentedError = ErrorWrapper(error: error)
    }

    func recover(from action: ReframeError.RecoveryAction) {
        presentedError = nil
        switch action {
        case .openSettings, .manageStorage:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .retryAtLowerQuality:
            let canvas = document?.timeline.canvas ?? .reel1080
            exportSettings = ExportSettings.matching(canvas: canvas, shortSide: 720, preferHEVC: exportSettings.preferHEVC)
            if path.last != .export { path.append(.export) }
        case .chooseDifferentFile:
            path = [.referenceImport]
        case .addMoreAssets:
            if path.last != .contentImport { path.append(.contentImport) }
        case .retry:
            // There is no generic retry — what to retry depends on where you are — so send the
            // user back one step, which is the screen the failed action was started from.
            if path.count > 1 { path.removeLast() }
        case .dismiss, .showScreenRecordingHelp, .waitForCooldown:
            break
        }
    }

    // MARK: - Memory

    func handleMemoryPressure() {
        PerformanceLog.warn("memory warning at \(PerformanceLog.memoryFootprintMB()) MB")
        renderer?.evictCaches()
        templatePreviews.handleMemoryPressure()
        Task { await resolver.evictCache() }
    }

    // MARK: - Helpers

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
