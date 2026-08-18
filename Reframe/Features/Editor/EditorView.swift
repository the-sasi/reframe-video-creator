import AVFoundation
import PhotosUI
import ReframeKit
import SwiftUI

/// The editor.
///
/// Preview on top, timeline under it, and a toolbar that shows *only what applies to what is
/// selected*: nothing selected offers ways to add; a clip offers clip tools; text offers text
/// tools; audio offers audio tools. Nothing is nested more than two levels, and every control
/// goes through an `EditCommand`, so everything undoes.
struct EditorView: View {
    @Environment(AppModel.self) private var model

    @State private var engine: PreviewEngine?
    @State private var selection: EditorSelection?
    @State private var currentTime: Double = 0
    @State private var toast: String?
    @State private var waveforms: [UUID: Waveform] = [:]

    // Sheets
    @State private var sheet: EditorSheet?
    @State private var replacementItem: PhotosPickerItem?
    @State private var addItems: [PhotosPickerItem] = []
    @State private var confirmDelete = false

    enum EditorSheet: Identifiable {
        case text, audio, style, transition, speed, replace, canvas, captions, saveTemplate, variations
        var id: Int { hashValue }
    }

    var body: some View {
        Group {
            if let engine, let document = model.document {
                editor(engine: engine, document: document)
            } else {
                ProgressView("Preparing editor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Palette.background)
            }
        }
        .navigationTitle(model.projectTitle ?? model.recipe?.title ?? "Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await prepareEngine() }
        .onAppear { model.markEditorOpen() }
        .onDisappear {
            engine?.pause()
            let snapshotEngine = engine
            Task {
                let poster = await snapshotEngine?.snapshot(at: min(1.0, (snapshotEngine?.duration ?? 0) * 0.3))
                await model.saveProject(thumbnail: poster)
                await model.flushAutosave()
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, Theme.Space.s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Layout

    private func editor(engine: PreviewEngine, document: TimelineDocument) -> some View {
        VStack(spacing: 0) {
            PreviewPane(
                engine: engine,
                document: document,
                currentTime: currentTime,
                selectedTextID: Binding(
                    get: { selection?.textID },
                    set: { selection = $0.map { .text($0) } }
                )
            )
            .frame(maxHeight: .infinity)

            TimelineView(
                timeline: document.timeline,
                assets: model.assets,
                beatGrid: model.activeBeatGrid,
                waveforms: waveforms,
                currentTime: currentTime,
                selection: selection,
                isPlaying: engine.isPlaying,
                actions: TimelineActions(
                    onScrub: { time in
                        currentTime = time
                        engine.scrub(to: time)
                    },
                    onScrubEnd: { engine.endScrub() },
                    onSelect: { selection = $0 },
                    perform: { document.perform($0) },
                    beginGesture: { document.beginGesture(key: $0) },
                    endGesture: { document.endGesture() }
                )
            )
            .frame(height: TimelineView.preferredHeight(for: document.timeline))
            .background(Theme.Palette.surface.opacity(0.5))

            contextualToolbar(document: document, engine: engine)
            bottomTabs
        }
        .background(Theme.Palette.background)
        .onChange(of: engine.currentTime) { _, new in
            if engine.isPlaying { currentTime = new }
        }
        .onChange(of: document.revision) { _, _ in
            engine.timeline = document.timeline
            model.noteEdit()
            // Selection may point at something that no longer exists.
            if let selection, !exists(selection, in: document.timeline) { self.selection = nil }
        }
        .onChange(of: model.assets) { _, pool in
            engine.updateAssets(pool)
            Task { await loadWaveforms(pool) }
        }
        .task(id: model.assets.audioTracks.count) { await loadWaveforms(model.assets) }
        .onChange(of: replacementItem) { _, item in
            guard let item, let clipID = selection?.clipID else { return }
            Task { await replaceAsset(of: clipID, with: item, document: document) }
        }
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addClips(items, document: document) }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .text:
                TextSheet(document: document, currentTime: currentTime, selectedID: selection?.textID)
            case .audio:
                AudioSheet(document: document, currentTime: currentTime, selectedID: selection?.audioID)
            case .style:
                StyleSheet(document: document, selectedClipID: selection?.clipID)
            case .transition:
                TransitionSheet(document: document, clipID: selection?.clipID)
            case .speed:
                SpeedSheet(document: document, clipID: selection?.clipID)
            case .replace:
                ReplaceSheet(document: document, clipID: selection?.clipID)
            case .canvas:
                CanvasSheet(document: document)
            case .captions:
                CaptionsSheet(document: document)
            case .saveTemplate:
                SaveTemplateSheet()
            case .variations:
                VariationsSheet(document: document)
            }
        }
        .confirmationDialog("Delete this?", isPresented: $confirmDelete, titleVisibility: .hidden) {
            Button("Delete", role: .destructive) { deleteSelection(document: document) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Contextual toolbar

    @ViewBuilder
    private func contextualToolbar(document: TimelineDocument, engine: PreviewEngine) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                switch selection {
                case .clip(let id):
                    if let clip = document.timeline.clip(id: id) {
                        clipTools(clip: clip, document: document)
                    }
                case .text(let id):
                    if let layer = document.timeline.textLayers.first(where: { $0.id == id }) {
                        textTools(layer: layer, document: document)
                    }
                case .audio(let id):
                    if let clip = document.timeline.audio.first(where: { $0.id == id }) {
                        audioTools(clip: clip, document: document)
                    }
                case nil:
                    addTools(document: document)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.Palette.surface)
        .animation(Theme.Motion.quick, value: selection)
    }

    @ViewBuilder
    private func addTools(document: TimelineDocument) -> some View {
        PhotosPicker(selection: $addItems, maxSelectionCount: 20, selectionBehavior: .ordered,
                     matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
            ToolLabel(title: "Add media", systemImage: "photo.badge.plus")
        }
        .buttonStyle(.plain)
        ToolButton(title: "Add text", systemImage: "textformat") { addTextLayer(document: document) }
        ToolButton(title: "Audio", systemImage: "music.note") { sheet = .audio }
        ToolButton(title: "Captions", systemImage: "captions.bubble") { sheet = .captions }
        ToolButton(title: "Canvas", systemImage: "aspectratio") { sheet = .canvas }
        ToolButton(title: "Look", systemImage: "camera.filters") { sheet = .style }
        ToolButton(title: "Variations", systemImage: "wand.and.sparkles") { sheet = .variations }
        ToolButton(title: "Save style", systemImage: "square.and.arrow.down.on.square", isEnabled: model.recipe != nil) { sheet = .saveTemplate }
    }

    @ViewBuilder
    private func clipTools(clip: VideoClip, document: TimelineDocument) -> some View {
        ToolButton(title: "Split", systemImage: "scissors") { split(clip: clip, document: document) }
        ToolButton(title: "Replace", systemImage: "arrow.triangle.2.circlepath") { sheet = .replace }
        ToolButton(title: "Transition", systemImage: "arrow.left.arrow.right", isActive: (clip.transitionIn?.kind ?? .cut) != .cut) { sheet = .transition }
        ToolButton(title: "Framing", systemImage: "crop") { sheet = .style }
        ToolButton(title: "Speed", systemImage: "gauge.with.dots.needle.67percent",
                   isActive: abs(clip.speed - 1) > 0.01,
                   isEnabled: clip.assetID.flatMap { model.assets[$0] }?.kind == .video) { sheet = .speed }
        ToolButton(title: "Adjust", systemImage: "slider.horizontal.3", isActive: !clip.grade.isNeutral || clip.vignette > 0 || clip.grain > 0) { sheet = .style }
        ToolButton(title: clip.volume > 0.001 ? "Volume" : "Muted",
                   systemImage: clip.volume > 0.001 ? "speaker.wave.2" : "speaker.slash",
                   isEnabled: clip.assetID.flatMap { model.assets[$0] }?.kind == .video) {
            let newVolume = clip.volume > 0.001 ? 0.0 : 0.8
            document.perform(.setClipVolume(id: clip.id, volume: newVolume, wasVolume: clip.volume))
            showToast(newVolume > 0 ? "Clip audio on" : "Clip audio muted")
        }
        ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") {
            var copy = clip
            copy.id = UUID()
            copy.transitionIn = nil
            guard let index = document.timeline.clipIndex(id: clip.id) else { return }
            document.perform(.insertClip(index: index + 1, clip: copy))
        }
        ToolButton(title: "Delete", systemImage: "trash", isDestructive: true) { confirmDelete = true }
    }

    @ViewBuilder
    private func textTools(layer: TextLayer, document: TimelineDocument) -> some View {
        ToolButton(title: "Edit", systemImage: "character.cursor.ibeam") { sheet = .text }
        ToolButton(title: "Style", systemImage: "paintbrush") { sheet = .text }
        ToolButton(title: "Start here", systemImage: "arrow.right.to.line") {
            let length = layer.duration
            let start = min(max(0, currentTime), max(0, document.timeline.duration - 0.3))
            document.perform(.setTextTiming(id: layer.id, start: start, end: start + length, wasStart: layer.start, wasEnd: layer.end))
        }
        ToolButton(title: "End here", systemImage: "arrow.left.to.line") {
            let end = max(layer.start + 0.3, currentTime)
            document.perform(.setTextTiming(id: layer.id, start: layer.start, end: end, wasStart: layer.start, wasEnd: layer.end))
        }
        ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") {
            var copy = layer
            copy.id = UUID()
            copy.slotID = nil
            copy.frame.y = min(0.9, layer.frame.y + 0.05)
            document.perform(.addTextLayer(layer: copy))
        }
        ToolButton(title: "Delete", systemImage: "trash", isDestructive: true) { confirmDelete = true }
    }

    @ViewBuilder
    private func audioTools(clip: AudioClip, document: TimelineDocument) -> some View {
        ToolButton(title: "Levels", systemImage: "slider.horizontal.3") { sheet = .audio }
        ToolButton(title: clip.isMuted ? "Unmute" : "Mute", systemImage: clip.isMuted ? "speaker.slash" : "speaker.wave.2", isActive: clip.isMuted) {
            document.perform(.setAudioMuted(id: clip.id, isMuted: !clip.isMuted, wasMuted: clip.isMuted))
        }
        ToolButton(title: "Start here", systemImage: "arrow.right.to.line") {
            document.perform(.retimeAudioClip(id: clip.id, start: max(0, currentTime), duration: clip.duration, sourceStart: clip.sourceStart,
                                              wasStart: clip.start, wasDuration: clip.duration, wasSourceStart: clip.sourceStart))
        }
        ToolButton(title: "Split", systemImage: "scissors") {
            let local = currentTime - clip.start
            guard local > 0.2, local < clip.duration - 0.2 else { Haptics.warning(); return }
            var tail = clip
            tail.id = UUID()
            tail.start = clip.start + local
            tail.duration = clip.duration - local
            tail.sourceStart = clip.sourceStart + local
            tail.fadeIn = 0
            document.perform(.retimeAudioClip(id: clip.id, start: clip.start, duration: local, sourceStart: clip.sourceStart,
                                              wasStart: clip.start, wasDuration: clip.duration, wasSourceStart: clip.sourceStart))
            document.perform(.addAudioClip(clip: tail))
        }
        ToolButton(title: "Delete", systemImage: "trash", isDestructive: true) { confirmDelete = true }
    }

    private var bottomTabs: some View {
        HStack(spacing: 0) {
            tab("Text", "textformat") { sheet = .text }
            tab("Audio", "music.note") { sheet = .audio }
            tab("Look", "wand.and.rays") { sheet = .style }
            tab("Export", "square.and.arrow.up") { model.path.append(.export) }
        }
        .background(.regularMaterial)
    }

    private func tab(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 17, weight: .regular))
                Text(title).font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(title == "Export" ? Theme.Palette.accent : Theme.Palette.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                guard let name = model.document?.undo() else { return }
                showToast("Undid \(name)")
                Haptics.grab()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!(model.document?.canUndo ?? false))
            .accessibilityLabel("Undo \(model.document?.undoName ?? "")")

            Button {
                guard let name = model.document?.redo() else { return }
                showToast("Redid \(name)")
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!(model.document?.canRedo ?? false))
            .accessibilityLabel("Redo")
        }
    }

    // MARK: - Actions

    private func exists(_ selection: EditorSelection, in timeline: Timeline) -> Bool {
        switch selection {
        case .clip(let id): return timeline.clip(id: id) != nil
        case .text(let id): return timeline.textLayers.contains { $0.id == id }
        case .audio(let id): return timeline.audio.contains { $0.id == id }
        }
    }

    private func split(clip: VideoClip, document: TimelineDocument) {
        let localTime = currentTime - clip.start
        // Refuse a split that would produce a sub-frame sliver — that is a mis-tap, not an edit.
        guard localTime > 0.1, localTime < clip.duration - 0.1 else {
            showToast("Move the playhead inside the clip to split")
            Haptics.warning()
            return
        }
        document.perform(
            .splitClip(id: clip.id, atLocalTime: localTime, newClipID: UUID(),
                       wasDuration: clip.duration, wasCropEnd: clip.cropEnd)
        )
        Haptics.grab()
    }

    private func deleteSelection(document: TimelineDocument) {
        switch selection {
        case .clip(let id):
            guard let index = document.timeline.clipIndex(id: id) else { return }
            document.perform(.deleteClip(index: index, clip: document.timeline.clips[index]))
        case .text(let id):
            guard let index = document.timeline.textLayers.firstIndex(where: { $0.id == id }) else { return }
            document.perform(.deleteTextLayer(index: index, layer: document.timeline.textLayers[index]))
        case .audio(let id):
            guard let index = document.timeline.audio.firstIndex(where: { $0.id == id }) else { return }
            document.perform(.deleteAudioClip(index: index, clip: document.timeline.audio[index]))
        case nil:
            return
        }
        selection = nil
        Haptics.grab()
    }

    private func addTextLayer(document: TimelineDocument) {
        let duration = document.timeline.duration
        let start = min(max(0, currentTime), max(0, duration - 1.0))
        let isFirst = document.timeline.textLayers.isEmpty
        let layer = TextLayer(
            text: "Your text",
            role: isFirst ? .title : .caption,
            start: start,
            end: min(max(duration, start + 1), start + 2.5),
            frame: NormalizedRect(x: 0.08, y: isFirst ? 0.16 : 0.7, width: 0.84, height: 0.14),
            alignment: .center,
            weight: .heavy,
            sizeRatio: isFirst ? 0.062 : 0.044
        )
        document.perform(.addTextLayer(layer: layer))
        selection = .text(layer.id)
        sheet = .text
        Haptics.grab()
    }

    private func replaceAsset(of clipID: UUID, with item: PhotosPickerItem, document: TimelineDocument) async {
        guard let reference = await MediaImport.reference(from: item) else {
            model.present(.unsupportedFormat(detail: "unreadable Photos item"))
            return
        }
        model.assets.add(reference)
        guard let clip = document.timeline.clip(id: clipID) else { return }
        document.perform(.replaceClipAsset(id: clipID, assetID: reference.id, wasAssetID: clip.assetID))
        replacementItem = nil
        await model.extractMissingFeatures()
        showToast("Replaced")
    }

    private func addClips(_ items: [PhotosPickerItem], document: TimelineDocument) async {
        var index = document.timeline.clips.count
        if let selectedID = selection?.clipID, let i = document.timeline.clipIndex(id: selectedID) { index = i + 1 }
        for item in items {
            guard let reference = await MediaImport.reference(from: item) else { continue }
            model.assets.add(reference)
            let isVideo = reference.kind == .video
            let clip = VideoClip(
                assetID: reference.id,
                start: 0,
                duration: isVideo && reference.duration > 0 ? min(reference.duration, 4) : 2,
                cropStart: .full,
                cropEnd: isVideo ? .full : NormalizedRect.full.scaled(by: 0.9),
                transitionIn: index == 0 ? nil : ClipTransition(kind: .cut, duration: 0),
                volume: 0
            )
            document.perform(.insertClip(index: index, clip: clip))
            index += 1
        }
        addItems.removeAll()
        await model.extractMissingFeatures()
    }

    private func loadWaveforms(_ pool: AssetPool) async {
        for track in pool.audioTracks where waveforms[track.id] == nil {
            guard let resolved = await model.resolver.resolve(track), let asset = resolved.asset,
                  let waveform = try? await WaveformSampler.sample(asset: asset) else { continue }
            waveforms[track.id] = waveform
        }
    }

    private func showToast(_ message: String) {
        withAnimation(Theme.Motion.quick) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.Motion.quick) { toast = nil }
        }
    }

    private func prepareEngine() async {
        guard engine == nil,
              let renderer = model.renderer,
              let document = model.document else {
            if model.renderer == nil { model.present(.metalUnavailable) }
            return
        }
        let engine = PreviewEngine(
            renderer: renderer,
            resolver: model.resolver,
            timeline: document.timeline,
            assets: model.assets
        )
        self.engine = engine
    }
}

/// A `ToolButton` look for things that must be labels (PhotosPicker).
struct ToolLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 17)).frame(height: 22)
            Text(title).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.primaryText)
        .frame(width: 64, height: 56)
        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}
