import Foundation
import RecipeCore

/// Bridges `TransitionKind` to the shader, and describes the catalogue for the editor's picker.
public enum TransitionLibrary {

    /// Must match the `switch (uniforms.kind)` cases in Shaders.metal.
    public static func shaderKind(for kind: TransitionKind) -> Int32 {
        switch kind {
        case .cut, .dissolve: return 0
        case .fadeToBlack: return 1
        case .fadeToWhite: return 2
        case .slide: return 3
        case .push: return 4
        case .zoomIn: return 5
        case .zoomOut: return 6
        case .whip: return 7
        case .blur: return 8
        }
    }

    public static func shaderDirection(for direction: TransitionDirection?) -> Int32 {
        switch direction {
        case .left: return 0
        case .right: return 1
        case .up: return 2
        case .down: return 3
        case nil: return 1
        }
    }

    /// Sensible duration when the user picks a transition by hand, rather than one being
    /// measured from a reference.
    public static func defaultDuration(for kind: TransitionKind) -> Double {
        switch kind {
        case .cut: return 0
        case .dissolve: return 0.30
        case .fadeToBlack, .fadeToWhite: return 0.45
        case .slide, .push: return 0.35
        case .zoomIn, .zoomOut: return 0.40
        case .whip: return 0.22
        case .blur: return 0.35
        }
    }

    /// Offered in the editor. Ordered by how often they are actually wanted, not alphabetically
    /// — the first three cover the overwhelming majority of real edits.
    public static let catalogue: [TransitionKind] = [
        .cut, .dissolve, .fadeToBlack,
        .push, .slide, .zoomIn, .zoomOut, .whip, .blur, .fadeToWhite,
    ]

    public static func requiresDirection(_ kind: TransitionKind) -> Bool {
        kind.needsDirection
    }
}
