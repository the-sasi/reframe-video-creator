import ReframeKit
import SwiftUI

@main
struct ReframeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { Haptics.prepare() }
                // Caches are regenerable; under pressure they go immediately rather than after
                // the allocator has already lost.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    model.handleMemoryPressure()
                }
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
                    case .generate:
                        GenerateView()
                    case .editor:
                        EditorView()
                    case .export:
                        ExportView()
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .tint(Theme.Palette.accent)
        .sheet(item: $model.presentedError) { wrapper in
            ErrorSheet(
                error: wrapper.error,
                onRecover: { model.recover(from: $0) },
                onDismiss: { model.presentedError = nil }
            )
        }
    }
}

enum Route: Hashable {
    case referenceImport
    case analysis(URL)
    case recipeSummary
    case contentImport
    case mapping
    case generate
    case editor
    case export
    case settings
}

/// `ReframeError` is an enum without `Identifiable`; this wraps it for `.sheet(item:)`.
struct ErrorWrapper: Identifiable, Equatable {
    let id = UUID()
    let error: ReframeError
}
