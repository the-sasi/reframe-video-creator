import Observation
import Photos
import ReframeKit
import SwiftUI
import UIKit

/// App-wide state and service wiring.
///
/// Holds the in-flight project — recipe, assets, words, assignment — because the primary flow
/// spans six screens and the work-in-progress belongs to the flow rather than to any one of
/// them. The editable document itself lives in `TimelineDocument`, which owns the undo stack.
@MainActor
@Observable
final class AppModel {

    // MARK: Navigation

    var path: [Route] = []
    var presentedError: ErrorWrapper?

    // MARK: Services

    let projectStore = ProjectStore()
    let resolver = AssetResolver()
    let intelligence = IntelligenceService()
    private(set) var renderer: MetalRenderer?

    // MARK: In-flight project

    var recipe: EditRecipe?
    var assets = AssetPool()
    var content = UserContent()
    var assignment = AssetAssignment()
    var assetFeatures: [UUID: AssetFeatures] = [:]
    var document: TimelineDocument?
    var exportSettings: ExportSettings = .default

    /// Whether to apply the reference's inferred colour to your photos.
    ///
    /// Off by default and deliberately so: an automatic grade applied to somebody else's
    /// photographs reads as a bug rather than a style when it is wrong. But the analyser
    /// measures it either way, so leaving it permanently discarded — which is what the code did
    /// before — threw away work for no reason.
    var matchReferenceLook = false

    /// Identity of the project being edited.
    ///
    /// Deliberately *not* derived from `timeline.id`. `RecipeBinder` generates that
    /// deterministically from the reference's fingerprint, so two projects made from the same
    /// reference would collide and the second would silently overwrite the first. Determinism
    /// is right for recipe content and wrong for project identity.
    var currentProjectID = UUID()

    /// Recent projects for the Continue strip.
    var recentProjects: [ProjectSummary] = []
    var savedRecipes: [EditRecipe] = []

    struct ProjectSummary: Identifiable, Hashable {
        let id: UUID
        let title: String
        let modifiedAt: Date
        let sceneCount: Int
    }

    init() {
        do {
            renderer = try MetalRenderer()
        } catch let error as ReframeError {
            // Surfaced on first use rather than at launch — a Metal failure on the Simulator
            // should not stop the user browsing their projects.
            PerformanceLog.error("Metal unavailable: \(error.logDetail)")
        } catch {
            PerformanceLog.error("Metal unavailable: \(error)")
        }
    }

    // MARK: - Flow

    func startFromReference() {
        resetFlow()
        path.append(.referenceImport)
    }

    func resetFlow() {
        recipe = nil
        assets = AssetPool()
        content = UserContent()
        assignment = AssetAssignment()
        assetFeatures = [:]
        document = nil
        currentProjectID = UUID()
    }

