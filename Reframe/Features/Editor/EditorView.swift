import ReframeKit
import SwiftUI

/// The editor.
///
/// Five bottom-bar items, because that set covers the overwhelming majority of real edits.
/// Nothing is nested more than two levels, and the contextual row for a clip does not exist
/// until a clip is selected — progressive disclosure as a structural property rather than a
/// setting.
struct EditorView: View {
    @Environment(AppModel.self) private var model

    @State private var engine: PreviewEngine?
    @State private var selectedClipID: UUID?
    @State private var activeTool: Tool = .edit
    @State private var currentTime: Double = 0
    @State private var undoToast: String?
    @State private var showsAudioSheet = false

    enum Tool: String, CaseIterable, Identifiable {
        case edit, text, audio, style, export
        var id: String { rawValue }

        var title: String {
            switch self {
            case .edit: return "Edit"
            case .text: return "Text"
            case .audio: return "Audio"
            case .style: return "Style"
            case .export: return "Export"
            }
        }

        var systemImage: String {
            switch self {
            case .edit: return "scissors"
            case .text: return "textformat"
            case .audio: return "music.note"
            case .style: return "wand.and.rays"
            case .export: return "square.and.arrow.up"
            }
        }
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
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await prepareEngine() }
        .onDisappear {
            engine?.pause()
            Task { await model.saveProject() }
        }
        .overlay(alignment: .top) {
            if let undoToast {
                Text(undoToast)
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
            PreviewPane(engine: engine)
                .frame(maxHeight: .infinity)

            TimelineView(
                timeline: document.timeline,
                beatGrid: model.recipe?.beatGrid,
                currentTime: $currentTime,
                selectedClipID: $selectedClipID,
                isPlaying: engine.isPlaying,
                onScrub: { time in
                    currentTime = time
                    engine.scrub(to: time)
                },
                onScrubEnd: { engine.endScrub() },
                onSelect: { selectedClipID = $0 }
            )
            .frame(height: 116)
            .background(Theme.Palette.surface.opacity(0.5))

            contextualRow(document: document)

            toolbar
        }
        .background(Theme.Palette.background)
        .onChange(of: engine.currentTime) { _, new in
            if engine.isPlaying { currentTime = new }
        }
        .onChange(of: document.revision) { _, _ in
            engine.timeline = document.timeline
            // The pool may have gained a track since the engine was built; without this the
            // preview stays silent after adding music.
            engine.currentAssetPool = model.assets
            engine.updateAssets(model.assets)
        }
        .sheet(isPresented: $showsAudioSheet) {
            AudioSheet(document: document)
        }
    }

    @ViewBuilder
    private func contextualRow(document: TimelineDocument) -> some View {
        if let clipID = selectedClipID, let clip = document.timeline.clip(id: clipID) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ClipAction(title: "Split", systemImage: "scissors") {
                        split(clip: clip, document: document)
                    }
                    ClipAction(title: "Duplicate", systemImage: "plus.square.on.square") {
                        var copy = clip
                        copy.id = UUID()
                        copy.transitionIn = nil
                        guard let index = document.timeline.clipIndex(id: clip.id) else { return }
                        document.perform(.insertClip(index: index + 1, clip: copy))
                    }
                    ClipAction(title: "Trim −0.2s", systemImage: "minus") {
                        retrim(clip: clip, delta: -0.2, document: document)
                    }
                    ClipAction(title: "Trim +0.2s", systemImage: "plus") {
                        retrim(clip: clip, delta: 0.2, document: document)
                    }
                    ClipAction(title: "Transition", systemImage: "arrow.left.arrow.right") {
                        cycleTransition(clip: clip, document: document)
                    }
                    ClipAction(title: "Delete", systemImage: "trash", isDestructive: true) {
                        guard let index = document.timeline.clipIndex(id: clip.id) else { return }
                        document.perform(.deleteClip(index: index, clip: clip))
                        selectedClipID = nil
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
            }
            .background(Theme.Palette.surface)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { tool in
                Button {
                    switch tool {
                    case .export:
                        model.path.append(.export)
                    case .audio:
                        showsAudioSheet = true
                    default:
                        withAnimation(Theme.Motion.quick) { activeTool = tool }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 17, weight: .regular))
                        Text(tool.title)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(
                        activeTool == tool && tool != .export
                            ? Theme.Palette.accent
                            : Theme.Palette.secondaryText
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(tool.title)
            }
        }
        .background(.regularMaterial)
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

    private func split(clip: VideoClip, document: TimelineDocument) {
        let localTime = currentTime - clip.start
        // Refuse a split that would produce a sub-frame sliver — that is a mis-tap, not an edit.
        guard localTime > 0.1, localTime < clip.duration - 0.1 else {
            Haptics.warning()
            return
        }
        document.perform(
            .splitClip(
                id: clip.id, atLocalTime: localTime,
                newClipID: UUID(), wasDuration: clip.duration
            )
        )
        Haptics.grab()
    }

    private func retrim(clip: VideoClip, delta: Double, document: TimelineDocument) {
        let newDuration = max(
            document.timeline.canvas.frameDuration * 2,
            clip.duration + delta
        )
        document.perform(
            .trimClip(
                id: clip.id, duration: newDuration, sourceStart: clip.sourceStart,
                wasDuration: clip.duration, wasSourceStart: clip.sourceStart
            )
        )
    }

    private func cycleTransition(clip: VideoClip, document: TimelineDocument) {
        let catalogue = TransitionLibrary.catalogue
        let current = clip.transitionIn?.kind ?? .cut
        let next = catalogue[(catalogue.firstIndex(of: current).map { $0 + 1 } ?? 0) % catalogue.count]

        let transition = next == .cut
            ? nil
            : Transition(
                kind: next,
                duration: TransitionLibrary.defaultDuration(for: next),
                direction: next.needsDirection ? .left : nil
            )

        document.perform(
            .setTransition(
                clipID: clip.id, transition: transition, wasTransition: clip.transitionIn
            )
        )
        showToast(next.displayName)
        Haptics.snap()
    }

    private func showToast(_ message: String) {
        withAnimation(Theme.Motion.quick) { undoToast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.Motion.quick) { undoToast = nil }
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
        engine.currentAssetPool = model.assets
        self.engine = engine
    }
}

private struct ClipAction: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isDestructive ? Theme.Palette.danger : Theme.Palette.primaryText)
            .frame(width: 68, height: 50)
            .background(
                Theme.Palette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
