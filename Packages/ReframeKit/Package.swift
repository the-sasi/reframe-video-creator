// swift-tools-version: 6.2
// `.iOS(.v26)` below was introduced in PackageDescription 6.2 — declaring 6.0 here makes the
// manifest fail to compile before SPM gets as far as looking at any source.
import PackageDescription

// The engine. Deliberately links no UI framework, so `swift test` exercises the whole
// thing on a Mac with no simulator and no device.
//
// Module dependencies are one-directional and enforced here rather than by convention:
// Analysis has no way to reach Rendering, and Rendering has never heard of a reference video.

let package = Package(
    name: "ReframeKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ReframeKit", targets: ["ReframeKit"]),
    ],
    targets: [
        // Schema, timeline document, undoable commands, binding. Zero dependencies —
        // not even AVFoundation. This is pure data.
        .target(name: "RecipeCore"),

        // Everything that touches a file or an AVAsset.
        .target(name: "MediaIO", dependencies: ["RecipeCore"]),

        // Reference video -> ReferenceAnalysis -> EditRecipe.
        .target(name: "Analysis", dependencies: ["RecipeCore", "MediaIO"]),

        // User assets -> features -> optimal slot assignment.
        .target(name: "Mapping", dependencies: ["RecipeCore", "MediaIO"]),

        // Timeline -> RenderPlan -> pixels -> file.
        //
        // No `resources:` here on purpose. Shaders.metal lives in the app target so Xcode
        // compiles and validates it at build time; declaring a Resources directory that does
        // not exist makes SPM refuse to load the manifest at all.
        .target(name: "Rendering", dependencies: ["RecipeCore", "MediaIO"]),

        // Optional, absent-tolerant. Heuristic implementation is the default.
        .target(name: "Intelligence", dependencies: ["RecipeCore"]),

        // Umbrella re-export so the app imports one module.
        .target(
            name: "ReframeKit",
            dependencies: ["RecipeCore", "MediaIO", "Analysis", "Mapping", "Rendering", "Intelligence"]
        ),

        .testTarget(
            name: "ReframeKitTests",
            dependencies: ["ReframeKit"]
        ),
    ]
)
