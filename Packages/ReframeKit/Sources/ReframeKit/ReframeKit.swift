/// Umbrella module, so the app imports one thing.
///
/// The submodule split is not cosmetic — it is what makes "Analysis has no way to reach
/// Rendering" a compiler-enforced fact rather than a convention. The umbrella re-exports them
/// for convenience without letting them see each other.
@_exported import Analysis
@_exported import Intelligence
@_exported import Mapping
@_exported import MediaIO
@_exported import RecipeCore
@_exported import Rendering

public enum ReframeKit {
    public static let version = "1.0.0"
    public static let schemaVersion = RecipeSchema.current
}

/// Unambiguous spelling of `RecipeCore.TextAlignment`.
///
/// SwiftUI declares its own `TextAlignment`, so the bare name is ambiguous in any view file —
/// the same collision Vision's `NormalizedRect` causes in the analysis modules. The app target
/// links the umbrella product rather than the sub-modules, so it cannot simply qualify with
/// `RecipeCore.`; exporting the alias from here gives it a name that always resolves.
public typealias SlotTextAlignment = RecipeCore.TextAlignment

/// Unambiguous spelling of `RecipeCore.Transition`. SwiftUI declares a `Transition` protocol,
/// so the bare name is ambiguous in type position inside the app target.
public typealias ClipTransition = RecipeCore.Transition
