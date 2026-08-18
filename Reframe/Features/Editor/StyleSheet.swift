import ReframeKit
import SwiftUI

/// Per-clip look and motion — previously unreachable.
///
/// The Style button switched a highlight and rendered nothing, so colour, speed, volume and
/// framing were all locked at bind time despite the commands for them existing and being
/// covered by tests. Everything routes through `EditCommand`, so it all undoes.
struct StyleSheet: View {
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
                        scopeSection(clip)
                        colourSection(clip)
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
            slider(
                "Speed", value: clip.speed, range: 0.25...4,
                format: { String(format: "%.2fx", $0) }
            ) { newValue in
                perform(from: clip) { target in
                    .setClipSpeed(id: target.id, speed: newValue, wasSpeed: target.speed)
                }
            }

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
            Text("Motion")
        } footer: {
            Text("Speed affects video clips. Movement is the slow drift applied to stills.")
        }
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
}
