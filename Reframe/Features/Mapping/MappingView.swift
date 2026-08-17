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
        .sheet(item: $swapTarget) { scene in
            SwapSheet(scene: scene)
        }
    }

    private func content(_ recipe: EditRecipe) -> some View {
        ScrollView {
            VStack(spacing: Theme.Space.s) {
                header

                ForEach(recipe.scenes) { scene in
                    MappingRow(
                        scene: scene,
                        assetID: model.assignment[scene.slot.id],
                        asset: model.assignment[scene.slot.id].flatMap { model.assets[$0] },
                        reason: model.assignment.reasonBySlot[scene.slot.id],
                        onTap: { swapTarget = scene }
                    )
                }
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.s) {
                PrimaryButton(title: "Looks Good", systemImage: "arrow.right") {
                    model.bindTimeline()
                    model.path.append(.generate)
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
                        if isArranging {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "shuffle")
                        }
                        Text("Shuffle")
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.Palette.secondaryText)
                }
                .minimumHitTarget()
                .disabled(isArranging)
            }
            .padding(Theme.Space.m)
            .background(.regularMaterial)
        }
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.m) {
                // Reference / template description.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.xs) {
                        Text("\(scene.index + 1)")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
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
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.Palette.surfaceRaised)
            .frame(width: 62, height: 82)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .task { await load() }
    }

    private func load() async {
        guard image == nil, case .photoLibrary(let identifier) = asset.origin else { return }
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast

        image = await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: phAsset, targetSize: CGSize(width: 160, height: 220),
                contentMode: .aspectFill, options: options
            ) { result, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
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
                            model.assignment.reasonBySlot[scene.slot.id] = "chosen by you"
                            Haptics.snap()
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                MappedThumbnail(asset: entry.asset)
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
