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
            options: RecipeBinder.Options(canvas: nil, respectBeatGrid: true, allowAssetReuse: true)
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

    func saveProject() async {
        guard let document, let recipe else { return }
        let project = Project(
            id: document.timeline.id,
            title: recipe.title,
            timeline: document.timeline,
            assets: assets,
            content: content,
            assignment: assignment,
            recipeID: recipe.id,
            exportSettings: exportSettings
        )
        do {
            try await projectStore.save(project, history: document.history)
            try await projectStore.save(recipe: recipe)
            await refreshLibrary()
        } catch {
            present(.documentCorrupt(detail: "\(error)"))
        }
    }

    func openProject(id: UUID) async {
        do {
            let project = try await projectStore.load(id: id)
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
