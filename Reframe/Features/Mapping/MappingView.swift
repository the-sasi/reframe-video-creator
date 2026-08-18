import Photos
import ReframeKit
import SwiftUI

/// The screen that makes the automatic choices legible.
///
/// Reference → template → your content, one row per scene, with the actual reason for each
/// assignment. A surprising choice becomes arguable rather than mysterious, and every one is
/// one tap from being overridden.
///
/// The reference column describes the shot rather than showing a frame of it: the reference's
/// pixels are released the moment analysis finishes and never enter the project. What is being
/// reused is the *structure*, and the column shows exactly that.
struct MappingView: View {
    @Environment(AppModel.self) private var model
    @State private var swapTarget: SceneTemplate?
    @State private var shuffleSeed = 0
    @State private var isArranging = false
    @State private var isCreating = false

    var body: some View {
        Group {
            if let recipe = model.recipe {
                content(recipe)
            } else {
                EmptyStateView(
                    systemImage: "square.dashed",
                    title: "No style loaded",
                    message: "Go back and pick a reference first."
                )
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Arrange")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            FlowProgress(step: 3, total: 4, title: "Arrange your content")
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(.bar)
        }
        .sheet(item: $swapTarget) { scene in
            SwapSheet(scene: scene)
        }
    }

    private func content(_ recipe: EditRecipe) -> some View {
        ScrollView {
            VStack(spacing: Theme.Space.s) {
                if shortfall > 0 { shortfallBanner(recipe) }
                header

                ForEach(recipe.scenes) { scene in
                    MappingRow(
                        scene: scene,
                        assetID: model.assignment[scene.slot.id],
                        asset: model.assignment[scene.slot.id].flatMap { model.assets[$0] },
                        reason: model.assignment.reasonBySlot[scene.slot.id],
                        isLocked: model.assignment.isLocked(scene.slot.id),
                        onTap: { swapTarget = scene },
                        onToggleLock: {
                            model.setSlotLocked(!model.assignment.isLocked(scene.slot.id), slotID: scene.slot.id)
                            Haptics.snap()
                        }
                    )
                }
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.s) {
                PrimaryButton(title: "Create Video", systemImage: "sparkles", isBusy: isCreating) {
                    Task {
                        isCreating = true
                        await model.createVideoAndEdit()
                        isCreating = false
                    }
                }
                HStack(spacing: Theme.Space.l) {
                    Button {
                        Task {
                            isArranging = true
                            await model.autoArrange(shuffleSeed: 0)
                            isArranging = false
                            Haptics.snap()
                        }
                    } label: {
                        Label("Auto Arrange", systemImage: "wand.and.rays")
                    }
                    Button {
                        shuffleSeed += 1
                        Task {
                            isArranging = true
                            await model.autoArrange(shuffleSeed: shuffleSeed)
                            isArranging = false
                            Haptics.snap()
                        }
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            if isArranging { ProgressView().controlSize(.small) } else { Image(systemName: "shuffle") }
                            Text("Shuffle")
                        }
                    }
                    if !model.assignment.lockedSlots.isEmpty {
                        Button {
                            for slot in model.assignment.lockedSlots { model.setSlotLocked(false, slotID: slot) }
                        } label: {
                            Label("Unpin all", systemImage: "pin.slash")
                        }
                    }
                }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.Palette.secondaryText)
                .disabled(isArranging)
            }
            .padding(Theme.Space.m)
            .background(.regularMaterial)
        }
    }

    /// How many slots more than we have distinct assets to fill them with.
    private var shortfall: Int {
        guard let recipe = model.recipe else { return 0 }
        return max(0, recipe.assetSlotCount - model.assets.visuals.count)
    }

    /// The template is longer than the material given to it.
    ///
    /// Reusing photos is a reasonable fallback and the solver already picks the *best* ones to
    /// repeat — but doing it silently is not. Saying so, with the exact number and a one-tap
    /// route back to add more, is the honest version.
    private func shortfallBanner(_ recipe: EditRecipe) -> some View {
        Button {
            model.path.removeLast()
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.Palette.warning)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(shortfall) more would fill every slot")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("This style has \(recipe.assetSlotCount) slots and you've added \(model.assets.visuals.count). Reframe is repeating \(shortfall == 1 ? "one" : "some") of them — tap to add more photos or clips.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
            .padding(Theme.Space.m)
            .background(
                Theme.Palette.warning.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .pressable()
    }

    private var header: some View {
        HStack {
            Text("REFERENCE")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("YOURS")
                .frame(width: 92, alignment: .center)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.Palette.tertiaryText)
        .padding(.horizontal, Theme.Space.s)
    }
}

