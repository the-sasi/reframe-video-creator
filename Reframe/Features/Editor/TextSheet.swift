import ReframeKit
import SwiftUI

/// Text editing — previously unreachable.
///
/// The Text toolbar button switched a highlight and rendered nothing, which meant whatever you
/// typed on the content screen was permanent. Everything here goes through `EditCommand`, so
/// text edits share the undo stack with clip edits.
struct TextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TimelineDocument
    let currentTime: Double

    @State private var selectedID: UUID?

    private var layers: [TextLayer] { document.timeline.textLayers.sorted { $0.start < $1.start } }

    var body: some View {
        NavigationStack {
            Group {
                if layers.isEmpty {
                    EmptyStateView(
                        systemImage: "textformat",
                        title: "No text yet",
                        message: "Add a title, a caption or a call to action.",
                        actionTitle: "Add Text",
                        action: addLayer
                    )
                } else {
                    List {
                        ForEach(layers) { layer in
                            Section {
                                TextLayerEditor(document: document, layer: layer)
                            } header: {
                                HStack {
                                    Text(layer.role.displayName)
                                    Spacer()
                                    Button(role: .destructive) {
                                        delete(layer)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.Palette.danger)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        addLayer()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add text")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addLayer() {
        let duration = document.timeline.duration
        // Start at the playhead so a new layer appears where you were looking, clamped so it
        // always has room to be visible.
        let start = min(max(0, currentTime), max(0, duration - 1.0))
        let layer = TextLayer(
            text: "Your text",
            role: layers.isEmpty ? .title : .caption,
            start: start,
            end: min(duration, start + 2.5),
            frame: NormalizedRect(x: 0.08, y: 0.16, width: 0.84, height: 0.14),
            alignment: .center,
            sizeRatio: layers.isEmpty ? 0.062 : 0.042
        )
        document.perform(.addTextLayer(layer: layer))
        Haptics.grab()
    }

    private func delete(_ layer: TextLayer) {
        guard let index = document.timeline.textLayers.firstIndex(where: { $0.id == layer.id })
        else { return }
        document.perform(.deleteTextLayer(index: index, layer: layer))
    }
}

/// One text layer's controls.
private struct TextLayerEditor: View {
    let document: TimelineDocument
    let layer: TextLayer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextField(
                "Text",
                text: Binding(
                    get: { layer.text },
                    set: { newValue in
                        document.perform(
                            .setTextContent(id: layer.id, text: newValue, wasText: layer.text)
                        )
                    }
                ),
                axis: .vertical
            )
            .font(.system(.body, design: .rounded, weight: .medium))
            .lineLimit(1...3)
            .padding(Theme.Space.s)
            .background(
                Theme.Palette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            )

            labelled("Size") {
                Slider(
                    value: styleBinding(\.sizeRatio, apply: { $0.sizeRatio = $1 }),
                    in: 0.02...0.12
                )
                .tint(Theme.Palette.accent)
            }

            labelled("Position") {
                Slider(
                    value: Binding(
                        get: { layer.frame.y },
                        set: { newValue in
                            var frame = layer.frame
                            frame.y = newValue
                            document.perform(
                                .setTextFrame(id: layer.id, frame: frame, wasFrame: layer.frame)
                            )
                        }
                    ),
                    in: 0.02...0.88
                )
                .tint(Theme.Palette.accent)
            }

            HStack(spacing: Theme.Space.m) {
                // `SlotTextAlignment` rather than `TextAlignment`: SwiftUI declares its own,
                // so the bare name is ambiguous in any view file.
                Picker(
                    "Align",
                    selection: styleBinding(\.alignment, apply: { $0.alignment = $1 })
                ) {
                    Image(systemName: "text.alignleft").tag(SlotTextAlignment.leading)
                    Image(systemName: "text.aligncenter").tag(SlotTextAlignment.center)
                    Image(systemName: "text.alignright").tag(SlotTextAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Picker("Font", selection: styleBinding(\.fontCategory, apply: { $0.fontCategory = $1 })) {
                ForEach(FontCategory.allCases, id: \.self) { category in
                    Text(category.displayName).tag(category)
                }
            }

            Picker("Entrance", selection: styleBinding(\.entry, apply: { $0.entry = $1 })) {
                ForEach(TextEntryAnimation.allCases, id: \.self) { animation in
                    Text(animation.displayName).tag(animation)
                }
            }

            ColorRow(document: document, layer: layer)

            Toggle(
                "Shadow",
                isOn: styleBinding(\.hasShadow, apply: { $0.hasShadow = $1 })
            )
            .tint(Theme.Palette.accent)

            timingRow
        }
        .padding(.vertical, 2)
    }

    private var timingRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Timing").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text(String(format: "%.1fs – %.1fs", layer.start, layer.end))
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            HStack(spacing: Theme.Space.s) {
                Slider(
                    value: Binding(
                        get: { layer.start },
                        set: { retime(start: $0, end: max($0 + 0.4, layer.end)) }
                    ),
                    in: 0...max(0.5, document.timeline.duration)
                )
                Slider(
                    value: Binding(
                        get: { layer.end },
                        set: { retime(start: min(layer.start, $0 - 0.4), end: $0) }
                    ),
                    in: 0...max(0.5, document.timeline.duration)
                )
            }
            .tint(Theme.Palette.accent)
        }
    }

    private func retime(start: Double, end: Double) {
        document.perform(
            .setTextTiming(
                id: layer.id, start: max(0, start), end: end,
                wasStart: layer.start, wasEnd: layer.end
            )
        )
    }

    /// All style fields travel together in one command, so a font change and a colour change
    /// are separate undo steps rather than one merged blob.
    private func styleBinding<Value>(
        _ keyPath: KeyPath<TextLayer, Value>,
        apply: @escaping (inout TextLayerStyle, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { layer[keyPath: keyPath] },
            set: { newValue in
                let was = TextLayerStyle(layer: layer)
                var style = was
                apply(&style, newValue)
                document.perform(.setTextStyle(id: layer.id, style: style, wasStyle: was))
            }
        )
    }

    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            content()
        }
    }
}

/// A small palette rather than a full colour picker — video text is legible in about six
/// colours and a wheel invites choices that vanish against footage.
private struct ColorRow: View {
    let document: TimelineDocument
    let layer: TextLayer

    private static let swatches = [
        "#FFFFFF", "#000000", "#E97187", "#F5D06A", "#7FD1B9", "#2B2B2E",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colour")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            HStack(spacing: Theme.Space.s) {
                ForEach(Self.swatches, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle().strokeBorder(
                                layer.colorHex.uppercased() == hex
                                    ? Theme.Palette.accent
                                    : Color.white.opacity(0.25),
                                lineWidth: layer.colorHex.uppercased() == hex ? 3 : 1
                            )
                        }
                        .onTapGesture {
                            let was = TextLayerStyle(layer: layer)
                            var style = was
                            style.colorHex = hex
                            document.perform(
                                .setTextStyle(id: layer.id, style: style, wasStyle: was)
                            )
                            Haptics.snap()
                        }
                }
                Spacer()
            }
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
}
