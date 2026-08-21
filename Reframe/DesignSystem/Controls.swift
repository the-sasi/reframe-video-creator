import ReframeKit
import SwiftUI

// Reusable controls beyond the primitives in Components.swift: chips, choice cards, tool
// buttons, labelled sliders, sheet scaffolding. Every editor panel is built from these, which
// is what keeps forty controls feeling like one product.

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: AnyView?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.sectionTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

// MARK: - Chips

/// A small selectable pill — categories, presets, quick values.
struct Chip: View {
    let title: String
    var systemImage: String?
    var isSelected = false
    var tint: Color = Theme.Palette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Theme.Palette.onAccent : Theme.Palette.primaryText)
            .background(
                isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.Palette.surfaceRaised),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(isSelected ? .clear : Theme.Palette.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A horizontal, scrolling row of chips.
struct ChipRow<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    var systemImage: ((Item) -> String?)? = nil
    @Binding var selection: Item

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(items, id: \.self) { item in
                    Chip(
                        title: title(item),
                        systemImage: systemImage?(item),
                        isSelected: item == selection
                    ) {
                        withAnimation(Theme.Motion.quick) { selection = item }
                        Haptics.snap()
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Choice cards

/// A tall, tappable card with a title, a line of copy and a checkmark when chosen. Used for
/// the fidelity mode and audio choices — decisions with a sentence of consequence each.
struct ChoiceCard: View {
    let title: String
    let detail: String
    var systemImage: String
    var isSelected: Bool
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.Palette.onAccent : Theme.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        isSelected ? AnyShapeStyle(Theme.Palette.accentGradient) : AnyShapeStyle(Theme.Palette.accentSoft),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(title)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.Palette.accentSoft, in: Capsule())
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.tertiaryText)
            }
            .padding(Theme.Space.m)
            .background(
                Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Palette.accent.opacity(0.6) : Theme.Palette.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .pressable()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Tool buttons

/// An icon-over-label button for the editor's contextual toolbar.
struct ToolButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isDestructive ? Theme.Palette.danger
                    : (isActive ? Theme.Palette.accent : Theme.Palette.primaryText)
            )
            .frame(width: 64, height: 56)
            .background(
                isActive ? Theme.Palette.accentSoft : Theme.Palette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Sliders

/// A slider with a title and a live value, that coalesces its drag into one undo step.
struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String
    var onEditingChanged: ((Bool) -> Void)?
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(.subheadline, design: .rounded))
                Spacer()
                Text(format(value))
                    .font(.system(.caption, design: .rounded, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Group {
                if let step {
                    Slider(
                        value: Binding(get: { value }, set: onChange),
                        in: range, step: step,
                        onEditingChanged: { onEditingChanged?($0) }
                    )
                } else {
                    Slider(
                        value: Binding(get: { value }, set: onChange),
                        in: range,
                        onEditingChanged: { onEditingChanged?($0) }
                    )
                }
            }
            .tint(Theme.Palette.accent)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sheet scaffold

/// A bottom sheet with a title row and a Done button. Every editor panel uses it, so the
/// panels feel like one family rather than five.
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var leading: AnyView?
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let leading {
                        ToolbarItem(placement: .topBarLeading) { leading }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

// MARK: - Swatches

/// A colour swatch row: presets plus a system colour picker.
struct ColorSwatchRow: View {
    let selectedHex: String
    let onSelect: (String) -> Void

    static let swatches = [
        "#FFFFFF", "#000000", "#F5D06A", "#E97187", "#7FD1B9", "#5AA9E6", "#F28C38", "#B388EB",
    ]

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(Self.swatches, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().strokeBorder(
                            selectedHex.uppercased() == hex ? Theme.Palette.accent : Color.primary.opacity(0.18),
                            lineWidth: selectedHex.uppercased() == hex ? 3 : 1
                        )
                    }
                    .onTapGesture {
                        onSelect(hex)
                        Haptics.snap()
                    }
                    .accessibilityLabel("Colour \(hex)")
            }
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(hex: selectedHex) },
                    set: { onSelect($0.hexString ?? selectedHex) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 26, height: 26)
        }
    }
}

extension Color {
    /// Mirrors `SIMD4<Float>.fromHex` in the renderer so the swatch matches what gets drawn.
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        let value = UInt32(cleaned, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBB`, resolved in sRGB. Nil if the colour has no RGB representation.
    var hexString: String? {
        guard let components = UIColor(self).cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        )?.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Thumbnails

/// A photo-library or file-backed thumbnail, cached per identifier for the session.
struct AssetThumbnailView: View {
    let asset: AssetReference
    var size: CGSize = CGSize(width: 120, height: 160)
    var cornerRadius: CGFloat = Theme.Radius.small
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.Palette.surfaceRaised)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: asset.kind == .video ? "film" : (asset.kind == .audio ? "waveform" : "photo"))
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if asset.kind == .video {
                    Text(Self.duration(asset.duration))
                        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                }
            }
            .task(id: asset.id) { image = await ThumbnailCache.shared.thumbnail(for: asset, size: size) }
            .accessibilityLabel(asset.displayName)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
    }
}
