import Foundation

/// Named looks, built from the same four grade scalars the renderer already applies plus the
/// two effect scalars.
///
/// Deliberately not LUT-based. A LUT would mean shipping texture assets and a third sampler for
/// a difference nobody would notice at these strengths, and it would break the property that a
/// grade is four numbers you can read in the project JSON.
public struct FilterPreset: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var grade: ColorGrade
    public var vignette: Double
    public var grain: Double

    public init(
        id: String, name: String, grade: ColorGrade,
        vignette: Double = 0, grain: Double = 0
    ) {
        self.id = id
        self.name = name
        self.grade = grade
        self.vignette = vignette
        self.grain = grain
    }

    public static let none = FilterPreset(
        id: "none", name: "None", grade: .neutral
    )

    /// Ordered by how often they are actually wanted. Strengths are deliberately restrained —
    /// these are applied to somebody's own photographs, and an aggressive automatic look reads
    /// as a bug rather than a style.
    public static let all: [FilterPreset] = [
        .none,
        FilterPreset(
            id: "warm", name: "Warm",
            grade: ColorGrade(exposure: 0.04, contrast: 1.05, saturation: 1.10, temperature: 0.28)
        ),
        FilterPreset(
            id: "cool", name: "Cool",
            grade: ColorGrade(exposure: 0.02, contrast: 1.06, saturation: 1.02, temperature: -0.26)
        ),
        FilterPreset(
            id: "vivid", name: "Vivid",
            grade: ColorGrade(exposure: 0.03, contrast: 1.18, saturation: 1.35, temperature: 0.05)
        ),
        FilterPreset(
            id: "soft", name: "Soft",
            grade: ColorGrade(exposure: 0.08, contrast: 0.90, saturation: 0.94, temperature: 0.08),
            vignette: 0.15
        ),
        FilterPreset(
            id: "film", name: "Film",
            grade: ColorGrade(exposure: 0.02, contrast: 1.12, saturation: 0.88, temperature: 0.14),
            vignette: 0.28, grain: 0.35
        ),
        FilterPreset(
            id: "mono", name: "Mono",
            grade: ColorGrade(exposure: 0.03, contrast: 1.22, saturation: 0.0, temperature: 0),
            vignette: 0.22, grain: 0.20
        ),
        FilterPreset(
            id: "fade", name: "Fade",
            grade: ColorGrade(exposure: 0.10, contrast: 0.82, saturation: 0.82, temperature: 0.06),
            vignette: 0.10
        ),
        FilterPreset(
            id: "noir", name: "Noir",
            grade: ColorGrade(exposure: -0.06, contrast: 1.40, saturation: 0.0, temperature: -0.05),
            vignette: 0.45, grain: 0.30
        ),
        FilterPreset(
            id: "bloom", name: "Bloom",
            grade: ColorGrade(exposure: 0.12, contrast: 0.95, saturation: 1.18, temperature: 0.18),
            vignette: 0.08
        ),
    ]

    /// Best match for an arbitrary grade, so the UI can show which preset a clip is currently
    /// on after a project reload — or "Custom" when a manual tweak has moved it off one.
    public static func matching(grade: ColorGrade, vignette: Double, grain: Double) -> FilterPreset? {
        all.first { preset in
            abs(preset.grade.exposure - grade.exposure) < 0.01
                && abs(preset.grade.contrast - grade.contrast) < 0.01
                && abs(preset.grade.saturation - grade.saturation) < 0.01
                && abs(preset.grade.temperature - grade.temperature) < 0.01
                && abs(preset.vignette - vignette) < 0.01
                && abs(preset.grain - grain) < 0.01
        }
    }
}
