import AVFoundation
import ImageIO
import Photos
import PhotosUI
import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// Photos and clips in, words in. Two sections, no ceremony.
///
/// The slot count from the recipe drives the prompt ("12 slots — add about 12"), and the
/// reference's character count drives the placeholder, so copy gets written to fit the layout
/// rather than being truncated later.
struct ContentImportView: View {
    @Environment(AppModel.self) private var model

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var logoItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var isPreparing = false
    @State private var isImportingMusic = false
    @State private var showsReorder = false
    @State private var authorization: PHAuthorizationStatus = .notDetermined
    @State private var lastImportNote: String?

    private var slotCount: Int { model.recipe?.assetSlotCount ?? 0 }
    private var hasEnoughAssets: Bool { !model.assets.visuals.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if authorization == .denied || authorization == .restricted {
                    permissionBanner
                }
                mediaSection
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
                title: model.recipe == nil ? "Create Video" : "Auto Arrange",
                systemImage: model.recipe == nil ? "sparkles" : "wand.and.rays",
                isEnabled: hasEnoughAssets,
                isBusy: isPreparing
            ) {
                Task { await arrange() }
            }
            .padding(Theme.Space.m)
            .background(.regularMaterial)
        }
        .task {
            // `photoLibrary: .shared()` below needs real authorisation, otherwise every picked
            // item comes back without an identifier and silently vanishes.
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            DiagnosticsLog.shared.info("content", "photo authorisation: \(authorization.rawValue)")
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { await loadLogo(item) }
        }
        .sheet(isPresented: $showsReorder) {
            ReorderSheet()
        }
    }

    // MARK: - Permission

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.Palette.warning)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Photos access is off")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                Text("Reframe can't read the photos you pick. Nothing is ever uploaded — everything stays on this iPhone.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(
            Theme.Palette.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        )
    }

    // MARK: - Media

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Photos & videos").font(Theme.Font.sectionTitle)
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

            if let lastImportNote {
                Text(lastImportNote)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }

            if model.assets.visuals.isEmpty {
                picker {
                    EmptyStateView(
                        systemImage: "photo.stack",
                        title: "Add photos or videos",
                        message: slotCount > 0
                            ? "This style has \(slotCount) slots. Pick around that many — photos, clips, or a mix."
                            : "Pick the photos and clips you want in the video."
                    )
                    .cardSurface()
                }
            } else {
                assetGrid
            }
        }
    }

    /// One picker definition, used in both the empty and populated states.
    ///
    /// `photoLibrary: .shared()` is the important part: without it the picker runs
    /// out-of-process, `itemIdentifier` is nil for every result, and items are dropped without
    /// any visible error.
    private func picker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(
            selection: $photoItems,
            maxSelectionCount: 40,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared(),
            label: label
        )
        .disabled(isLoading)
    }

    private var guidance: String {
        let have = model.assets.visuals.count
        if have == 0 { return "Pick around \(slotCount) — you can add more later." }
        if have < slotCount {
            return "\(slotCount - have) more would fill every slot. Reframe can repeat items, but it looks better with more."
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

            picker {
                Label(isLoading ? "Adding…" : "Add more", systemImage: isLoading ? "hourglass" : "plus")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Theme.Palette.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    )
            }
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
                        .textInputAutocapitalization(slot.role == .cta ? .characters : .sentences)
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
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Optional").font(Theme.Font.sectionTitle)

            if let palette = model.recipe?.palette, !palette.dominant.isEmpty {
                Toggle(isOn: $model.matchReferenceLook) {
                    HStack(spacing: Theme.Space.m) {
                        HStack(spacing: -6) {
                            ForEach(palette.dominant.prefix(3), id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 22, height: 22)
                                    .overlay { Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Match the reference's look")
                                .font(Theme.Font.body)
                            Text("Applies the colour tone from the original video to your photos.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.m)
                .cardSurface()
            }

            if model.assets.visuals.count > 1 {
                Button {
                    showsReorder = true
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Reorder")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("Auto Arrange picks the best fit, but order still matters")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .padding(Theme.Space.m)
                    .cardSurface()
                }
                .buttonStyle(.plain)
            }

            PhotosPicker(
                selection: $logoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
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

            musicRow

            if model.recipe?.audio.hasMusic == true, model.content.musicAssetID == nil {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 24)
                    Text("The reference is cut to music at \(Int(model.recipe?.beatGrid?.bpm.value.rounded() ?? 0)) BPM. Add your own track and the cuts will land on its beat — Reframe never uses the reference's audio.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
                .background(
                    Theme.Palette.accentSoft,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
            }
        }
        .fileImporter(
            isPresented: $isImportingMusic,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await importMusic(from: url) }
        }
    }

    private var musicRow: some View {
        Group {
            if let id = model.content.musicAssetID, let track = model.assets[id] {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "music.note")
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.displayName)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .lineLimit(1)
                        Text(String(format: "%.0f seconds", track.duration))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer()
                    Button {
                        model.content.musicAssetID = nil
                        model.assets.remove(id: id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Space.m)
                .cardSurface()
            } else {
                Button {
                    isImportingMusic = true
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "music.note")
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add music")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("From Files — an MP3, M4A or WAV you own")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .padding(Theme.Space.m)
                    .cardSurface()
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Copies the chosen track into the sandbox.
    ///
    /// Copying rather than referencing, for two reasons: the security-scoped URL from Files
    /// expires, and preview playback needs a stable local path. Music files are small enough
    /// that the copy is not worth avoiding, unlike photos.
    private func importMusic(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/audio-\(UUID().uuidString).\(url.pathExtension)"
        let destination = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
            DiagnosticsLog.shared.failure("content", "could not copy audio \(url.lastPathComponent)")
            lastImportNote = "Couldn't read that audio file."
            return
        }

        let asset = AVURLAsset(url: destination)
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        // DRM-protected tracks (anything from Apple Music) copy fine but have no readable
        // audio track, so catch that here rather than at export time.
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        guard duration > 0, hasAudio else {
            try? FileManager.default.removeItem(at: destination)
            DiagnosticsLog.shared.warning("content", "audio unreadable or DRM-protected: \(url.lastPathComponent)")
            lastImportNote = "That track is protected and can't be used. Apple Music downloads won't work — try a file you own."
            return
        }

        let reference = AssetReference(
            kind: .audio,
            origin: .sandboxRelativePath(relative),
            displayName: url.deletingPathExtension().lastPathComponent,
            pixelWidth: 0,
            pixelHeight: 0,
            duration: duration
        )
        model.assets.add(reference)
        model.content.musicAssetID = reference.id
        lastImportNote = nil
        DiagnosticsLog.shared.info(
            "content", "music added: \(reference.displayName), \(String(format: "%.1fs", duration))"
        )
    }

    // MARK: - Import

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        isLoading = true
        lastImportNote = nil
        defer { isLoading = false }

        var added = 0
        var copied = 0
        var failed = 0

        for item in items {
            // Preferred path: reference the library asset by identifier, copying nothing.
            if let identifier = item.itemIdentifier,
               let reference = Self.libraryReference(for: identifier) {
                if !model.assets.assets.contains(where: { $0.origin == reference.origin }) {
                    model.assets.add(reference)
                    added += 1
                }
                continue
            }

            // Fallback: no identifier — Limited Library access, an iCloud-only item, or a
            // picker that declined to hand one over. Copy the file into the sandbox instead so
            // the import still succeeds rather than silently dropping the item.
            if let reference = await Self.copiedReference(from: item) {
                model.assets.add(reference)
                copied += 1
            } else {
                failed += 1
            }
        }

        photoItems.removeAll()

        DiagnosticsLog.shared.info(
            "content",
            "import: \(added) referenced, \(copied) copied, \(failed) failed (of \(items.count))"
        )

        if failed > 0 {
            lastImportNote = "\(failed) item\(failed == 1 ? "" : "s") couldn't be read — they may still be downloading from iCloud."
        }
    }

    private func loadLogo(_ item: PhotosPickerItem) async {
        let reference: AssetReference?
        if let identifier = item.itemIdentifier {
            reference = Self.libraryReference(for: identifier)
        } else {
            reference = await Self.copiedReference(from: item)
        }
        guard let reference else { return }
        model.assets.add(reference)
        model.content.logoAssetID = reference.id
        logoItem = nil
    }

    /// Builds a reference from a Photos identifier, reading dimensions from `PHAsset` rather
    /// than by decoding — so adding 40 items costs no image decoding at all.
    private static func libraryReference(for identifier: String) -> AssetReference? {
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
            displayName: (phAsset.value(forKey: "filename") as? String) ?? "Item",
            pixelWidth: phAsset.pixelWidth,
            pixelHeight: phAsset.pixelHeight,
            duration: phAsset.duration,
            creationDate: phAsset.creationDate
        )
    }

    /// Copies a picked item into the sandbox and measures it. Slower and uses disk, which is
    /// why it is the fallback rather than the default.
    private static func copiedReference(from item: PhotosPickerItem) async -> AssetReference? {
        guard let media = try? await item.loadTransferable(type: PickedMedia.self) else {
            return nil
        }

        let isVideo = media.url.pathExtension.lowercased() != "jpg"
            && ["mov", "mp4", "m4v"].contains(media.url.pathExtension.lowercased())

        var width = 0
        var height = 0
        var duration = 0.0

        if isVideo {
            let asset = AVURLAsset(url: media.url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let presented = size.applying(transform)
                width = Int(abs(presented.width).rounded())
                height = Int(abs(presented.height).rounded())
            }
            duration = (try? await asset.load(.duration).seconds) ?? 0
        } else if let source = CGImageSourceCreateWithURL(media.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }

        guard width > 0, height > 0 else { return nil }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/\(media.url.lastPathComponent)"
        let destination = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: media.url, to: destination)) != nil else {
            return nil
        }

        return AssetReference(
            kind: isVideo ? .video : .image,
            origin: .sandboxRelativePath(relative),
            displayName: media.url.lastPathComponent,
            pixelWidth: width,
            pixelHeight: height,
            duration: duration
        )
    }

    private func arrange() async {
        isPreparing = true
        defer { isPreparing = false }

        // No recipe means "Start From Scratch". There are no slots to map assets into, so skip
        // straight to a default timeline and the editor rather than walking into a mapping
        // screen with nothing to show.
        guard model.recipe != nil else {
            DiagnosticsLog.shared.info(
                "content", "scratch build from \(model.assets.visuals.count) assets"
            )
            model.buildScratchTimeline()
            model.path.append(.editor)
            return
        }

        DiagnosticsLog.shared.info(
            "content",
            "arranging \(model.assets.visuals.count) assets into \(slotCount) slots"
        )
        await model.autoArrange()
        model.bindTimeline()
        model.path.append(.mapping)
    }
}

/// Carries a picked photo or video out of the picker as a file we control.
///
/// Both representations are declared because `.any(of: [.images, .videos])` can hand back
/// either, and a movie has no useful `Data` representation at 4K.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { media in
            SentTransferredFile(media.url)
        } importing: { received in
            PickedMedia(url: try Self.stage(received.file, fallbackExtension: "mov"))
        }

        FileRepresentation(contentType: .image) { media in
            SentTransferredFile(media.url)
        } importing: { received in
            PickedMedia(url: try Self.stage(received.file, fallbackExtension: "jpg"))
        }
    }

    /// The picker deletes its temporary file the moment the transfer completes, so it has to be
    /// moved somewhere we own before anything else touches it.
    private static func stage(_ file: URL, fallbackExtension: String) throws -> URL {
        let ext = file.pathExtension.isEmpty ? fallbackExtension : file.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
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
                    Image(uiImage: image).resizable().scaledToFill()
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
        guard image == nil else { return }

        switch asset.origin {
        case .photoLibrary(let identifier):
            image = await Self.libraryThumbnail(identifier)
        case .sandboxRelativePath(let path):
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            image = Self.fileThumbnail(documents.appendingPathComponent(path), isVideo: asset.kind == .video)
        case .fileBookmark:
            image = nil
        }
    }

    private static func libraryThumbnail(_ identifier: String) async -> UIImage? {
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
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

    private static func fileThumbnail(_ url: URL, isVideo: Bool) -> UIImage? {
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 200,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
              ) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
