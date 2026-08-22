import Foundation
import Testing
@testable import RecipeCore

/// Navigation had zero test coverage and produced the worst bug in the app. These are the
/// invariants that bug violated.
@Suite("Navigation")
struct NavigationTests {

    private let video = URL(fileURLWithPath: "/tmp/reference.mov")

    // MARK: - The reported bug

    @Test("RF-001: analysis is never a back destination once it has completed")
    func analysisIsNeverABackDestination() {
        // Home → reference → analysis → summary, which is the exact reported sequence.
        var path: [AppRoute] = []
        path = NavigationPolicy.advance(path, to: .referenceImport)
        path = NavigationPolicy.advance(path, to: .analysis(video))
        path = NavigationPolicy.advance(path, to: .recipeSummary)

        // Analysis must have been dropped when it completed.
        #expect(!path.contains(.analysis(video)), "analysis survived into \(path)")

        // Backing out of the summary must not land on it either.
        let back = NavigationPolicy.back(path)
        #expect(back.last != .analysis(video))
        #expect(back.isEmpty, "back from the summary should reach home, got \(back)")
    }

    @Test("A transient state is never stranded beneath the current screen")
    func noStrandedTransients() {
        var path: [AppRoute] = []
        for route in [AppRoute.referenceImport, .analysis(video), .recipeSummary, .contentImport, .mapping, .editor] {
            path = NavigationPolicy.advance(path, to: route)
            #expect(
                !NavigationPolicy.containsStrandedTransient(path),
                "stranded transient after advancing to \(route.logName): \(path.map(\.logName))"
            )
        }
    }

    // MARK: - Universal invariants

    @Test("Every route declares a back destination that is not itself")
    func everyRouteHasAnExit() {
        let all: [AppRoute] = [
            .referenceImport, .analysis(video), .recipeSummary, .contentImport,
            .mapping, .editor, .export, .templates, .settings,
        ]
        for route in all {
            let path = [route]
            let back = NavigationPolicy.back(path)
            #expect(back != path, "\(route.logName) backs onto itself")
            #expect(back.last != route, "\(route.logName) cannot be escaped")
        }
    }

    @Test("Back always shortens the path or reaches home")
    func backMakesProgress() {
        let paths: [[AppRoute]] = [
            [.referenceImport],
            [.referenceImport, .analysis(video)],
            [.recipeSummary],
            [.contentImport, .mapping],
            [.editor, .export],
            [.templates],
            [.settings],
        ]
        for path in paths {
            let back = NavigationPolicy.back(path)
            #expect(
                back.count < path.count || back.isEmpty,
                "back from \(path.map(\.logName)) produced \(back.map(\.logName))"
            )
        }
    }

    @Test("Advancing to the state you are already on does not duplicate it")
    func advanceIsIdempotent() {
        var path: [AppRoute] = [.contentImport]
        path = NavigationPolicy.advance(path, to: .contentImport)
        #expect(path == [.contentImport])
    }

    @Test("Back is well defined from a path that never visited the destination")
    func backFromDeepLink() {
        // Share-sheet entry can construct a path directly; back must still work.
        let path: [AppRoute] = [.export]
        #expect(NavigationPolicy.back(path) == [.editor])
    }

    @Test("Export backs to the editor, not out of the project")
    func exportBacksToEditor() {
        let path: [AppRoute] = [.contentImport, .editor, .export]
        #expect(NavigationPolicy.back(path).last == .editor)
    }

    @Test("Arrange backs to content selection")
    func mappingBacksToContent() {
        let path: [AppRoute] = [.contentImport, .mapping]
        #expect(NavigationPolicy.back(path).last == .contentImport)
    }

    // MARK: - Architecture guard

    /// The dead end existed because twelve sites across eight files mutated the path. This
    /// fails the build if a feature view starts doing that again.
    @Test("RF-002: no feature view mutates the navigation path directly")
    func routerIsTheOnlyMutator() throws {
        let features = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReframeKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ReframeKit
            .deletingLastPathComponent()   // Packages
            .appendingPathComponent("Reframe/Features")

        guard FileManager.default.fileExists(atPath: features.path) else { return }

        let forbidden = ["path.append", "path.removeLast", "path.removeAll", "path = ["]
        var offenders: [String] = []

        let enumerator = FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for needle in forbidden where source.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }

        #expect(offenders.isEmpty, "navigation mutated outside the router: \(offenders)")
    }
}
