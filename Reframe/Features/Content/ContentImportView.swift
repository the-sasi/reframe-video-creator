import Photos
import PhotosUI
import ReframeKit
import SwiftUI

/// Photos in, words in. Two sections, no ceremony.
///
/// The slot count from the recipe drives the prompt ("12 slots — add about 12 photos"), and the
/// reference's character count drives the placeholder, so copy gets written to fit the layout
/// rather than being truncated later.
struct ContentImportView: View {
    @Environment(AppModel.self) private var model

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var logoItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var isPreparing = false

    private var slotCount: Int { model.recipe?.assetSlotCount ?? 0 }
    private var hasEnoughAssets: Bool { !model.assets.visuals.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                photosSection
                if let recipe = model.recipe, !recipe.fillableTextSlots.isEmpty {
                    textSection(recipe)
                }
                extrasSection
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Your content")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(
                title: "Auto Arrange",
                systemImage: "wand.and.rays",
                isEnabled: hasEnoughAssets,
                isBusy: isPreparing
            ) {
                Task { await arrange() }
            }
            .padding(Theme.Space.m)
            .background(.regularMaterial)
        }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { await loadLogo(item) }
        }
    }

    // MARK: - Photos

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Photos & video").font(Theme.Font.sectionTitle)
                Spacer()
                if slotCount > 0 {
                    Text("\(model.assets.visuals.count) / \(slotCount)")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(
                            model.assets.visuals.count >= slotCount
                                ? Theme.Palette.success
                                : Theme.Palette.secondaryText
                        )
                }
            }

            if slotCount > 0 {
                Text(guidance)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }

            if model.assets.visuals.isEmpty {
                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: 40,
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images, .videos])
                ) {
                    EmptyStateView(
                        systemImage: "photo.stack",
                        title: "Add your photos",
                        message: slotCount > 0
                            ? "This style has \(slotCount) slots. Pick around that many."
                            : "Pick the photos and clips you want in the video."
                    )
                    .cardSurface()
                }
                .disabled(isLoading)
            } else {
                assetGrid
            }
        }
    }

    private var guidance: String {
        let have = model.assets.visuals.count
        if have == 0 { return "Pick around \(slotCount) photos — you can add more later." }
        if have < slotCount {
            return "\(slotCount - have) more would fill every slot. Reframe can repeat photos, but it looks better with more."
        }
        if have > slotCount {
            return "More than enough — Reframe will pick the \(slotCount) that fit best."
        }
        return "Exactly right."
    }

    private var assetGrid: some View {
        VStack(spacing: Theme.Space.s) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                spacing: 6
            ) {
                ForEach(model.assets.visuals) { asset in
                    AssetThumbnail(asset: asset)
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                model.assets.remove(id: asset.id)
                                model.assetFeatures.removeValue(forKey: asset.id)
                            }
                        }
                }
            }

            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 40,
                selectionBehavior: .ordered,
                matching: .any(of: [.images, .videos])
            ) {
                Label("Add more", systemImage: "plus")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Theme.Palette.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    )
            }
            .disabled(isLoading)
        }
    }

    // MARK: - Text

    private func textSection(_ recipe: EditRecipe) -> some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Words").font(Theme.Font.sectionTitle)
            Text("Leave anything blank and that layer simply won't appear.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)

            VStack(spacing: Theme.Space.s) {
                ForEach(recipe.fillableTextSlots) { slot in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(slot.role.displayName)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Spacer()
                            if slot.charCountHint > 0 {
                                Text("~\(slot.charCountHint) chars fits")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                            }
                        }

                        TextField(
                            slot.role.prompt,
                            text: Binding(
                                get: { model.content.textBySlot[slot.id] ?? "" },
                                set: { model.content.textBySlot[slot.id] = $0 }
                            )
                        )
                        .font(Theme.Font.body)
                        .textInputAutocapitalization(
                            slot.role == .cta ? .characters : .sentences
                        )
                        .padding(Theme.Space.m)
                        .background(
                            Theme.Palette.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Extras

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Optional").font(Theme.Font.sectionTitle)

            PhotosPicker(selection: $logoItem, matching: .images) {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "seal")
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 24)
                    Text(model.content.logoAssetID == nil ? "Add a logo" : "Logo added")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Spacer()
                    if model.content.logoAssetID != nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.Palette.success)
                    }
                }
                .padding(Theme.Space.m)
                .cardSurface()
            }

            if model.recipe?.audio.hasMusic == true {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "music.note")
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .frame(width: 24)
                    Text("The reference is cut to music. Add your own track in the editor and the cuts will line up — Reframe never uses the reference's audio.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
                .background(
                    Theme.Palette.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
            }
        }
    }

    // MARK: - Loading

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoading = true
        defer { isLoading = false }

        for item in items {
            guard let identifier = item.itemIdentifier else { continue }
            guard !model.assets.assets.contains(where: {
                $0.origin == .photoLibrary(localIdentifier: identifier)
            }) else { continue }
            guard let reference = Self.reference(forLocalIdentifier: identifier) else { continue }
            model.assets.add(reference)
        }
        photoItems.removeAll()
    }

    private func loadLogo(_ item: PhotosPickerItem) async {
        guard let identifier = item.itemIdentifier,
              let reference = Self.reference(forLocalIdentifier: identifier) else { return }
        model.assets.add(reference)
        model.content.logoAssetID = reference.id
        logoItem = nil
    }

    /// Builds an `AssetReference` from a Photos identifier. Reads dimensions from `PHAsset`
    /// rather than by decoding, so adding 40 photos costs no image decoding at all.
    private static func reference(forLocalIdentifier identifier: String) -> AssetReference? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let phAsset = fetch.firstObject else { return nil }

        let kind: AssetKind
        switch phAsset.mediaType {
        case .image: kind = .image
        case .video: kind = .video
        case .audio: kind = .audio
        default: return nil
        }

        return AssetReference(
            kind: kind,
            origin: .photoLibrary(localIdentifier: identifier),
            displayName: phAsset.value(forKey: "filename") as? String ?? "Photo",
            pixelWidth: phAsset.pixelWidth,
            pixelHeight: phAsset.pixelHeight,
            duration: phAsset.duration,
            creationDate: phAsset.creationDate
        )
    }

    private func arrange() async {
        isPreparing = true
        defer { isPreparing = false }

        await model.autoArrange()
        model.bindTimeline()
        model.path.append(.mapping)
    }
}

private struct AssetThumbnail: View {
    let asset: AssetReference
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.Palette.surfaceRaised)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if asset.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(3)
                }
            }
            .task { await load() }
            .accessibilityLabel(asset.displayName)
    }

    private func load() async {
        guard image == nil, case .photoLibrary(let identifier) = asset.origin else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let phAsset = fetch.firstObject else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        image = await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: options
            ) { result, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
    }
}
