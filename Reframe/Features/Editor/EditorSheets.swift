import PhotosUI
import ReframeKit
import SwiftUI

// MARK: - Transition

/// Pick a transition into the selected clip: kind, duration, direction, and "apply to all".
struct TransitionSheet: View {
    let document: TimelineDocument
    let clipID: UUID?

    @State private var applyToAll = false

    private var clip: VideoClip? {
        if let clipID, let found = document.timeline.clip(id: clipID) { return found }
        return document.timeline.clips.dropFirst().first
    }

    var body: some View {
        SheetScaffold(title: "Transition", detents: [.medium]) {
            if let clip, let index = document.timeline.clipIndex(id: clip.id), index > 0 {
                content(clip)
            } else {
                EmptyStateView(
                    systemImage: "arrow.left.arrow.right",
                    title: "Nothing to transition into",
                    message: "The first clip has nothing before it. Select a later clip to set how it comes in."
                )
            }
        }
    }

    private func content(_ clip: VideoClip) -> some View {
        let current = clip.transitionIn ?? .cut
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(TransitionLibrary.catalogue, id: \.self) { kind in
                        Button {
                            set(kind: kind, for: clip)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: icon(for: kind))
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(height: 22)
                                Text(kind.displayName)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 62)
                            .foregroundStyle(current.kind == kind ? Theme.Palette.onAccent : Theme.Palette.primaryText)
                            .background(current.kind == kind ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.surfaceRaised),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if current.kind != .cut {
                    LabeledSlider(title: "Duration", value: current.duration, range: 0.1...1.2, step: 0.05,
                                  format: { String(format: "%.2fs", $0) },
                                  onEditingChanged: nil) { value in
                        document.perform(.setTransition(clipID: clip.id, transition: ClipTransition(kind: current.kind, duration: value, direction: current.direction), wasTransition: clip.transitionIn))
                    }
                    if current.kind.needsDirection {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Direction").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                            HStack(spacing: Theme.Space.s) {
                                ForEach(TransitionDirection.allCases, id: \.self) { direction in
                                    Chip(title: direction.rawValue.capitalized, systemImage: arrow(for: direction), isSelected: (current.direction ?? .left) == direction) {
                                        document.perform(.setTransition(clipID: clip.id, transition: ClipTransition(kind: current.kind, duration: current.duration, direction: direction), wasTransition: clip.transitionIn))
                                    }
                                }
                            }
                        }
                    }
                }

                Toggle(isOn: $applyToAll) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Apply to every clip")
                        Text("Sets the same transition between all clips.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .tint(Theme.Palette.accent)
            }
            .padding(Theme.Space.m)
        }
    }

    private func set(kind: TransitionKind, for clip: VideoClip) {
        let transition: ClipTransition? = kind == .cut ? nil : ClipTransition(
            kind: kind,
            duration: clip.transitionIn?.kind == kind ? (clip.transitionIn?.duration ?? TransitionLibrary.defaultDuration(for: kind)) : TransitionLibrary.defaultDuration(for: kind),
            direction: kind.needsDirection ? (clip.transitionIn?.direction ?? .left) : nil
        )
        let targets = applyToAll ? Array(document.timeline.clips.dropFirst()) : [clip]
        for target in targets {
            document.perform(.setTransition(clipID: target.id, transition: transition, wasTransition: target.transitionIn))
        }
        Haptics.snap()
    }

    private func icon(for kind: TransitionKind) -> String {
        switch kind {
        case .cut: return "scissors"
        case .dissolve: return "circle.lefthalf.filled"
        case .fadeToBlack: return "moon.fill"
        case .fadeToWhite: return "sun.max.fill"
        case .slide: return "rectangle.portrait.and.arrow.right"
        case .push: return "arrow.right.square"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .whip: return "wind"
        case .blur: return "drop.halffull"
        }
    }

    private func arrow(for direction: TransitionDirection) -> String {
        switch direction {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        }
    }
}

// MARK: - Speed

/// Playback speed for a video clip. Timeline duration stays fixed (the slot's length is the
/// reference's decision); speed changes how much footage plays inside it.
struct SpeedSheet: View {
    @Environment(AppModel.self) private var model
    let document: TimelineDocument
    let clipID: UUID?

