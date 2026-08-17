import SwiftUI

/// Design tokens.
///
/// Native-feeling rather than branded-heavy: system semantic colours, one accent used only for
/// the primary action on each screen, and nothing decorative. Dark mode is the primary design —
/// video editing happens in the dark — with light mode fully supported.
enum Theme {

    // MARK: - Colour

    enum Palette {
        /// Warm rose, matching the sample use case. Used for the single primary action per
        /// screen and nothing else. An accent that appears everywhere stops meaning anything.
        static let accent = Color(red: 0.91, green: 0.44, blue: 0.53)
        static let accentSoft = Color(red: 0.91, green: 0.44, blue: 0.53).opacity(0.14)

        static let background = Color(.systemBackground)
        static let surface = Color(.secondarySystemBackground)
        static let surfaceRaised = Color(.tertiarySystemBackground)

        static let primaryText = Color(.label)
        static let secondaryText = Color(.secondaryLabel)
        static let tertiaryText = Color(.tertiaryLabel)

        static let separator = Color(.separator)
        static let success = Color(.systemGreen)
        static let warning = Color(.systemOrange)
        static let danger = Color(.systemRed)

        /// Inference, not fact. Deliberately quiet — a "Guessed" badge should be findable, not
        /// alarming.
        static let guessed = Color(.systemOrange).opacity(0.85)
    }

    // MARK: - Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 14
        static let large: CGFloat = 22
        static let card: CGFloat = 20
    }

    // MARK: - Type

    /// Everything routes through Dynamic Type. Fixed point sizes appear nowhere, including in
    /// the timeline's time labels.
    enum Font {
        static let displayTitle = SwiftUI.Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let screenTitle = SwiftUI.Font.system(.title2, design: .rounded, weight: .semibold)
        static let sectionTitle = SwiftUI.Font.system(.headline, design: .rounded, weight: .semibold)
        static let body = SwiftUI.Font.system(.body)
        static let callout = SwiftUI.Font.system(.callout)
        static let caption = SwiftUI.Font.system(.caption)
        /// Rounded numerals for anything that counts or measures.
        static let metric = SwiftUI.Font.system(.title3, design: .rounded, weight: .semibold)
        static let metricLabel = SwiftUI.Font.system(.caption2, design: .rounded, weight: .medium)
    }

    // MARK: - Motion

    /// Nothing over 350ms, and everything respects `accessibilityReduceMotion` by degrading to
    /// a cross-fade rather than by becoming instant — instant transitions lose the sense of
    /// where you came from.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.28)
        static let smooth = Animation.smooth(duration: 0.34)
        static let quick = Animation.snappy(duration: 0.18)

        static func respectingReduceMotion(_ animation: Animation, reduce: Bool) -> Animation {
            reduce ? .easeInOut(duration: 0.2) : animation
        }
    }
}

// MARK: - Haptics

/// Sparingly used. Haptic inflation is worse than silence — if everything buzzes, the buzz on
/// the thing that matters carries no information.
enum Haptics {
    #if canImport(UIKit)
    private static let selection = UISelectionFeedbackGenerator()
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()
    #endif

    /// Snapping the playhead to a cut or a beat. The beat grid is felt as much as seen.
    static func snap() {
        #if canImport(UIKit)
        selection.selectionChanged()
        #endif
    }

    /// Grabbing a clip or a trim handle.
    static func grab() {
        #if canImport(UIKit)
        impactLight.impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        notification.notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        notification.notificationOccurred(.warning)
        #endif
    }

    static func prepare() {
        #if canImport(UIKit)
        selection.prepare()
        impactLight.prepare()
        #endif
    }
}

// MARK: - Modifiers

extension View {
    /// Enforces the 44pt minimum by construction rather than by vigilance.
    func minimumHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    func cardSurface() -> some View {
        background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
