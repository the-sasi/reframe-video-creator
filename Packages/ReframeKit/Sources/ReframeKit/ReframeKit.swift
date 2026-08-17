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