    /// Builds a timeline with no recipe — the "Start From Scratch" path.
    ///
    /// Previously this route navigated to the content screen and then dead-ended, because both
    /// `autoArrange()` and `bindTimeline()` bail out when `recipe` is nil. A default structure
    /// is a better answer than a broken menu item: even spacing, alternating gentle moves, hard
    /// cuts. Everything is editable afterwards, which is the point of starting from scratch.
    func buildScratchTimeline(secondsPerClip: Double = 2.0) {
        let canvas = CanvasSpec.reel1080
        var timeline = Timeline(id: UUID(), canvas: canvas, recipeID: nil)

        timeline.clips = assets.visuals.enumerated().map { index, asset in
            // Alternate push-in and pull-out so a run of stills does not read as a slideshow.
            let pushesIn = index.isMultiple(of: 2)
            let tight = NormalizedRect.full.scaled(by: 0.88)
            return VideoClip(
                assetID: asset.id,
                slotID: "scratch_\(index + 1)",
                start: Double(index) * secondsPerClip,
                duration: secondsPerClip,
                cropStart: pushesIn ? .full : tight,
                cropEnd: pushesIn ? tight : .full,
                easing: .easeInOut,
                transitionIn: index == 0 ? nil : Transition(kind: .cut, duration: 0),
                volume: 0
            )
        }
        timeline.relayout()

        if let musicID = content.musicAssetID {
            timeline.audio = [
                AudioClip(
                    assetID: musicID, start: 0, duration: timeline.duration,
                    fadeIn: 0.15, fadeOut: min(0.8, timeline.duration * 0.1)
                )
            ]
        }

        document = TimelineDocument(timeline: timeline)
        exportSettings = ExportSettings(
            width: canvas.width, height: canvas.height, fps: canvas.fps, preferHEVC: true
        )
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
    /// re-arranges — tapping Shuffle re-solves in milliseconds instead of re-running Vision.
    func autoArrange(shuffleSeed: Int = 0) async {
        guard let recipe else { return }

        let missing = assets.visuals.filter { assetFeatures[$0.id] == nil }
        if !missing.isEmpty {
            let extractor = AssetFeatureExtractor(resolver: resolver)
            for reference in missing {
                if let features = await extractor.extract(from: reference) {
                    assetFeatures[reference.id] = features
                }
            }
        }

        assignment = AssetMapper().map(
            recipe: recipe,
            assets: assets,
            features: assetFeatures,
            shuffleSeed: shuffleSeed
        )
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
                applyGrade: matchReferenceLook
            )
        )
        if let document {
            document.replace(with: timeline)
        } else {
            document = TimelineDocument(timeline: timeline)
        }
        exportSettings = ExportSettings(
            width: timeline.canvas.width,
            height: timeline.canvas.height,
            fps: timeline.canvas.fps,
            preferHEVC: true
        )
    }

    // MARK: - Persistence

    /// Saves whether or not a recipe is involved — a scratch project is still a project.
    func saveProject() async {
        guard let document else { return }
        let project = Project(
            id: currentProjectID,
            title: recipe?.title ?? "Untitled",
            timeline: document.timeline,
            assets: assets,
            content: content,
            assignment: assignment,
            recipeID: recipe?.id,
            exportSettings: exportSettings
        )
        do {
            try await projectStore.save(project, history: document.history)
            if let recipe { try await projectStore.save(recipe: recipe) }
            await refreshLibrary()
        } catch {
            present(.documentCorrupt(detail: "\(error)"))
        }
    }

    func openProject(id: UUID) async {
        do {
            let project = try await projectStore.load(id: id)
            currentProjectID = project.id
            assets = project.assets
            content = project.content
            assignment = project.assignment
            exportSettings = project.exportSettings

            // A project can outlive its recipe — the user may have deleted the style. That is
            // survivable: the timeline is self-contained, and only "re-arrange" needs the recipe.
            if let recipeID = project.recipeID {
                recipe = try? await projectStore.loadRecipe(id: recipeID)
            } else {
                recipe = nil
            }

            let document = TimelineDocument(timeline: project.timeline)
            if let history = await projectStore.loadHistory(id: id) {
                document.restore(history: history)
            }
            self.document = document
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
                summaries.append(
                    ProjectSummary(
                        id: project.id,
                        title: project.title,
                        modifiedAt: project.modifiedAt,
                        sceneCount: project.timeline.clips.count
                    )
                )
            }
            recentProjects = summaries.sorted { $0.modifiedAt > $1.modifiedAt }
            savedRecipes = (try? await projectStore.listRecipes()) ?? []
        } catch {
            recentProjects = []
        }
    }

    func deleteProject(id: UUID) async {
        try? await projectStore.delete(id: id)
        await refreshLibrary()
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
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .retryAtLowerQuality:
            exportSettings = .hd720
            if path.last != .export { path.append(.export) }
        case .chooseDifferentFile:
            path = [.referenceImport]
        case .addMoreAssets:
            if path.last != .contentImport { path.append(.contentImport) }
        case .manageStorage:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .dismiss, .retry, .showScreenRecordingHelp, .waitForCooldown:
            break
        }
    }

    // MARK: - Memory

    func handleMemoryPressure() {
        PerformanceLog.warn("memory warning at \(PerformanceLog.memoryFootprintMB()) MB")
        renderer?.evictCaches()
        Task { await resolver.evictCache() }
    }
}