    private static let presets: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]

    private var clip: VideoClip? { clipID.flatMap { document.timeline.clip(id: $0) } }

    var body: some View {
        SheetScaffold(title: "Speed", detents: [.height(300)]) {
            if let clip {
                let asset = clip.assetID.flatMap { model.assets[$0] }
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(Self.presets, id: \.self) { speed in
                            Chip(title: speed == 1 ? "Normal" : String(format: "%g×", speed), isSelected: abs(clip.speed - speed) < 0.01) {
                                document.perform(.setClipSpeed(id: clip.id, speed: speed, wasSpeed: clip.speed))
                            }
                        }
                    }
                    LabeledSlider(title: "Custom", value: clip.speed, range: 0.25...4, step: 0.05, format: { String(format: "%.2f×", $0) },
                                  onEditingChanged: { editing in
                                      if editing { document.beginGesture(key: "speed:\(clip.id)") } else { document.endGesture() }
                                  }) { value in
                        document.perform(.setClipSpeed(id: clip.id, speed: value, wasSpeed: clip.speed))
                    }
                    if let asset, asset.kind == .video, asset.duration > 0 {
                        let needed = clip.duration * clip.speed
                        let available = asset.duration - clip.sourceStart
                        if needed > available + 0.05 {
                            Label(
                                String(format: "At this speed the clip needs %.1fs of footage but only %.1fs is left — the end will hold on the last frame.", needed, available),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.warning)
                        } else {
                            Text(String(format: "Plays %.1fs of footage in this %.1fs slot. Pitch is preserved for the clip's own audio.", needed, clip.duration))
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                }
                .padding(Theme.Space.m)
            } else {
                EmptyStateView(systemImage: "gauge", title: "Select a video clip", message: "Speed applies to footage, not stills.")
            }
        }
    }
}

// MARK: - Replace

/// Swap the selected clip's photo or video for another from the pool or the library.
struct ReplaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: TimelineDocument
    let clipID: UUID?

    @State private var pickerItem: PhotosPickerItem?
    @State private var isAdding = false

    private var clip: VideoClip? { clipID.flatMap { document.timeline.clip(id: $0) } }

    var body: some View {
        SheetScaffold(title: "Replace") {
            if let clip {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "photo.badge.plus").foregroundStyle(Theme.Palette.accent).frame(width: 24)
                                Text(isAdding ? "Adding…" : "Choose from Photos")
                                    .font(Theme.Font.body).foregroundStyle(Theme.Palette.primaryText)
                                Spacer()
                                if isAdding { ProgressView().controlSize(.small) }
                            }
                            .padding(Theme.Space.m)
                            .cardSurface(.flat)
                        }
                        .disabled(isAdding)

                        Text("From this project").font(Theme.Font.sectionTitle)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(model.assets.visuals) { asset in
                                Button {
                                    replace(clip, with: asset)
                                } label: {
                                    AssetThumbnailView(asset: asset, size: CGSize(width: 100, height: 130))
                                        .aspectRatio(0.75, contentMode: .fit)
                                        .overlay {
                                            if clip.assetID == asset.id {
                                                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                                    .strokeBorder(Theme.Palette.accent, lineWidth: 3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        isAdding = true
                        if let reference = await MediaImport.reference(from: item) {
                            model.assets.add(reference)
                            replace(clip, with: reference)
                            await model.extractMissingFeatures()
                        } else {
                            model.present(.unsupportedFormat(detail: "unreadable Photos item"))
                        }
                        isAdding = false
                        pickerItem = nil
                    }
                }
            } else {
                EmptyStateView(systemImage: "arrow.triangle.2.circlepath", title: "Select a clip", message: "Tap a clip on the timeline first.")
            }
        }
    }

    private func replace(_ clip: VideoClip, with asset: AssetReference) {
        guard clip.assetID != asset.id else { dismiss(); return }
        document.perform(.replaceClipAsset(id: clip.id, assetID: asset.id, wasAssetID: clip.assetID))
        // A video into a still's slot: start from its beginning at normal speed.
        if asset.kind == .video, clip.speed != 1 || clip.sourceStart != 0 {
            document.perform(.trimClip(id: clip.id, duration: clip.duration, sourceStart: 0, wasDuration: clip.duration, wasSourceStart: clip.sourceStart))
        }
        Haptics.success()
        dismiss()
    }
}

// MARK: - Canvas

/// Aspect ratio and background. Changing aspect re-targets every clip's crop window around
/// its subject where the features are known.
struct CanvasSheet: View {
    @Environment(AppModel.self) private var model
    let document: TimelineDocument

    private struct Option: Identifiable {
        let id: String
        let title: String
        let detail: String
        let size: (Int, Int)
    }

    private let options: [Option] = [
        Option(id: "9:16", title: "9:16", detail: "Reels · TikTok · Shorts", size: (1080, 1920)),
        Option(id: "4:5", title: "4:5", detail: "Instagram portrait", size: (1080, 1350)),
        Option(id: "1:1", title: "1:1", detail: "Square post", size: (1080, 1080)),
        Option(id: "16:9", title: "16:9", detail: "YouTube · landscape", size: (1920, 1080)),
    ]

