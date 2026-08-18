import ReframeKit
import SwiftUI

@main
struct ReframeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reframe.appearance") private var appearance = AppearanceSetting.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(AppearanceSetting(rawValue: appearance)?.colorScheme)
                .task {
                    Haptics.prepare()
                    await model.checkForRecovery()
                }
                // Caches are regenerable; under pressure they go immediately rather than after
                // the allocator has already lost.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    model.handleMemoryPressure()
                }
                // "Share -> Reframe" / "Open in Reframe".
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Going to the background is the moment a crash or a jetsam is most likely to
            // follow. Whatever is open gets written now, not on the next debounce tick.
            if phase == .background || phase == .inactive, model.document != nil {
                Task { await model.flushAutosave() }
            }
        }
    }
}

/// System / light / dark. Video editing is designed dark-first, but the choice is the user's.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .referenceImport:
                        ReferenceImportView()
                    case .analysis(let url):
                        AnalysisView(sourceURL: url)
                    case .recipeSummary:
                        RecipeSummaryView()
                    case .contentImport:
                        ContentImportView()
                    case .mapping:
                        MappingView()
                    case .editor:
                        EditorView()
                    case .export:
                        ExportView()
                    case .templates:
                        TemplateLibraryView()
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .tint(Theme.Palette.accent)
        // Navigation breadcrumbs. The diagnostics log is how bugs get reported from a phone to a
        // machine with no debugger; without "which screen were they on" most UI reports are
        // unreproducible.
        .onChange(of: model.path) { _, path in
            DiagnosticsLog.shared.info("nav", path.isEmpty ? "home" : path.map(\.logName).joined(separator: " › "))
        }
        .sheet(item: $model.presentedError) { wrapper in
            ErrorSheet(
                error: wrapper.error,
                onRecover: { model.recover(from: $0) },
                onDismiss: { model.presentedError = nil }
            )
        }
        .alert(
            "Recover your last project?",
            isPresented: Binding(
                get: { model.recoveryCandidate != nil },
                set: { if !$0 { model.clearRecoveryMarker() } }
            ),
            presenting: model.recoveryCandidate
        ) { candidate in
            Button("Recover") {
                Task { await model.openProject(id: candidate.id) }
            }
            Button("Not now", role: .cancel) {
                model.clearRecoveryMarker()
            }
        } message: { candidate in
            Text("“\(candidate.title)” was open when Reframe last closed. Everything up to the last autosave is there.")
        }
    }
}

enum Route: Hashable {
    case referenceImport
    case analysis(URL)
    case recipeSummary
    case contentImport
    case mapping
    case editor
    case export
    case templates
    case settings

    /// Short, path-free name for the diagnostics log.
    var logName: String {
        switch self {
        case .referenceImport: return "reference"
        case .analysis: return "analysis"
        case .recipeSummary: return "summary"
        case .contentImport: return "content"
        case .mapping: return "mapping"
        case .editor: return "editor"
        case .export: return "export"
        case .templates: return "templates"
        case .settings: return "settings"
        }
    }
}

/// `ReframeError` is an enum without `Identifiable`; this wraps it for `.sheet(item:)`.
struct ErrorWrapper: Identifiable, Equatable {
    let id = UUID()
    let error: ReframeError
}
