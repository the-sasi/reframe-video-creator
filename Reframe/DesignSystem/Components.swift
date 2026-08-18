import ReframeKit
import SwiftUI

// MARK: - Buttons

/// The single primary action on a screen. There is never more than one.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isEnabled: Bool = true
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.step()
            action()
        } label: {
            HStack(spacing: Theme.Space.s) {
                if isBusy {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Palette.accentGradient)
                    .opacity(isEnabled ? 1 : 0.32)
            }
            .shadow(
                color: Theme.Palette.accent.opacity(isEnabled ? 0.35 : 0),
                radius: 14, x: 0, y: 6
            )
        }
        .disabled(!isEnabled || isBusy)
        .pressable()
        .accessibilityLabel(title)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                }
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(Theme.Palette.primaryText)
            .cardSurface(.flat, radius: Theme.Radius.medium)
        }
        .pressable()
    }
}

// MARK: - Confidence

/// Marks an inference as an inference.
///
/// This is the component that makes the app feel honest instead of magic, and it costs nothing
/// — the confidence and its `basis` are already in the recipe. Tapping reveals the reasoning in
/// plain language.
struct GuessedBadge: View {
    let confidence: Double
    let basis: String
    @State private var showsBasis = false

    var body: some View {
        if ConfidenceBand(confidence).needsGuessedBadge {
            Button {
                showsBasis = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 9))
                    Text("Guessed").font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.Palette.guessed.opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.Palette.guessed)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsBasis) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("How sure is this?")
                        .font(Theme.Font.sectionTitle)
                    Text("\(Int(confidence * 100))% confident")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.accent)
                    Text(BasisPhrasing.plainLanguage(basis))
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: 320)
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("Guessed, \(Int(confidence * 100)) percent confident. \(basis)")
        }
    }
}

/// Turns the analyser's terse `basis` strings into something a person would say.
///
/// The machine-readable form stays in the JSON for debugging; this is only for display.
enum BasisPhrasing {
    static func plainLanguage(_ basis: String) -> String {
        if basis.hasPrefix("similarity fit") {
            return "I tracked how the frame moved between sampled frames and fitted a camera move to it. \(basis)"
        }
        if basis.hasPrefix("blend residual") {
            return "The frames in between were almost exactly a blend of the shots either side, which is what a cross-fade looks like. \(basis)"
        }
        if basis.hasPrefix("frame delta") {
            return "The picture changed far more between these two frames than between their neighbours. \(basis)"
        }
        if basis.hasPrefix("luma std dev") {
            return "The picture flattened out toward a single colour, which is what a fade looks like. \(basis)"
        }
        if basis.hasPrefix("autocorrelation") {
            return "I looked for the interval that best explains where the beats land. \(basis)"
        }
        if basis.contains("not possible at this resolution") {
            return "Fonts can't be identified from video — this is a category guess based on letter proportions."
        }
        return basis
    }
}

// MARK: - Metrics

struct MetricTile: View {
    let value: String
    let label: String
    var systemImage: String?

    var body: some View {
        VStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(height: 18)
            }
            Text(value)
                .font(Theme.Font.metric)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(Theme.Font.metricLabel)
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// A numbered step marker for the main flow, so you always know where you are in it.
struct FlowProgress: View {
    let step: Int
    let total: Int
    let title: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 4) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(
                            index <= step
                                ? AnyShapeStyle(Theme.Palette.accentGradient)
                                : AnyShapeStyle(Theme.Palette.hairline)
                        )
                        .frame(width: index == step ? 22 : 7, height: 5)
                        .animation(Theme.Motion.bouncy, value: step)
                }
            }
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.Palette.secondaryText)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(total): \(title)")
    }
}

// MARK: - States

/// Empty states propose the next action rather than describing the absence.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.tertiaryText)
            Text(title).font(Theme.Font.sectionTitle)
            Text(message)
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .minimumHitTarget()
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Stage list for the analysis and generation screens.
///
/// Stages complete; they do not tick up. The number that appears is a result, not reassurance —
/// which is harder than a fake percentage and much better.
struct StageRow: View {
    let title: String
    let status: StageState.Status

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            icon
                .frame(width: 22, height: 22)
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(isPending ? Theme.Palette.tertiaryText : Theme.Palette.primaryText)
            Spacer()
            if case .done(let summary) = status, !summary.isEmpty {
                Text(summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var isPending: Bool {
        if case .pending = status { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Theme.Palette.tertiaryText)
        case .running(let fraction):
            if let fraction {
                // Determinate only where the denominator is genuinely known.
                CircularProgress(fraction: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.Palette.danger)
        }
    }
}

struct CircularProgress: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.separator, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Theme.Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .animation(Theme.Motion.quick, value: fraction)
    }
}

// MARK: - Errors

/// Errors carry an action, not just an apology.
struct ErrorSheet: View {
    let error: ReframeError
    let onRecover: (ReframeError.RecoveryAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let presentation = error.presentation

        VStack(spacing: Theme.Space.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.Palette.warning)

            VStack(spacing: Theme.Space.s) {
                Text(presentation.title).font(Theme.Font.screenTitle)
                Text(presentation.message)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Theme.Space.s) {
                PrimaryButton(title: presentation.recovery.buttonTitle) {
                    onRecover(presentation.recovery)
                }
                if presentation.recovery != .dismiss {
                    Button("Not now", action: onDismiss)
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .minimumHitTarget()
                }
            }
        }
        .padding(Theme.Space.l)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
    }
}