    var body: some View {
        let canvas = document.timeline.canvas
        SheetScaffold(title: "Canvas", detents: [.medium]) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(options) { option in
                            let isActive = canvas.width == option.size.0 && canvas.height == option.size.1
                            Button {
                                setCanvas(width: option.size.0, height: option.size.1)
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(isActive ? Theme.Palette.onAccent : Theme.Palette.secondaryText, lineWidth: 2)
                                        .frame(width: 30 * CGFloat(min(1, Double(option.size.0) / Double(option.size.1))),
                                               height: 30 * CGFloat(min(1, Double(option.size.1) / Double(option.size.0))))
                                        .frame(height: 32)
                                    Text(option.title).font(.system(.caption, design: .rounded, weight: .semibold))
                                    Text(option.detail).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(isActive ? Theme.Palette.onAccent : Theme.Palette.primaryText)
                                .background(isActive ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.surfaceRaised),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Frame rate").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                        HStack(spacing: Theme.Space.s) {
                            ForEach([24, 30, 60], id: \.self) { fps in
                                Chip(title: "\(fps) fps", isSelected: canvas.fps == fps) {
                                    var next = canvas
                                    next.fps = fps
                                    document.perform(.setCanvas(canvas: next, wasCanvas: canvas))
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Background").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                        ColorSwatchRow(selectedHex: document.timeline.backgroundHex) { hex in
                            document.perform(.setBackground(hex: hex, wasHex: document.timeline.backgroundHex))
                        }
                        Text("Shows behind letterboxed clips and text that outlasts the last clip.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.tertiaryText)
                    }
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private func setCanvas(width: Int, height: Int) {
        let canvas = document.timeline.canvas
        guard canvas.width != width || canvas.height != height else { return }
        let next = CanvasSpec(width: width, height: height, fps: canvas.fps)
        document.perform(.setCanvas(canvas: next, wasCanvas: canvas))

        // Re-solve every clip's fill window for the new aspect, around its subject.
        let subjects = model.subjectRects
        for clip in document.timeline.clips {
            guard let assetID = clip.assetID, let asset = model.assets[assetID] else { continue }
            let window = RecipeBinder.fillWindow(
                sourceAspect: asset.aspectRatio, targetAspect: next.aspectRatio,
                subject: subjects[assetID], referenceSubject: nil,
                framing: Confident(.medium, confidence: 0, basis: "canvas change")
            )
            // Keep the clip's zoom magnitude, re-anchored inside the new window.
            let zoom = clip.cropEnd.width / max(0.01, clip.cropStart.width)
            let start = window
            let end = window.scaled(by: min(1, max(0.62, zoom))).clampedInsideUnitSquare()
            document.perform(.setClipCrop(id: clip.id, start: start, end: zoom < 1 ? end : start, wasStart: clip.cropStart, wasEnd: clip.cropEnd))
        }
        model.exportSettings = ExportSettings.matching(canvas: next, shortSide: model.exportSettings.shortSideTier, preferHEVC: model.exportSettings.preferHEVC, quality: model.exportSettings.quality)
        Haptics.snap()
    }
}

// MARK: - Captions

/// Transcribe speech into timed caption layers, on device.
struct CaptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: TimelineDocument

    @State private var availability: CaptionTranscriber.Availability?
    @State private var isWorking = false
    @State private var progressText: String?
    @State private var styleIndex = 0
    @State private var sourceID: UUID?
    @State private var errorText: String?

    private static let styles: [(String, CaptionLayout.Style)] = [
        ("Pill", .default), ("Bold", .bold), ("Minimal", .minimal),
    ]

    /// Any audio track can carry speech — a downloaded reel audio is often someone talking.
    /// Voice and reference first (most likely), then the rest; transcription itself reports
    /// "no speech recognised" when a music pick turns out to be instrumental.
    private var candidates: [AudioClip] {
        let audio = document.timeline.audio
        return audio.filter { $0.role == .voice || $0.role == .reference }
            + audio.filter { $0.role != .voice && $0.role != .reference }
    }

    var body: some View {
        SheetScaffold(title: "Captions", detents: [.medium]) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let availability, !availability.isSupported {
                        Label(availability.reason ?? "Captions aren't available on this device.", systemImage: "captions.bubble")
                            .font(Theme.Font.callout).foregroundStyle(Theme.Palette.secondaryText)
                    } else if candidates.isEmpty {
                        EmptyStateView(
                            systemImage: "waveform.badge.mic",
                            title: "No audio to transcribe",
                            message: "Captions are made from speech in an audio track. Record a voiceover, keep the reference's audio, or add a track with talking in it."
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("From").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                            ForEach(candidates) { clip in
                                let name = model.assets[clip.assetID]?.displayName ?? clip.role.displayName
                                Chip(title: name, systemImage: clip.role == .voice ? "mic" : "waveform", isSelected: (sourceID ?? candidates.first?.id) == clip.id) {
                                    sourceID = clip.id
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Style").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                            HStack(spacing: Theme.Space.s) {
                                ForEach(Array(Self.styles.enumerated()), id: \.offset) { index, item in
                                    Chip(title: item.0, isSelected: styleIndex == index) { styleIndex = index }
                                }
                            }
                        }
                        if let availability, !availability.isInstalled {
                            Label("The language pack for \(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "your language") will download once (Apple, on device).", systemImage: "arrow.down.circle")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                        }
                        if let progressText {
                            HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text(progressText).font(Theme.Font.caption) }
                        }
                        if let errorText {
                            Text(errorText).font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                        }
                        PrimaryButton(title: "Make Captions", systemImage: "captions.bubble", isEnabled: !isWorking, isBusy: isWorking) {
                            Task { await transcribe() }
                        }
                        Text("Words appear as they are spoken. Everything runs on this iPhone; nothing is uploaded. Edit any caption afterwards like any other text.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.tertiaryText)
                    }
                }
                .padding(Theme.Space.m)
            }
        }
        .task { availability = await CaptionTranscriber.availability() }
    }

    private func transcribe() async {
        guard let clip = candidates.first(where: { $0.id == (sourceID ?? candidates.first?.id) }),
              let asset = model.assets[clip.assetID],
              case .sandboxRelativePath(let path) = asset.origin else {
            errorText = "That track isn't a local file."
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false; progressText = nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
        do {
            if let availability, !availability.isInstalled {
                progressText = "Downloading language pack…"
                try await CaptionTranscriber.installAssetsIfNeeded()
            }
            progressText = "Listening…"
            let segments = try await CaptionTranscriber.transcribe(fileURL: url)
            // Segments are in the file's time; the clip may start later on the timeline and
            // may not start at the file's beginning.
            let shifted = segments.compactMap { segment -> TranscribedSegment? in
                let start = segment.start - clip.sourceStart
                let end = segment.end - clip.sourceStart
                guard end > 0, start < clip.duration else { return nil }
                return TranscribedSegment(text: segment.text, start: max(0, start), end: min(clip.duration, end), wordStarts: segment.wordStarts?.map { $0 - clip.sourceStart })
            }
            let layers = CaptionLayout.layers(from: shifted, timeOffset: clip.start, style: Self.styles[styleIndex].1, canvasDuration: document.timeline.duration)
            guard !layers.isEmpty else {
                errorText = "No speech was recognised in that track."
                return
            }
            for layer in layers { document.perform(.addTextLayer(layer: layer)) }
            Haptics.success()
            dismiss()
        } catch let error as ReframeError {
            errorText = error.presentation.message
        } catch {
            DiagnosticsLog.shared.warning("captions", "unexpected error: \(error)")
            errorText = "Captions failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Save as template

struct SaveTemplateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        SheetScaffold(title: "Save Style", detents: [.height(260)]) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Saves this project's structure — timing, transitions, moves, text slots — as a reusable style. Your photos, videos and words are not included.")
                    .font(Theme.Font.callout).foregroundStyle(Theme.Palette.secondaryText)
                TextField("Style name", text: $title)
                    .textFieldStyle(.roundedBorder)
                PrimaryButton(title: "Save to Templates", systemImage: "square.and.arrow.down") {
                    Task {
                        await model.saveCurrentAsTemplate(title: title)
                        Haptics.success()
                        dismiss()
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .onAppear { title = model.recipe?.title ?? "" }
    }
}

// MARK: - Variations

/// Three (four) alternative treatments of the same structure and assets. Each is one undoable
/// step; "As bound" re-runs the binder from the recipe.
struct VariationsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: TimelineDocument

    var body: some View {
        SheetScaffold(title: "Variations", detents: [.medium, .large]) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Same cuts, same photos, a different treatment. Every one is a single undo step, so try them all.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .padding(.bottom, Theme.Space.xs)

                    if model.recipe != nil {
                        ChoiceCard(
                            title: "Closest to the reference",
                            detail: "Re-binds from the reference's style with your current photos and words. Discards manual edits to motion, transitions and colour.",
                            systemImage: "scope",
                            isSelected: false
                        ) {
                            model.bindTimeline()
                            Haptics.success()
                            dismiss()
                        }
                    }
                    ForEach(EditVariation.allCases) { variation in
                        ChoiceCard(
                            title: variation.displayName,
                            detail: variation.summary,
                            systemImage: icon(for: variation),
                            isSelected: false
                        ) {
                            guard let command = variation.command(for: document.timeline) else {
                                Haptics.warning()
                                return
                            }
                            document.perform(command)
                            Haptics.success()
                            dismiss()
                        }
                    }
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private func icon(for variation: EditVariation) -> String {
        switch variation {
        case .alternateTransitions: return "arrow.left.arrow.right"
        case .cinematic: return "film"
        case .punchy: return "bolt.fill"
        case .minimal: return "minus"
        }
    }
}
