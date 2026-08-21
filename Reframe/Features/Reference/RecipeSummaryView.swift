import ReframeKit
import SwiftUI

/// "Reference understood" — and the two decisions that follow from it: how closely to follow
/// the reference, and what to do about its soundtrack.
///
/// Everything the analyser was unsure about carries a Guessed badge that explains itself. That
/// is the difference between an app that feels honest and one that feels like a magic trick you
/// cannot argue with.
struct RecipeSummaryView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedSceneID: String?
    @State private var isExtracting = false
    @State private var extractedForShare: URL?

    var body: some View {
        if let recipe = model.recipe {
            content(recipe)
        } else {
            EmptyStateView(
                systemImage: "questionmark.folder",
                title: "No style loaded",
                message: "Something went wrong reading the reference.",
                actionTitle: "Start over",
                action: { model.returnHome() }
            )
        }
    }

    private func content(_ recipe: EditRecipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                understood(recipe)
                modeSection
                if recipe.source.hasAudio { audioSection(recipe) }
                if let grid = recipe.beatGrid { beatSection(grid, recipe: recipe) }
                sceneList(recipe)
                if !recipe.fillableTextSlots.isEmpty { textSlots(recipe) }
                confidenceNote(recipe)
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .background(Theme.Palette.background)
        .navigationTitle("The style")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            FlowProgress(step: 1, total: 4, title: "Choose how to use it")
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: model.fidelity.displayName, systemImage: "arrow.right") {
                model.path.append(.contentImport)
            }
            .padding(Theme.Space.m)
            .background(.regularMaterial)
        }
        .sheet(item: $extractedForShare) { url in
            ShareSheet(items: [url])
        }
    }

    // MARK: - Hero

    private func understood(_ recipe: EditRecipe) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Palette.success)
                Text("REFERENCE UNDERSTOOD")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Text(recipe.stats.pacingDescription)
                .font(Theme.Font.displayTitle)

            let grid = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: grid, spacing: Theme.Space.s) {
                Fact(value: String(format: "%.1fs", recipe.duration), label: "duration")
                Fact(value: "\(recipe.stats.sceneCount)", label: recipe.stats.sceneCount == 1 ? "scene" : "scenes")
                Fact(value: recipe.source.aspect.displayName, label: "format")
                // A tempo the analyser wasn't reasonably sure about is a guess from ambient
                // noise, not a fact about the video — the rhythm section below carries the
                // badge and the basis; this grid only states what's solid.
                Fact(
                    value: recipe.beatGrid.flatMap {
                        $0.bpm.confidence >= ConfidenceBand.fallbackThreshold ? "\(Int($0.bpm.value.rounded()))" : nil
                    } ?? "—",
                    label: "BPM"
                )
                Fact(value: "\(recipe.stats.textSlotCount)", label: "text layers")
                Fact(value: "\(recipe.scenes.filter { $0.move.effectiveKind != .none }.count)", label: "camera moves")
                Fact(value: "\(recipe.stats.transitionCount)", label: "transitions")
                Fact(value: recipe.audio.hasSpeech.value ? "Yes" : "No", label: "speech")
                Fact(value: "\(Int(recipe.source.fps.rounded()))", label: "fps")
            }
        }
        .padding(Theme.Space.l)
        .heroSurface()
    }

    private struct Fact: View {
        let value: String
        let label: String
        var body: some View {
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label.uppercased())
                    .font(Theme.Font.metricLabel)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("How closely to follow it", subtitle: "You can change anything afterwards in the editor.")
            ForEach(BindingFidelity.allCases) { mode in
                ChoiceCard(
                    title: mode.displayName,
                    detail: mode.summary,
                    systemImage: icon(for: mode),
                    isSelected: model.fidelity == mode,
                    badge: mode == .closeMatch ? "RECOMMENDED" : nil
                ) {
                    withAnimation(Theme.Motion.quick) { model.fidelity = mode }
                    Haptics.snap()
                }
            }
        }
    }

    private func icon(for mode: BindingFidelity) -> String {
        switch mode {
        case .closeMatch: return "scope"
        case .styleOnly: return "paintbrush.pointed"
        case .structureOnly: return "rectangle.split.3x1"
        }
    }

    // MARK: - Audio

    private func audioSection(_ recipe: EditRecipe) -> some View {
        let extracted = model.content.referenceAudioAssetID.flatMap { model.assets[$0] }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Reference audio", subtitle: recipe.audio.hasSpeech.value
                ? "This reference has speech. You can keep its soundtrack, add your own, or both."
                : "This reference has music. Bring your own track, or keep the original.")

            VStack(spacing: Theme.Space.s) {
                ChoiceCard(
                    title: "Use my own audio",
                    detail: "Add music or record a voiceover on the next screen. Nothing from the reference is used.",
                    systemImage: "music.note.list",
                    isSelected: extracted == nil
                ) {
                    if let id = model.content.referenceAudioAssetID {
                        model.content.referenceAudioAssetID = nil
                        model.assets.remove(id: id)
                    }
                    Haptics.snap()
                }
                ChoiceCard(
                    title: extracted == nil ? "Keep the reference's audio" : "Keeping the reference's audio",
                    detail: extracted == nil
                        ? "Extract its soundtrack and place it under your video. Only do this if you have the rights to use it."
                        : "\(String(format: "%.0f", extracted!.duration))s extracted. Mix it with your own tracks in the editor.",
                    systemImage: "waveform",
                    isSelected: extracted != nil
                ) {
                    guard extracted == nil else { return }
                    Task {
                        isExtracting = true
                        if let asset = await model.extractReferenceAudio() {
                            model.content.referenceAudioAssetID = asset.id
                        }
                        isExtracting = false
                    }
                }
            }

            HStack(spacing: Theme.Space.m) {
                Button {
                    Task {
                        isExtracting = true
                        if let asset = await model.extractReferenceAudio(),
                           case .sandboxRelativePath(let path) = asset.origin {
                            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            extractedForShare = documents.appendingPathComponent(path)
                        }
                        isExtracting = false
                    }
                } label: {
                    Label(isExtracting ? "Extracting…" : "Save audio to Files", systemImage: "square.and.arrow.down")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .disabled(isExtracting)
                Spacer()
                if isExtracting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Theme.Space.xs)
        }
    }

    // MARK: - Beat

    private func beatSection(_ grid: BeatGrid, recipe: EditRecipe) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Rhythm").font(Theme.Font.sectionTitle)
                GuessedBadge(confidence: grid.bpm.confidence, basis: grid.bpm.basis)
            }
            HStack(spacing: Theme.Space.m) {
                Text("\(Int(grid.bpm.value.rounded())) BPM")
                    .font(Theme.Font.metric)
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(grid.cutsAlignedToBeats.value ? "Cuts land on the beat" : "Cuts follow their own timing")
                        .font(Theme.Font.callout)
                    Text(grid.cutsAlignedToBeats.basis)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .cardSurface()
        }
    }

    // MARK: - Scenes & text

    private func sceneList(_ recipe: EditRecipe) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Scene by scene").font(Theme.Font.sectionTitle)
            VStack(spacing: 0) {
                ForEach(recipe.scenes) { scene in
                    SceneSummaryRow(
                        scene: scene,
                        isExpanded: expandedSceneID == scene.id,
                        onTap: {
                            withAnimation(Theme.Motion.quick) {
                                expandedSceneID = expandedSceneID == scene.id ? nil : scene.id
                            }
                        }
                    )
                    if scene.id != recipe.scenes.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .cardSurface()
        }
    }

    private func textSlots(_ recipe: EditRecipe) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Text layers", subtitle: model.fidelity == .closeMatch
                ? "You'll fill these with your own words on the next screen."
                : "Not used in this mode — add your own text freely in the editor.")
            VStack(spacing: Theme.Space.s) {
                ForEach(recipe.fillableTextSlots) { slot in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: "textformat")
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: Theme.Space.xs) {
                                Text(slot.role.displayName)
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                GuessedBadge(confidence: slot.style.category.confidence, basis: slot.style.category.basis)
                            }
                            Text("\(slot.style.category.value.displayName) · \(slot.animation.effectiveEntry.displayName.lowercased()) · \(String(format: "%.1f–%.1fs", slot.start, slot.end))")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            if let sample = slot.sampleText {
                                // A hint, never content. See RecipeBinder.buildTextLayers.
                                Text("reference said: \(sample) (\(slot.charCountHint) chars)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                                    .italic()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.m)
                    .cardSurface()
                    .opacity(model.fidelity == .closeMatch ? 1 : 0.55)
                }
            }
        }
    }

    private func confidenceNote(_ recipe: EditRecipe) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "info.circle").foregroundStyle(Theme.Palette.tertiaryText)
            Text("Overall confidence \(Int(recipe.confidence.overall * 100))%. Least certain: \(recipe.confidence.weakest). Anything marked *Guessed* is an inference — tap it to see why, and change it in the editor if it's wrong.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.s)
    }
}

