import Photos
import ReframeKit
import SwiftUI

/// Drag-to-reorder for the asset pool.
///
/// A `List` with `.onMove` rather than a draggable grid: reordering twenty-plus items by
/// dragging around a four-column grid on a phone is genuinely unpleasant, and the system list
/// gives free autoscroll, haptics and accessibility.
///
/// Order matters even though Auto Arrange scores every asset against every slot — it is the
/// tie-breaker when scores are close, and it is what "Shuffle" perturbs.
struct ReorderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.assets.visuals) { asset in
                        HStack(spacing: Theme.Space.m) {
                            AssetThumbnailView(asset: asset, size: CGSize(width: 44, height: 58))
                                .frame(width: 44, height: 58)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(asset.displayName)
                                    .font(Theme.Font.callout)
                                    .lineLimit(1)
                                Text(
                                    asset.kind == .video
                                        ? String(format: "video · %.0fs", asset.duration)
                                        : "\(asset.pixelWidth)×\(asset.pixelHeight)"
                                )
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            }
                            Spacer()
                        }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                } footer: {
                    Text("Drag to reorder, swipe to remove. Order breaks ties when Auto Arrange scores two photos equally.")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// `assets.assets` holds audio and the logo too, so indices from the visuals-only list have
    /// to be mapped back before moving anything.
    private func move(from source: IndexSet, to destination: Int) {
        var visuals = model.assets.visuals
        visuals.move(fromOffsets: source, toOffset: destination)

        let others = model.assets.assets.filter { $0.kind == .audio }
        let logoID = model.content.logoAssetID
        let logo = model.assets.assets.filter { $0.id == logoID && $0.kind != .audio }

        var rebuilt = visuals
        rebuilt.append(contentsOf: logo.filter { asset in !visuals.contains { $0.id == asset.id } })
        rebuilt.append(contentsOf: others)

        model.assets = AssetPool(assets: rebuilt)
        Haptics.snap()
    }

    private func delete(at offsets: IndexSet) {
        let visuals = model.assets.visuals
        for index in offsets where index < visuals.count {
            let asset = visuals[index]
            model.assets.remove(id: asset.id)
            model.assetFeatures.removeValue(forKey: asset.id)
        }
    }
}
