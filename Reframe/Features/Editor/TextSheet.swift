import ReframeKit
import SwiftUI

/// Text editing: layers on the left of your attention, one layer's controls below.
///
/// Presets first — most people want "a look" not "a letter-spacing value" — then the details.
/// Everything routes through `EditCommand`, so text edits share the undo stack with clip edits,
/// and slider drags coalesce into one step.
struct TextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TimelineDocument
    let currentTime: Double
    var selectedID: UUID?

    @State private var activeID: UUID?
    @State private var tab: Tab = .style

    enum Tab: String, CaseIterable, Identifiable {
        case style, font, animate, timing
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private var layers: [TextLayer] { document.timeline.textLayers.sorted { $0.start < $1.start } }
    private var active: TextLayer? {
        layers.first { $0.id == (activeID ?? selectedID) } ?? layers.first { $0.isVisible(at: currentTime) } ?? layers.first
    }

    var body: some View {
        SheetScaffold(
            title: "Text",
            leading: AnyView(
                Button {
                    addLayer()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add text")
            ),
            detents: [.medium, .large]
        ) {
            if layers.isEmpty {
                EmptyStateView(
                    systemImage: "textformat",
                    title: "No text yet",
                    message: "Add a title, a caption or a call to action. It lands at the playhead.",
                    actionTitle: "Add Text",
                    action: addLayer
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        layerStrip
                        if let layer = active {
                            editor(for: layer)
                        }
                    }
                    .padding(Theme.Space.m)
                    .padding(.bottom, Theme.Space.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear { activeID = selectedID }
    }

    // MARK: - Layer strip

    private var layerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(layers) { layer in
                    let isActive = layer.id == active?.id
                    Button {
                        activeID = layer.id
                        Haptics.snap()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layer.text.isEmpty ? "Empty" : layer.text)
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .lineLimit(1)
                            Text("\(layer.role.displayName) · \(String(format: "%.1f–%.1fs", layer.start, layer.end))")
                                .font(.system(size: 10))
                                .foregroundStyle(isActive ? .white.opacity(0.85) : Theme.Palette.secondaryText)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: 180, alignment: .leading)
                        .foregroundStyle(isActive ? .white : Theme.Palette.primaryText)
                        .background(isActive ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.surfaceRaised),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { delete(layer) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    // MARK: - Editor

    private func editor(for layer: TextLayer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextField(
                "Text",
                text: Binding(
                    get: { layer.text },
                    set: { newValue in
                        document.perform(.setTextContent(id: layer.id, text: newValue, wasText: layer.text))
                    }
                ),
                axis: .vertical
            )
            .font(.system(.body, design: .rounded, weight: .medium))
            .lineLimit(1...4)
            .padding(Theme.Space.s)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .onSubmit { document.endGesture() }
            .onChange(of: layer.id) { _, _ in document.endGesture() }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .style: styleControls(layer)
            case .font: fontControls(layer)
            case .animate: animationControls(layer)
            case .timing: timingControls(layer)
            }

            HStack {
                Button(role: .destructive) { delete(layer) } label: { Label("Delete layer", systemImage: "trash") }
                    .font(.system(.caption, design: .rounded, weight: .medium))
                Spacer()
            }
            .padding(.top, Theme.Space.s)
        }
    }

    // MARK: Style

    private func styleControls(_ layer: TextLayer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Presets").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(TextPreset.all) { preset in
                            Button {
                                apply(preset, to: layer)
                            } label: {
                                Text(preset.sample)
                                    .font(preset.previewFont)
                                    .foregroundStyle(Color(hex: preset.colorHex))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(
                                        preset.background.map { AnyShapeStyle(Color(hex: $0.colorHex).opacity($0.opacity)) }
                                            ?? AnyShapeStyle(Color.black.opacity(0.35)),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(alignment: .bottom) {
                                        Text(preset.name)
                                            .font(.system(size: 9, weight: .medium, design: .rounded))
                                            .foregroundStyle(Theme.Palette.secondaryText)
                                            .offset(y: 14)
                                    }
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 14)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Colour").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                ColorSwatchRow(selectedHex: layer.colorHex) { hex in
                    setStyle(layer) { $0.colorHex = hex }
                }
            }

            LabeledSlider(title: "Size", value: layer.sizeRatio, range: 0.02...0.14, format: { "\(Int($0 * 1000))" },
                          onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.sizeRatio = $1 })
            LabeledSlider(title: "Opacity", value: layer.opacity, range: 0.1...1, format: { "\(Int($0 * 100))%" },
                          onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.opacity = $1 })

            HStack(spacing: Theme.Space.s) {
                Chip(title: "Shadow", systemImage: "shadow", isSelected: layer.hasShadow) {
                    setStyle(layer) { $0.hasShadow.toggle() }
                }
                Chip(title: "Outline", systemImage: "circle.dashed", isSelected: layer.outline != nil) {
                    setStyle(layer) { $0.outline = $0.outline == nil ? TextOutline() : nil }
                }
                Chip(title: "Background", systemImage: "rectangle.fill", isSelected: layer.background != nil) {
                    setStyle(layer) { $0.background = $0.background == nil ? TextBackground() : nil }
                }
                Chip(title: "Caps", systemImage: "textformat.size.larger", isSelected: layer.allCaps) {
                    setStyle(layer) { $0.allCaps.toggle() }
                }
            }

            if let outline = layer.outline {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outline colour").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                    ColorSwatchRow(selectedHex: outline.colorHex) { hex in
                        setStyle(layer) { $0.outline?.colorHex = hex }
                    }
                }
                LabeledSlider(title: "Outline width", value: outline.widthEm, range: 0.02...0.16, format: { String(format: "%.2f", $0) },
                              onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.outline?.widthEm = $1 })
            }
            if let background = layer.background {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background colour").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                    ColorSwatchRow(selectedHex: background.colorHex) { hex in
                        setStyle(layer) { $0.background?.colorHex = hex }
                    }
                }
                LabeledSlider(title: "Background opacity", value: background.opacity, range: 0.1...1, format: { "\(Int($0 * 100))%" },
                              onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.background?.opacity = $1 })
                LabeledSlider(title: "Corner radius", value: background.cornerRadiusEm, range: 0...0.8, format: { String(format: "%.2f", $0) },
                              onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.background?.cornerRadiusEm = $1 })
            }

            LabeledSlider(title: "Rotation", value: layer.rotation * 180 / .pi, range: -45...45, step: 1, format: { "\(Int($0))°" },
                          onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.rotation = $1 * .pi / 180 })
        }
    }

    // MARK: Font

    private func fontControls(_ layer: TextLayer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Font").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(TextFont.all) { font in
                        let isActive = layer.fontName == font.familyName
                        Button {
                            setStyle(layer) { style in
                                style.fontName = font.familyName
                                style.fontCategory = font.category
                            }
                        } label: {
                            Text(font.displayName)
                                .font(font.familyName.flatMap { $0.hasPrefix(".") ? nil : Font.custom($0, size: 14) } ?? .system(size: 14, weight: .semibold, design: font.id == "sf-rounded" ? .rounded : .default))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .foregroundStyle(isActive ? .white : Theme.Palette.primaryText)
                                .background(isActive ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.surfaceRaised),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Weight").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                ChipRow(items: TextWeight.allCases, title: { $0.displayName },
                        selection: Binding(get: { layer.weight }, set: { w in setStyle(layer) { $0.weight = w } }))
            }

            HStack(spacing: Theme.Space.s) {
                Chip(title: "Italic", systemImage: "italic", isSelected: layer.isItalic) { setStyle(layer) { $0.isItalic.toggle() } }
                Picker("Align", selection: Binding(get: { layer.alignment }, set: { a in setStyle(layer) { $0.alignment = a } })) {
                    Image(systemName: "text.alignleft").tag(SlotTextAlignment.leading)
                    Image(systemName: "text.aligncenter").tag(SlotTextAlignment.center)
                    Image(systemName: "text.alignright").tag(SlotTextAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            LabeledSlider(title: "Letter spacing", value: layer.letterSpacing, range: -0.05...0.3, format: { String(format: "%.2f", $0) },
                          onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.letterSpacing = $1 })
            LabeledSlider(title: "Line spacing", value: layer.lineSpacing, range: 0.85...1.8, format: { String(format: "%.2f", $0) },
                          onEditingChanged: gesture("style:\(layer.id)"), onChange: styleSetter(layer) { $0.lineSpacing = $1 })
        }
    }

    // MARK: Animate

    private func animationControls(_ layer: TextLayer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Entrance").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(TextEntryAnimation.allCases, id: \.self) { animation in
                        Chip(title: animation.displayName, isSelected: layer.entry == animation && layer.wordTimings == nil) {
                            setStyle(layer) { $0.entry = animation }
                            if layer.wordTimings != nil {
                                document.perform(.setTextWordTimings(id: layer.id, timings: nil, wasTimings: layer.wordTimings))
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Exit").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                HStack(spacing: Theme.Space.s) {
                    ForEach(TextExitAnimation.allCases, id: \.self) { animation in
                        Chip(title: exitName(animation), isSelected: layer.exit == animation) {
                            setStyle(layer) { $0.exit = animation }
                        }
                    }
                }
            }
            if layer.wordTimings != nil {
                Label("This layer has per-word timing from captions. Choosing an entrance replaces it.", systemImage: "captions.bubble")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    private func exitName(_ exit: TextExitAnimation) -> String {
        switch exit {
        case .none: return "None"
        case .fadeOut: return "Fade out"
        case .popOut: return "Pop out"
        case .slideDown: return "Slide down"
        }
    }

    // MARK: Timing

    private func timingControls(_ layer: TextLayer) -> some View {
        let duration = max(0.5, document.timeline.duration)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            LabeledSlider(title: "Starts", value: layer.start, range: 0...duration, format: { PreviewPane.timecode($0) },
                          onEditingChanged: gesture("texttime:\(layer.id)")) { new in
                document.perform(.setTextTiming(id: layer.id, start: new, end: max(new + 0.3, layer.end), wasStart: layer.start, wasEnd: layer.end))
            }
            LabeledSlider(title: "Ends", value: layer.end, range: 0...max(duration, layer.end), format: { PreviewPane.timecode($0) },
                          onEditingChanged: gesture("texttime:\(layer.id)")) { new in
                document.perform(.setTextTiming(id: layer.id, start: min(layer.start, new - 0.3), end: new, wasStart: layer.start, wasEnd: layer.end))
            }
            HStack(spacing: Theme.Space.s) {
                Chip(title: "Start at playhead", systemImage: "arrow.right.to.line") {
                    let length = layer.duration
                    document.perform(.setTextTiming(id: layer.id, start: currentTime, end: currentTime + length, wasStart: layer.start, wasEnd: layer.end))
                }
                Chip(title: "End at playhead", systemImage: "arrow.left.to.line") {
                    guard currentTime > layer.start + 0.3 else { return }
                    document.perform(.setTextTiming(id: layer.id, start: layer.start, end: currentTime, wasStart: layer.start, wasEnd: layer.end))
                }
                Chip(title: "Whole video", systemImage: "rectangle.expand.vertical") {
                    document.perform(.setTextTiming(id: layer.id, start: 0, end: document.timeline.duration, wasStart: layer.start, wasEnd: layer.end))
                }
            }
            LabeledSlider(title: "Vertical position", value: layer.frame.y, range: 0.02...0.88, format: { "\(Int($0 * 100))%" },
                          onEditingChanged: gesture("textframe:\(layer.id)")) { new in
                var frame = layer.frame
                frame.y = new
                document.perform(.setTextFrame(id: layer.id, frame: frame, wasFrame: layer.frame))
            }
            Text("Drag the text on the preview to place it anywhere; drag its chip on the timeline to move it in time.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
        }
    }

    // MARK: - Helpers

    private func gesture(_ key: String) -> (Bool) -> Void {
        { editing in
            if editing { document.beginGesture(key: key) } else { document.endGesture() }
        }
    }

    /// One command per change; slider drags coalesce because `TimelineDocument.beginGesture`
    /// merges same-key `setTextStyle` commands... except that `setTextStyle` has no coalescing
    /// key by design (a font change and a colour change should be separate undo steps). So the
    /// sheet opens a gesture only around slider drags, and each discrete tap is its own step.
    private func setStyle(_ layer: TextLayer, _ mutate: (inout TextLayerStyle) -> Void) {
        let was = TextLayerStyle(layer: layer)
        var style = was
        mutate(&style)
        guard style != was else { return }
        document.perform(.setTextStyle(id: layer.id, style: style, wasStyle: was))
    }

    /// A slider's `onChange`: applies `mutate` with the slider value as one style command.
    private func styleSetter(_ layer: TextLayer, _ mutate: @escaping (inout TextLayerStyle, Double) -> Void) -> (Double) -> Void {
        { value in setStyle(layer) { mutate(&$0, value) } }
    }

    private func apply(_ preset: TextPreset, to layer: TextLayer) {
        setStyle(layer) { style in preset.apply(to: &style) }
        Haptics.snap()
    }

    private func addLayer() {
        let duration = document.timeline.duration
        let start = min(max(0, currentTime), max(0, duration - 1.0))
        let isFirst = layers.isEmpty
        let layer = TextLayer(
            text: "Your text",
            role: isFirst ? .title : .caption,
            start: start,
            end: min(max(duration, start + 1), start + 2.5),
            frame: NormalizedRect(x: 0.08, y: isFirst ? 0.16 : 0.7, width: 0.84, height: 0.14),
            alignment: .center,
            weight: .heavy,
            sizeRatio: isFirst ? 0.062 : 0.044
        )
        document.perform(.addTextLayer(layer: layer))
        activeID = layer.id
        Haptics.grab()
    }

    private func delete(_ layer: TextLayer) {
        guard let index = document.timeline.textLayers.firstIndex(where: { $0.id == layer.id }) else { return }
        document.perform(.deleteTextLayer(index: index, layer: layer))
        if activeID == layer.id { activeID = nil }
    }
}

/// Named looks for text. Each is a bundle of style fields, applied as one undo step.
struct TextPreset: Identifiable {
    let id: String
    let name: String
    let sample: String
    let colorHex: String
    let fontName: String?
    let category: FontCategory
    let weight: TextWeight
    let allCaps: Bool
    let letterSpacing: Double
    let hasShadow: Bool
    let outline: TextOutline?
    let background: TextBackground?
    let previewFont: Font

    func apply(to style: inout TextLayerStyle) {
        style.colorHex = colorHex
        style.fontName = fontName
        style.fontCategory = category
        style.weight = weight
        style.allCaps = allCaps
        style.letterSpacing = letterSpacing
        style.hasShadow = hasShadow
        style.outline = outline
        style.background = background
        style.isItalic = false
    }

    static let all: [TextPreset] = [
        TextPreset(id: "clean", name: "Clean", sample: "Clean", colorHex: "#FFFFFF", fontName: nil, category: .sansSerif, weight: .bold,
                   allCaps: false, letterSpacing: 0, hasShadow: true, outline: nil, background: nil,
                   previewFont: .system(size: 15, weight: .bold)),
        TextPreset(id: "bold", name: "Headline", sample: "HEADLINE", colorHex: "#FFFFFF", fontName: nil, category: .displayBold, weight: .black,
                   allCaps: true, letterSpacing: 0.02, hasShadow: true, outline: nil, background: nil,
                   previewFont: .system(size: 15, weight: .black)),
        TextPreset(id: "caption", name: "Caption", sample: "caption pill", colorHex: "#FFFFFF", fontName: nil, category: .sansSerif, weight: .heavy,
                   allCaps: false, letterSpacing: 0, hasShadow: false, outline: nil, background: TextBackground(),
                   previewFont: .system(size: 14, weight: .heavy)),
        TextPreset(id: "outline", name: "Outline", sample: "OUTLINE", colorHex: "#FFFFFF", fontName: nil, category: .displayBold, weight: .black,
                   allCaps: true, letterSpacing: 0.03, hasShadow: false, outline: TextOutline(colorHex: "#000000", widthEm: 0.07), background: nil,
                   previewFont: .system(size: 15, weight: .black)),
        TextPreset(id: "yellow", name: "Highlight", sample: "Highlight", colorHex: "#111111", fontName: nil, category: .sansSerif, weight: .heavy,
                   allCaps: false, letterSpacing: 0, hasShadow: false, outline: nil,
                   background: TextBackground(colorHex: "#F5D06A", opacity: 1, paddingEm: 0.3, cornerRadiusEm: 0.15),
                   previewFont: .system(size: 14, weight: .heavy)),
        TextPreset(id: "serif", name: "Editorial", sample: "Editorial", colorHex: "#FFFFFF", fontName: "Georgia", category: .serif, weight: .regular,
                   allCaps: false, letterSpacing: 0.01, hasShadow: true, outline: nil, background: nil,
                   previewFont: .custom("Georgia", size: 15)),
        TextPreset(id: "tracked", name: "Tracked", sample: "T R A C K E D", colorHex: "#FFFFFF", fontName: nil, category: .sansSerif, weight: .medium,
                   allCaps: true, letterSpacing: 0.25, hasShadow: true, outline: nil, background: nil,
                   previewFont: .system(size: 12, weight: .medium)),
        TextPreset(id: "script", name: "Script", sample: "Script", colorHex: "#FFFFFF", fontName: "Snell Roundhand", category: .handwritten, weight: .bold,
                   allCaps: false, letterSpacing: 0, hasShadow: true, outline: nil, background: nil,
                   previewFont: .custom("Snell Roundhand", size: 18)),
        TextPreset(id: "typewriter", name: "Type", sample: "typewriter", colorHex: "#F3E9DD", fontName: "American Typewriter", category: .serif, weight: .semibold,
                   allCaps: false, letterSpacing: 0.02, hasShadow: false, outline: nil,
                   background: TextBackground(colorHex: "#1C1C1E", opacity: 0.75, paddingEm: 0.35, cornerRadiusEm: 0.1),
                   previewFont: .custom("American Typewriter", size: 14)),
    ]
}
