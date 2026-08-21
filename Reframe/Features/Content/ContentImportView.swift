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
    @State private var showsVoiceover = false
    @State private var authorization: PHAuthorizationStatus = .notDetermined
    @State private var lastImportNote: String?

    private var slotCount: Int { model.recipe?.assetSlotCount ?? 0 }
    private var hasEnoughAssets: Bool { !model.assets.visuals.isEmpty }
    /// Flow B cannot generate without an analysed track.
    private var canContinue: Bool {
        guard hasEnoughAssets else { return false }
        if model.wantsMusicEdit && model.recipe == nil {
            return model.musicProfile != nil && !model.isAnalyzingMusic
        }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if authorization == .denied || authorization == .restricted {
                    permissionBanner
                }
                mediaSection
                if let recipe = model.recipe, !recipe.fillableTextSlots.isEmpty, model.fidelity == .closeMatch {
                    textSection(recipe)
                }
                audioSection
                extrasSection
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Your content")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) {
            FlowProgress(
                step: model.recipe == nil ? 1 : 2,
                total: model.recipe == nil ? 2 : 4,
                title: "Add photos, videos, words and sound"
            )
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(
                title: model.wantsMusicEdit && model.recipe == nil
                    ? "Create to Music"
                    : (model.recipe == nil ? "Create Video" : "Auto Arrange"),
                systemImage: model.recipe == nil ? "sparkles" : "wand.and.rays",
                isEnabled: canContinue,
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
        .sheet(isPresented: $showsVoiceover) {
            VoiceoverSheet { reference in
                model.content.voiceoverAssetID = reference.id
            }
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
                    AssetThumbnailView(asset: asset, size: CGSize(width: 90, height: 90))
                        .aspectRatio(1, contentMode: .fit)
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

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Sound", subtitle: "Music, a voiceover, or both. Everything can be re-mixed in the editor.")

            musicRow
            voiceRow
            if let referenceID = model.content.referenceAudioAssetID, let track = model.assets[referenceID] {
                audioRow(
                    systemImage: "waveform", title: "Reference audio", subtitle: track.displayName,
                    detail: String(format: "%.0f seconds · kept from the reference", track.duration)
                ) {
                    model.content.referenceAudioAssetID = nil
                    model.assets.remove(id: referenceID)
                }
            }

            if model.assets.visuals.contains(where: { $0.kind == .video }) {
                Toggle(
                    isOn: Binding(
                        get: { model.content.clipAudioVolume > 0 },
                        set: { model.content.clipAudioVolume = $0 ? 0.8 : 0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep sound from my clips").font(Theme.Font.body)
                        Text("Your videos' own audio plays under the music. Off keeps the bed clean.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.m)
                .cardSurface()
            }

            if model.recipe?.audio.hasMusic == true, model.content.musicAssetID == nil, model.content.referenceAudioAssetID == nil {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 24)
                    Text("The reference is cut to music at \(Int(model.recipe?.beatGrid?.bpm.value.rounded() ?? 0)) BPM. Add a track at a similar tempo and the cuts will feel tightest.")
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

    // MARK: - Extras

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Optional").font(Theme.Font.sectionTitle)

            if let palette = model.recipe?.palette, !palette.dominant.isEmpty, model.recipe?.isBuiltIn != true {
                Toggle(
                    isOn: Binding(
                        get: { model.matchReferenceLook },
                        set: { model.matchReferenceLook = $0 }
                    )
                ) {
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
                            Text("Auto Arrange picks the best fit, but order breaks ties")
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
        }
    }

    private var musicRow: some View {
        Group {
            if let id = model.content.musicAssetID, let track = model.assets[id] {
                audioRow(
                    systemImage: "music.note", title: "Music", subtitle: track.displayName,
                    detail: model.isAnalyzingMusic
                        ? "Finding the beat…"
                        : (model.musicBeatGrid.map { String(format: "%.0f seconds · %.0f BPM — cuts will land on its beat", track.duration, $0.bpm.value) }
                            ?? String(format: "%.0f seconds", track.duration))
                ) {
                    model.content.musicAssetID = nil
                    model.musicBeatGrid = nil
                    model.assets.remove(id: id)
                }
            } else {
                addRow(systemImage: "music.note", title: "Add music", subtitle: "From Files — an MP3, M4A, AAC or WAV you own") {
                    isImportingMusic = true
                }
            }
        }
    }

    private var voiceRow: some View {
        Group {
            if let id = model.content.voiceoverAssetID, let track = model.assets[id] {
                audioRow(
                    systemImage: "mic", title: "Voiceover", subtitle: track.displayName,
                    detail: String(format: "%.0f seconds · music dips under it automatically", track.duration)
                ) {
                    model.content.voiceoverAssetID = nil
                    model.assets.remove(id: id)
                }
            } else {
                addRow(systemImage: "mic", title: "Record a voiceover", subtitle: "Music dips under your voice automatically") {
                    showsVoiceover = true
                }
            }
        }
    }

    private func audioRow(
        systemImage: String, title: String, subtitle: String, detail: String, onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondaryText)
                Text(subtitle)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }

    private func addRow(systemImage: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(subtitle)
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

    /// Copies the chosen track into the sandbox and validates it.
    private func importMusic(from url: URL) async {
        let (reference, note) = await MediaImport.importAudio(from: url)
        guard let reference else {
            lastImportNote = note
            return
        }
        model.assets.add(reference)
        model.content.musicAssetID = reference.id
        lastImportNote = nil
        await model.analyzeMusic(reference)
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
               let reference = MediaImport.libraryReference(for: identifier) {
                if !model.assets.assets.contains(where: { $0.origin == reference.origin }) {
                    model.assets.add(reference)
                    added += 1
                }
                continue
            }

            // Fallback: no identifier — copy the file into the sandbox instead so the import
            // still succeeds rather than silently dropping the item.
            if let reference = await MediaImport.copiedReference(from: item) {
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
        guard let reference = await MediaImport.reference(from: item) else { return }
        model.assets.add(reference)
        model.content.logoAssetID = reference.id
        logoItem = nil
    }

    private func arrange() async {
        isPreparing = true
        defer { isPreparing = false }

        // No recipe means "Start From Scratch". There are no slots to map assets into, so skip
        // straight to a default timeline and the editor rather than walking into a mapping
        // screen with nothing to show.
        if model.recipe == nil {
            // Flow B: plan the recipe from the analysed track, then continue like any other
            // recipe-driven flow — mapping screen, editor, the lot.
            if model.wantsMusicEdit {
                guard model.generateMusicRecipe() else {
                    DiagnosticsLog.shared.warning("music-edit", "generate requested with no analysed track")
                    return
                }
            } else {
                DiagnosticsLog.shared.info(
                    "content", "scratch build from \(model.assets.visuals.count) assets"
                )
                await model.createVideoAndEdit()
                return
            }
        }

        DiagnosticsLog.shared.info(
            "content",
            "arranging \(model.assets.visuals.count) assets into \(slotCount) slots"
        )
        await model.arrangeAndBind()
        model.path.append(.mapping)
    }
}
