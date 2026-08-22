import Foundation

/// Every screen in the application, as a state rather than a view.
///
/// Lives in `RecipeCore` — with no UI dependency — so the transition policy below can be
/// exercised by `swift test` in CI. Navigation was previously the least-tested part of the app
/// and the source of its worst bug; testable policy is the fix for that class of problem, not
/// just for the one symptom.
public enum AppRoute: Hashable, Sendable {
    case referenceImport
    case analysis(URL)
    case recipeSummary
    case contentImport
    case mapping
    case editor
    case export
    case templates
    case settings

    /// A step you pass *through*, not one you return to.
    ///
    /// This is the specific fix for the analysis dead end. Analysis is work in progress: once
    /// it has produced a recipe, going "back" to it is meaningless — the work is done, the
    /// screen has nothing to offer, and re-running it would discard the result. Marking it
    /// transient removes it from the path the moment it completes, so it cannot be a back
    /// destination at all.
    public var isTransient: Bool {
        switch self {
        case .analysis, .mapping: return true
        default: return false
        }
    }

    /// Where "back" goes from here. Never "whatever happens to be underneath on the stack".
    ///
    /// `nil` means home.
    public var backDestination: AppRoute? {
        switch self {
        case .referenceImport, .templates, .settings, .contentImport:
            return nil
        case .analysis:
            // Cancelling analysis returns to picking a different reference, which is the only
            // useful thing to do next.
            return .referenceImport
        case .recipeSummary:
            // Deliberately *not* `.analysis`. That is the dead end.
            return nil
        case .mapping:
            return .contentImport
        case .editor:
            // The project is saved; home is a safe landing.
            return nil
        case .export:
            return .editor
        }
    }

    /// Short, path-free name for the diagnostics log.
    public var logName: String {
        switch self {
        case .referenceImport: return "reference"
        case .analysis: return "analysis"
        case .recipeSummary: return "summary"
        case .contentImport: return "content"
        case .mapping: return "arrange"
        case .editor: return "editor"
        case .export: return "export"
        case .templates: return "templates"
        case .settings: return "settings"
        }
    }
}

/// The single authority on navigation transitions.
///
/// Pure functions over a path. Previously the path was mutated from twelve sites across eight
/// files, each screen inventing its own assumptions about what came before — so no one place
/// described the flow and no screen could be reasoned about alone.
public enum NavigationPolicy {

    /// Moves forward, dropping any transient state we are leaving behind.
    ///
    /// Advancing from analysis to the summary removes analysis from the path entirely, so the
    /// back button from the summary skips straight past it.
    public static func advance(_ path: [AppRoute], to route: AppRoute) -> [AppRoute] {
        var result = path
        while let last = result.last, last.isTransient {
            result.removeLast()
        }
        // Re-entering the state you are already on is a no-op, not a duplicate push.
        if result.last == route { return result }
        result.append(route)
        return result
    }

    /// Moves back, skipping any transient state it would otherwise land on.
    public static func back(_ path: [AppRoute]) -> [AppRoute] {
        guard let current = path.last else { return [] }

        if let destination = current.backDestination {
            // Rewind to that destination if it is already behind us; otherwise rebuild a
            // minimal path to it, so back is well-defined even from a restored or deep-linked
            // path that never visited it.
            if let index = path.lastIndex(of: destination) {
                return Array(path.prefix(through: index))
            }
            return [destination]
        }

        // No declared destination means home.
        return []
    }

    /// Abandons the current task. Same as `back` today, kept separate because cancelling and
    /// going back are different intents and will diverge (cancel discards work).
    public static func cancel(_ path: [AppRoute]) -> [AppRoute] {
        back(path)
    }

    /// Every route reachable from a path, for assertions and for deciding whether a screen has
    /// any exit at all.
    public static func hasExit(from path: [AppRoute]) -> Bool {
        guard let current = path.last else { return true }  // home always "exits"
        return current.backDestination != nil || path.count >= 1
    }

    /// True if any transient state survives in a position it could be navigated back onto.
    /// Used by the regression test — the invariant the dead-end bug violated.
    public static func containsStrandedTransient(_ path: [AppRoute]) -> Bool {
        // A transient state is legitimate only as the *current* screen.
        path.dropLast().contains { $0.isTransient }
    }
}
