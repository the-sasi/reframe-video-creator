import ReframeKit
import SwiftUI

/// "Here's what I found" — and one button.
///
/// Everything the analyser was unsure about carries a Guessed badge that explains itself. That
/// is the difference between an app that feels honest and one that feels like a magic trick you
/// cannot argue with.
struct RecipeSummaryView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedSceneID: String?

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
                headline(recipe)
                metrics(recipe)

                if let grid = recipe.beatGrid {
                    beatSection(grid, recipe: recipe)
                }

                sceneList(recipe)

                if !recipe.fillableTextSlots.isEmpty {
                    textSlots(recipe)
                }

                confidenceNote(recipe)
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .background(Theme.Palette.background)
        .navigationTitle("The style")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Use This Style", systemImage: "checkmark") {
                model.path.append(.contentImport)
            }
            .padding(Theme.Space.m)
            .background(.regularMaterial)
        }
    }

    private func headline(_ recipe: EditRecipe) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(recipe.stats.pacingDescription)
                .font(Theme.Font.screenTitle)
            Text("\(recipe.stats.sceneCount) slots to fill · \(recipe.source.aspect.displayName) · \(String(format: "%.1f", recipe.duration))s")
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    private func metrics(_ recipe: EditRecipe) -> some View {
        HStack(spacing: 0) {
            MetricTile(
                value: "\(recipe.stats.sceneCount)",
                label: "scenes", systemImage: "rectangle.stack"
            )
            Divider().frame(height: 34)
            MetricTile(
                value: "\(recipe.stats.transitionCount)",
                label: "transitions", systemImage: "arrow.left.arrow.right"
            )
            Divider().frame(height: 34)
            MetricTile(
                value: "\(recipe.stats.textSlotCount)",
                label: "text layers", systemImage: "textformat"
            )
            Divider().frame(height: 34)
            MetricTile(
                value: String(format: "%.1fs", recipe.stats.medianSceneDuration),
                label: "median cut", systemImage: "scissors"
            )
        }
        .cardSurface()
    }

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
                    Text(
                        grid.cutsAlignedToBeats.value
                            ? "Cuts land on the beat"
                            : "Cuts follow their own timing"
                    )
                    .font(Theme.Font.callout)
                    Text(grid.cutsAlignedToBeats.basis)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .cardSurface()

            if grid.cutsAlignedToBeats.value {
                Text("Your video will cut on the beat too — bring your own music and it'll line up.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

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
            Text("Text layers").font(Theme.Font.sectionTitle)

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
                                GuessedBadge(
                                    confidence: slot.style.category.confidence,
                                    basis: slot.style.category.basis
                                )
                            }

                            Text("\(slot.style.category.value.displayName) · \(slot.animation.effectiveEntry.displayName.lowercased()) · \(String(format: "%.1f–%.1fs", slot.start, slot.end))")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)

                            // A hint, never content. Shown so the user can size their own copy
                            // to the layout; it is structurally impossible for this to reach the
                            // output — see RecipeBinder.buildTextLayers.
                            if let sample = slot.sampleText {
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
                }
            }
        }
    }

    private func confidenceNote(_ recipe: EditRecipe) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.Palette.tertiaryText)
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

                    GuessedBadge(
                        confidence: scene.move.kind.confidence,
                        basis: scene.move.kind.basis
                    )

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
                        detail(
                            "Enters on",
                            "\(transition.effectiveKind.displayName)\(transition.effectiveDuration > 0 ? String(format: " (%.2fs)", transition.effectiveDuration) : "")"
                        )
                    }
                    detail("Camera", scene.move.effectiveKind.displayName)
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
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
            Text(value)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }
}
