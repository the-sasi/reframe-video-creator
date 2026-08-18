import SwiftUI

/// Design tokens.
///
/// Dark-first, because video editing happens in the dark and a bright chrome fights the
/// footage. Light mode is fully supported through semantic colours.
///
/// The earlier version leaned almost entirely on system defaults, which made every screen the
/// same weight — nothing guided the eye. This adds three things that do most of the work:
/// **elevation** (surfaces sit at distinct depths), **a gradient accent** (one warm ramp that
/// marks the primary action), and **a real type scale** (display sizes that are actually
/// display-sized).
enum Theme {

    // MARK: - Colour

    enum Palette {
        /// Amber. Warm and cinematic on the dark chrome, unmistakable as "the thing to tap",
        /// and it reads as a video tool rather than a lifestyle app. The original rose was
        /// chosen to match a bouquet-shop sample reel, which is not a reason.
        static let accent = Color(red: 0.961, green: 0.722, blue: 0.302)   // #F5B84D
        static let accentDeep = Color(red: 0.788, green: 0.490, blue: 0.071) // #C97D12
        static let accentSoft = Color(red: 0.961, green: 0.722, blue: 0.302).opacity(0.16)
        /// Text and glyphs *on* the accent. Gold is light; white on it fails contrast, so
        /// anything sitting on an accent fill uses this near-black instead.
        static let onAccent = Color(red: 0.12, green: 0.08, blue: 0.02)

        /// The one gradient in the app. Used for the primary action and nothing else, so it
        /// keeps meaning "this is the thing to tap".
        static let accentGradient = LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        /// A wash for hero surfaces — deliberately faint, so it reads as light falling on the
        /// card rather than as a coloured panel.
        static let heroWash = LinearGradient(
            colors: [
                accent.opacity(0.22),
                accentDeep.opacity(0.10),
                Color.clear,
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

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

        /// Inference, not fact. Quiet on purpose — findable, not alarming. Cool, so it never
        /// reads as the (warm) accent.
        static let guessed = Color(.systemIndigo).opacity(0.9)

        /// Hairline that reads on both light and dark without needing two definitions.
        static let hairline = Color.primary.opacity(0.08)
    }

    // MARK: - Elevation

    /// Three depths, and no more. A surface either sits on the background, floats above it, or
    /// is the thing you're meant to tap.
    enum Elevation {
        case flat, raised, floating

        var shadowColor: Color {
            switch self {
            case .flat: return .clear
            case .raised: return .black.opacity(0.18)
            case .floating: return .black.opacity(0.28)
            }
        }

        var radius: CGFloat {
            switch self {
            case .flat: return 0
            case .raised: return 12
            case .floating: return 24
            }
        }

        var y: CGFloat {
            switch self {
            case .flat: return 0
            case .raised: return 4
            case .floating: return 10
            }
        }
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
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let card: CGFloat = 22
        static let hero: CGFloat = 28
    }

    // MARK: - Type

    /// Everything routes through Dynamic Type; there are no fixed point sizes in the app.
    enum Font {
        static let hero = SwiftUI.Font.system(size: 34, weight: .bold, design: .rounded)
        static let displayTitle = SwiftUI.Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let screenTitle = SwiftUI.Font.system(.title2, design: .rounded, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(.title3, design: .rounded, weight: .bold)
        static let sectionTitle = SwiftUI.Font.system(.headline, design: .rounded, weight: .semibold)
        static let body = SwiftUI.Font.system(.body)
        static let callout = SwiftUI.Font.system(.callout)
        static let caption = SwiftUI.Font.system(.caption)

        /// Rounded numerals for anything that counts or measures.
        static let metric = SwiftUI.Font.system(size: 22, weight: .bold, design: .rounded)
        static let metricLabel = SwiftUI.Font.system(size: 11, weight: .medium, design: .rounded)
        /// Monospaced digits, for anything that changes while you watch it.
        static let timecode = SwiftUI.Font.system(.callout, design: .rounded).monospacedDigit()
    }

    // MARK: - Motion

    /// Nothing over 350ms. `accessibilityReduceMotion` degrades to a cross-fade rather than to
    /// nothing — an instant change loses the sense of where you came from.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.28)
        static let smooth = Animation.smooth(duration: 0.34)
        static let quick = Animation.snappy(duration: 0.18)
        static let bouncy = Animation.spring(response: 0.35, dampingFraction: 0.72)

        static func respectingReduceMotion(_ animation: Animation, reduce: Bool) -> Animation {
            reduce ? .easeInOut(duration: 0.2) : animation
        }
    }
}

// MARK: - Haptics

/// Sparingly used. If everything buzzes, the buzz on the thing that matters carries no
/// information.
///
/// `@MainActor` because UIKit's feedback generators have main-actor-isolated initialisers.
@MainActor
enum Haptics {
    #if canImport(UIKit)
    private static let selection = UISelectionFeedbackGenerator()
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactSoft = UIImpactFeedbackGenerator(style: .soft)
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

    /// Advancing a step in the main flow.
    static func step() {
        #if canImport(UIKit)
        impactSoft.impactOccurred()
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
        impactSoft.prepare()
        #endif
    }
}

// MARK: - Modifiers

extension View {
    /// Enforces the 44pt minimum by construction rather than by vigilance.
    nonisolated func minimumHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    /// A standard card: surface, hairline, and a shadow appropriate to its depth.
    nonisolated func cardSurface(
        _ elevation: Theme.Elevation = .raised,
        radius: CGFloat = Theme.Radius.card
    ) -> some View {
        background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            }
            .shadow(
                color: elevation.shadowColor,
                radius: elevation.radius,
                x: 0, y: elevation.y
            )
    }

    /// The one hero surface per screen — a card carrying the accent wash.
    nonisolated func heroSurface() -> some View {
        background {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                        .fill(Theme.Palette.heroWash)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .strokeBorder(Theme.Palette.accent.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: Theme.Elevation.floating.shadowColor, radius: 20, x: 0, y: 8)
    }

    /// Presses inward slightly. Applied to tappable cards so they acknowledge the touch —
    /// the previous build had no press feedback anywhere, which made it feel inert.
    nonisolated func pressable() -> some View {
        buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}