private struct MappingRow: View {
    let scene: SceneTemplate
    let assetID: UUID?
    let asset: AssetReference?
    let reason: String?
    let isLocked: Bool
    let onTap: () -> Void
    let onToggleLock: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.m) {
                // Reference / template description.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.xs) {
                        Text("\(scene.index + 1)")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.Palette.onAccent)
                            .frame(width: 18, height: 18)
                            .background(Theme.Palette.accent.opacity(0.85), in: Circle())

                        Text(scene.role.value.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                    }

                    Text(descriptor)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)

                    if let reason {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiaryText)

                // Assigned asset.
                VStack(spacing: 4) {
                    if let asset {
                        MappedThumbnail(asset: asset)
                            .overlay(alignment: .topTrailing) {
                                Button(action: onToggleLock) {
                                    Image(systemName: isLocked ? "pin.fill" : "pin")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(isLocked ? .white : .white.opacity(0.85))
                                        .padding(5)
                                        .background(isLocked ? Theme.Palette.accent : .black.opacity(0.45), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .accessibilityLabel(isLocked ? "Unpin" : "Pin this photo to this scene")
                            }
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Theme.Palette.surfaceRaised)
                            .frame(width: 62, height: 82)
                            .overlay {
                                Image(systemName: "plus")
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                            }
                    }
                    Text(asset?.displayName ?? "Choose")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .lineLimit(1)
                }
                .frame(width: 80)
            }
            .padding(Theme.Space.m)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Scene \(scene.index + 1), \(scene.role.value.displayName), \(descriptor). Assigned \(asset?.displayName ?? "nothing"). Double tap to change."
        )
    }

    private var descriptor: String {
        var parts = [scene.slot.framing.value.displayName.lowercased()]
        if scene.move.effectiveKind != .none {
            parts.append(scene.move.effectiveKind.displayName.lowercased())
        }
        parts.append(String(format: "%.1fs", scene.duration))
        return parts.joined(separator: " · ")
    }
}

private struct MappedThumbnail: View {
    let asset: AssetReference

    var body: some View {
        AssetThumbnailView(asset: asset, size: CGSize(width: 62, height: 82))
            .frame(width: 62, height: 82)
    }
}

/// Ranked alternatives for one slot, using the same cost function as the solver — so the
/// sheet's order agrees with the automatic choice instead of contradicting it.
private struct SwapSheet: View {
    let scene: SceneTemplate
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(ranked, id: \.asset.id) { entry in
                        Button {
                            model.assignment[scene.slot.id] = entry.asset.id
                            // A hand-picked photo is a decision: pin it so Shuffle respects it.
                            model.setSlotLocked(true, slotID: scene.slot.id)
                            model.assignment.reasonBySlot[scene.slot.id] = "chosen by you"
                            Haptics.snap()
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                AssetThumbnailView(asset: entry.asset, size: CGSize(width: 88, height: 118))
                                    .frame(width: 88, height: 118)
                                    .overlay {
                                        if model.assignment[scene.slot.id] == entry.asset.id {
                                            RoundedRectangle(
                                                cornerRadius: Theme.Radius.small, style: .continuous
                                            )
                                            .strokeBorder(Theme.Palette.accent, lineWidth: 3)
                                        }
                                    }
                                Text(entry.reason)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Space.m)
            }
            .navigationTitle("Scene \(scene.index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.setSlotLocked(!model.assignment.isLocked(scene.slot.id), slotID: scene.slot.id)
                        Haptics.snap()
                    } label: {
                        Image(systemName: model.assignment.isLocked(scene.slot.id) ? "pin.fill" : "pin")
                    }
                    .accessibilityLabel("Pin this choice")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var ranked: [(asset: AssetReference, reason: String)] {
        guard let recipe = model.recipe else { return [] }
        return AssetMapper().ranking(
            for: scene,
            canvas: recipe.canvas,
            assets: model.assets,
            features: model.assetFeatures
        )
    }
}