private struct SceneSummaryRow: View {
    let scene: SceneTemplate
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button(action: onTap) {
                HStack(spacing: Theme.Space.m) {
                    Text("\(scene.index + 1)")
                        .font(.system(.footnote, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(scene.role.value.displayName)
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(Theme.Palette.primaryText)
                            if scene.move.effectiveKind != .none {
                                Text("·").foregroundStyle(Theme.Palette.tertiaryText)
                                Text(scene.move.effectiveKind.displayName)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                        Text("\(scene.slot.framing.value.displayName) · \(String(format: "%.2fs", scene.duration))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                    GuessedBadge(confidence: scene.move.kind.confidence, basis: scene.move.kind.basis)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.vertical, Theme.Space.s)
                .padding(.horizontal, Theme.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Starts", String(format: "%.2fs", scene.start))
                    if let transition = scene.transitionIn {
                        detail("Enters on", "\(transition.effectiveKind.displayName)\(transition.effectiveDuration > 0 ? String(format: " (%.2fs)", transition.effectiveDuration) : "")")
                    }
                    detail("Camera", scene.move.effectiveKind.displayName)
                    if let subject = scene.slot.subjectRect {
                        detail("Subject", String(format: "at (%.0f%%, %.0f%%), %.0f%% of frame", subject.value.centerX * 100, subject.value.centerY * 100, subject.value.area * 100))
                    }
                    detail("Reference used", scene.sourceKind == .video ? "video" : "a still")
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.leading, 40)
                .padding(.bottom, Theme.Space.s)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.Palette.tertiaryText)
            Text(value).font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
        }
    }
}
