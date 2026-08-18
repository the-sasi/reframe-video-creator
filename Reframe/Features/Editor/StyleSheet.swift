import ReframeKit
import SwiftUI

/// Per-clip look and motion — previously unreachable.
///
/// The Style button switched a highlight and rendered nothing, so colour, speed, volume and
/// framing were all locked at bind time despite the commands for them existing and being
/// covered by tests. Everything routes through `EditCommand`, so it all undoes.
struct StyleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TimelineDocument
    let selectedClipID: UUID?

    @State private var applyToAll = false

    private var clip: VideoClip? {
        if let selectedClipID, let found = document.timeline.clip(id: selectedClipID) {
            return found
        }
        return document.timeline.clips.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let clip {
                    List {
                        filterSection(clip)
                        scopeSection(clip)
                        colourSection(clip)
                        effectsSection(clip)
                        motionSection(clip)
                        audioSection(clip)
                    }
                } else {
                    EmptyStateView(
                        systemImage: "wand.and.rays",
                        title: "Nothing to style",
                        message: "Add some clips first."
                    )
                }
            }
            .navigationTitle("Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Sections

    private func filterSection(_ clip: VideoClip) -> some View {
        let active = FilterPreset.matching(
            grade: clip.grade, vignette: clip.vignette, grain: clip.grain
        )

        return Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(FilterPreset.all) { preset in
                        FilterChip(
                            preset: preset,
                            isActive: active?.id == preset.id
                        ) {
                            apply(preset, from: clip)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        } header: {
            HStack {
                Text("Filter")
                Spacer()
                Text(active?.name ?? "Custom")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
    }

    private func effectsSection(_ clip: VideoClip) -> some View {
        Section {
            slider(
                "Vignette", value: clip.vignette, range: 0...1,
                format: { "\(Int($0 * 100))%" }
            ) { newValue in
                applyEffects(from: clip, vignette: newValue, grain: clip.grain)
            }
            slider(
                "Grain", value: clip.grain, range: 0...1,
                format: { "\(Int($0 * 100))%" }
            ) { newValue in
                applyEffects(from: clip, vignette: clip.vignette, grain: newValue)
            }
        } header: {
            Text("Effects")
        }
    }

    private func scopeSection(_ clip: VideoClip) -> some View {
        Section {
            Toggle(isOn: $applyToAll) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Apply to every clip")
                    Text(
                        applyToAll
                            ? "Changes affect all \(document.timeline.clips.count) clips"
                            : "Changes affect the selected clip only"
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            .tint(Theme.Palette.accent)
        } header: {
            Text(
                selectedClipID == nil
                    ? "Editing the first clip"
                    : "Editing the selected clip"
            )
        }
    }

    private func colourSection(_ clip: VideoClip) -> some View {
        Section {
            slider(
                "Brightness", value: clip.grade.exposure, range: -0.5...0.5,
                format: { String(format: "%+.2f", $0) }
            ) { newValue in
                applyGrade(from: clip) { $0.exposure = newValue }
            }

            slider(
                "Contrast", value: clip.grade.contrast, range: 0.6...1.6,
                format: { String(format: "%.2f", $0) }
            ) { newValue in
                applyGrade(from: clip) { $0.contrast = newValue }
            }

            slider(
                "Saturation", value: clip.grade.saturation, range: 0...2,
                format: { String(format: "%.2f", $0) }
            ) { newValue in
                applyGrade(from: clip) { $0.saturation = newValue }
            }

            slider(
                "Warmth", value: clip.grade.temperature, range: -1...1,
                format: { String(format: "%+.2f", $0) }
            ) { newValue in
                applyGrade(from: clip) { $0.temperature = newValue }
            }

            Button("Reset colour") {
                applyGrade(from: clip) { $0 = .neutral }
                Haptics.snap()
            }
            .foregroundStyle(Theme.Palette.accent)
        } header: {
            Text("Colour")
        }
    }

    private func motionSection(_ clip: VideoClip) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fit")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                HStack(spacing: Theme.Space.s) {
                    ForEach(FitMode.allCases, id: \.self) { mode in
                        Chip(title: mode.displayName, systemImage: mode == .fill ? "rectangle.fill" : "rectangle.inset.filled", isSelected: clip.fitMode == mode) {
                            perform(from: clip) { target in
                                .setClipFit(id: target.id, fitMode: mode, wasFitMode: target.fitMode)
                            }
                            Haptics.snap()
                        }
                    }
                    Chip(title: "Smart crop", systemImage: "person.crop.rectangle") {
                        smartCrop(from: clip)
                    }
                }
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Movement")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                HStack(spacing: Theme.Space.s) {
                    movementButton("Static", "rectangle", clip: clip, start: .full, end: .full)
                    movementButton(
                        "Push in", "arrow.down.right.and.arrow.up.left",
                        clip: clip, start: .full, end: NormalizedRect.full.scaled(by: 0.85)
                    )
                    movementButton(
                        "Pull out", "arrow.up.left.and.arrow.down.right",
                        clip: clip, start: NormalizedRect.full.scaled(by: 0.85), end: .full
                    )
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Framing")
        } footer: {
            Text("Fill crops to the canvas; Fit shows the whole picture with bars. Smart crop re-centres the crop on the subject Reframe found in the photo. Movement is the slow drift applied to stills.")
        }
    }

    /// Re-solves the crop window around the asset's detected subject, keeping the current zoom.
    private func smartCrop(from clip: VideoClip) {
        let targets = applyToAll ? document.timeline.clips : [clip]
        let subjects = model.subjectRects
        for target in targets {
            guard let assetID = target.assetID, let asset = model.assets[assetID] else { continue }
            let window = RecipeBinder.fillWindow(
                sourceAspect: asset.aspectRatio, targetAspect: document.timeline.canvas.aspectRatio,
                subject: subjects[assetID], referenceSubject: nil,
                framing: Confident(.medium, confidence: 0, basis: "manual")
            )
            let zoom = target.cropEnd.width / max(0.01, target.cropStart.width)
            let end = zoom < 1 ? window.scaled(by: max(0.62, zoom)).clampedInsideUnitSquare() : window
            document.perform(.setClipCrop(id: target.id, start: window, end: end, wasStart: target.cropStart, wasEnd: target.cropEnd))
        }
        Haptics.snap()
    }

    private func audioSection(_ clip: VideoClip) -> some View {
        Section {
            slider(
                "Clip volume", value: clip.volume, range: 0...1,
                format: { "\(Int($0 * 100))%" }
            ) { newValue in
                perform(from: clip) { target in
                    .setClipVolume(id: target.id, volume: newValue, wasVolume: target.volume)
                }
            }
        } header: {
            Text("Sound")
        } footer: {
            // Explains the muted-by-default behaviour rather than leaving it a mystery.
            Text("Video clips start muted so the music bed is clean. Raise this to hear the clip's own audio.")
        }
    }

    // MARK: - Controls

    private func slider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
            .tint(Theme.Palette.accent)
        }
        .padding(.vertical, 2)
    }

    private func movementButton(
        _ title: String, _ symbol: String,
        clip: VideoClip, start: NormalizedRect, end: NormalizedRect
    ) -> some View {
        let isActive = abs(clip.cropStart.width - start.width) < 0.02
            && abs(clip.cropEnd.width - end.width) < 0.02

        return Button {
            perform(from: clip) { target in
                .setClipCrop(
                    id: target.id, start: start, end: end,
                    wasStart: target.cropStart, wasEnd: target.cropEnd
                )
            }
            Haptics.snap()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(isActive ? .white : Theme.Palette.primaryText)
            .background(
                isActive ? Theme.Palette.accent : Theme.Palette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Applying

    /// Fans a change out to one clip or all of them, depending on the scope toggle.
    private func perform(
        from clip: VideoClip,
        _ build: (VideoClip) -> EditCommand
    ) {
        let targets = applyToAll ? document.timeline.clips : [clip]
        for target in targets {
            document.perform(build(target))
        }
    }

    private func applyGrade(from clip: VideoClip, _ mutate: (inout ColorGrade) -> Void) {
        let targets = applyToAll ? document.timeline.clips : [clip]
        for target in targets {
            var grade = target.grade
            mutate(&grade)
            document.perform(
                .setClipGrade(id: target.id, grade: grade, wasGrade: target.grade)
            )
        }
    }

    private func applyEffects(from clip: VideoClip, vignette: Double, grain: Double) {
        let targets = applyToAll ? document.timeline.clips : [clip]
        for target in targets {
            document.perform(
                .setClipEffects(
                    id: target.id, vignette: vignette, grain: grain,
                    wasVignette: target.vignette, wasGrain: target.grain
                )
            )
        }
    }

    /// A preset is two commands, so grade and effects stay independently undoable.
    private func apply(_ preset: FilterPreset, from clip: VideoClip) {
        let targets = applyToAll ? document.timeline.clips : [clip]
        for target in targets {
            document.perform(
                .setClipGrade(id: target.id, grade: preset.grade, wasGrade: target.grade)
            )
            document.perform(
                .setClipEffects(
                    id: target.id, vignette: preset.vignette, grain: preset.grain,
                    wasVignette: target.vignette, wasGrain: target.grain
                )
            )
        }
        Haptics.snap()
    }
}

/// A filter swatch previewing roughly what the grade does, without needing a rendered thumbnail.
private struct FilterChip: View {
    let preset: FilterPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(swatch)
                    .frame(width: 56, height: 56)
                    .overlay {
                        if preset.vignette > 0.1 {
                            RadialGradient(
                                colors: [.clear, .black.opacity(preset.vignette * 0.7)],
                                center: .center, startRadius: 12, endRadius: 40
                            )
                            .clipShape(
                                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            )
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(
                                isActive ? Theme.Palette.accent : .white.opacity(0.12),
                                lineWidth: isActive ? 3 : 1
                            )
                    }
                Text(preset.name)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isActive ? Theme.Palette.accent : Theme.Palette.secondaryText)
            }
        }
        .buttonStyle(.plain)
    }

    /// Approximates the preset by pushing a mid-tone through the same maths the shader uses,
    /// so the chip and the result agree without rendering anything.
    private var swatch: Color {
        var r = 0.62, g = 0.55, b = 0.52
        let grade = preset.grade

        let exposure = pow(2.0, grade.exposure)
        r *= exposure; g *= exposure; b *= exposure
        r = (r - 0.5) * grade.contrast + 0.5
        g = (g - 0.5) * grade.contrast + 0.5
        b = (b - 0.5) * grade.contrast + 0.5
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r = luma + (r - luma) * grade.saturation
        g = luma + (g - luma) * grade.saturation
        b = luma + (b - luma) * grade.saturation
        r += grade.temperature * 0.06
        b -= grade.temperature * 0.06

        return Color(
            red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1)
        )
    }
}
