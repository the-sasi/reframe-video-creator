import Photos
import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// Export, save, share. No watermark, ever.
///
/// Presets name destinations rather than pixel counts; the size and quality choices under them
/// explain themselves in plain words. Progress is a real bar during the video pass — the only
/// phase with a real denominator — and named states elsewhere.
struct ExportView: View {
    @Environment(AppModel.self) private var model

    @State private var progress: ExportProgress?
    @State private var outputURL: URL?
    @State private var isExporting = false
    @State private var savedToPhotos = false
    @State private var shareItem: URL?
    @State private var task: Task<Void, Never>?
    @State private var isSavingToFiles = false
    @State private var startedAt: Date?
    @State private var elapsed: Double = 0

    private var canvas: CanvasSpec { model.document?.timeline.canvas ?? .reel1080 }
    private var duration: Double { model.document?.timeline.duration ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                if let outputURL {
                    finished(url: outputURL)
                } else if isExporting {
                    exporting
                } else {
                    settings
                }
            }
            .padding(Theme.Space.m)
            .padding(.bottom, 96)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if outputURL == nil {
                PrimaryButton(
                    title: isExporting ? "Exporting…" : "Export \(model.exportSettings.shortSideTier == 2160 ? "4K" : "\(model.exportSettings.shortSideTier)p")",
                    systemImage: "square.and.arrow.up",
                    isEnabled: !isExporting && duration > 0,
                    isBusy: isExporting
                ) {
                    startExport()
                }
                .padding(Theme.Space.m)
                .background(.regularMaterial)
            }
        }
        .sheet(item: $shareItem) { url in
            ShareSheet(items: [url])
        }
        .fileExporter(
            isPresented: $isSavingToFiles,
            item: outputURL.map { ExportedMovie(url: $0) },
            contentTypes: [.mpeg4Movie],
            defaultFilename: outputURL?.deletingPathExtension().lastPathComponent
        ) { result in
            if case .success = result { Haptics.success() }
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            presetSection
            sizeSection
            qualitySection
            summary
        }
    }

    private struct Preset: Identifiable {
        let id: String
        let title: String
        let detail: String
        let aspect: Double
        let systemImage: String
    }

    private static let presets: [Preset] = [
        Preset(id: "reel", title: "Instagram Reel", detail: "1080 × 1920 · 9:16", aspect: 9.0 / 16.0, systemImage: "iphone"),
        Preset(id: "short", title: "YouTube Short", detail: "1080 × 1920 · 9:16", aspect: 9.0 / 16.0, systemImage: "play.rectangle"),
        Preset(id: "tiktok", title: "TikTok", detail: "1080 × 1920 · 9:16", aspect: 9.0 / 16.0, systemImage: "music.note"),
        Preset(id: "portrait", title: "Instagram Portrait", detail: "1080 × 1350 · 4:5", aspect: 4.0 / 5.0, systemImage: "rectangle.portrait"),
        Preset(id: "square", title: "Instagram Post", detail: "1080 × 1080 · 1:1", aspect: 1, systemImage: "square"),
        Preset(id: "youtube", title: "YouTube", detail: "1920 × 1080 · 16:9", aspect: 16.0 / 9.0, systemImage: "tv"),
    ]

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Destination", subtitle: "The canvas is \(canvas.width) × \(canvas.height). Presets that match it are ready; others need a canvas change in the editor.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(Self.presets) { preset in
                        let matches = abs(preset.aspect - canvas.aspectRatio) < 0.02
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: preset.systemImage)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(matches ? Theme.Palette.accent : Theme.Palette.tertiaryText)
                            Text(preset.title)
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(matches ? Theme.Palette.primaryText : Theme.Palette.tertiaryText)
                            Text(preset.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.tertiaryText)
                        }
                        .padding(Theme.Space.s)
                        .frame(width: 130, alignment: .leading)
                        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .strokeBorder(matches ? Theme.Palette.accent.opacity(0.5) : Theme.Palette.hairline, lineWidth: 1)
                        }
                        .opacity(matches ? 1 : 0.6)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Size").font(Theme.Font.sectionTitle)
            Picker("Size", selection: sizeBinding) {
                Text("720p").tag(720)
                Text("1080p").tag(1080)
                Text("4K").tag(2160)
            }
            .pickerStyle(.segmented)

            Text(sizeExplanation)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)

            if model.exportSettings.shortSideTier == 2160 {
                Label(
                    "4K takes several times longer than 1080p and warms the phone. If it fails, the error offers a 720p retry. Your photos are only rendered at 4K if they have the pixels for it.",
                    systemImage: "thermometer.medium"
                )
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.warning)
            }

            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Frame rate").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                    Picker("Frame rate", selection: fpsBinding) {
                        Text("24").tag(24)
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codec").font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                    Picker("Codec", selection: hevcBinding) {
                        Text("HEVC").tag(true)
                        Text("H.264").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
            Text(model.exportSettings.preferHEVC
                 ? "HEVC is about 40% smaller at the same quality and plays everywhere modern."
                 : "H.264 is the maximum-compatibility choice for older devices and some websites.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            if model.exportSettings.fps == 60, duration > 45 {
                Label("60fps on a long video takes noticeably longer and gets warm.", systemImage: "info.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
        }
    }

    private var sizeExplanation: String {
        let s = model.exportSettings
        return "\(s.width) × \(s.height) · \(s.fps) fps · \(s.preferHEVC ? "HEVC" : "H.264") · about \(s.bitrate / 1_000_000) Mbps"
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Quality").font(Theme.Font.sectionTitle)
            ForEach(ExportQuality.allCases) { quality in
                ChoiceCard(
                    title: quality.displayName,
                    detail: quality.explanation + " ~" + ByteCountFormatter.string(
                        fromByteCount: settings(withQuality: quality).estimatedBytes(duration: duration), countStyle: .file
                    ),
                    systemImage: quality == .standard ? "hare" : (quality == .high ? "checkmark.seal" : "sparkles"),
                    isSelected: model.exportSettings.quality == quality
                ) {
                    model.exportSettings.quality = quality
                    Haptics.snap()
                }
            }
        }
    }

    private func settings(withQuality quality: ExportQuality) -> ExportSettings {
        var s = model.exportSettings
        s.quality = quality
        return s
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            let bytes = model.exportSettings.estimatedBytes(duration: duration)
            HStack {
                Text("Estimated size").font(Theme.Font.callout).foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(.callout, design: .rounded, weight: .medium))
            }
            HStack {
                Text("Length").font(Theme.Font.callout).foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text(PreviewPane.timecode(duration))
                    .font(.system(.callout, design: .rounded, weight: .medium).monospacedDigit())
            }
            HStack {
                Text("Watermark").font(Theme.Font.callout).foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text("None. Ever.").font(.system(.callout, design: .rounded, weight: .medium))
            }
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }

    // MARK: - In progress

    private var exporting: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: Theme.Space.xl)

            if let progress {
                VStack(spacing: Theme.Space.s) {
                    Text(progress.phase.title)
                        .font(Theme.Font.screenTitle)

                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .tint(Theme.Palette.accent)
                            .frame(maxWidth: 260)
                        HStack(spacing: Theme.Space.m) {
                            Text("\(progress.framesWritten) of \(progress.totalFrames) frames")
                            if elapsed > 2, fraction > 0.02 {
                                let remaining = elapsed / fraction - elapsed
                                Text("· about \(Int(remaining.rounded()))s left")
                            }
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    } else {
                        ProgressView().controlSize(.regular)
                    }
                }
            }

            Text("Keep Reframe open — rendering stops if the app goes to the background.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)

            Button("Cancel") {
                task?.cancel()
                isExporting = false
            }
            .font(Theme.Font.callout)
            .foregroundStyle(Theme.Palette.secondaryText)
            .minimumHitTarget()

            Spacer(minLength: 0)
        }
        .task {
            while isExporting, !Task.isCancelled {
                if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Finished

    private func finished(url: URL) -> some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: Theme.Space.l)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.Palette.success)

            VStack(spacing: 4) {
                Text("Your video is ready").font(Theme.Font.screenTitle)
                if let bytes = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · \(model.exportSettings.width) × \(model.exportSettings.height) · \(String(format: "%.0fs", elapsed)) to render")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            VStack(spacing: Theme.Space.s) {
                PrimaryButton(
                    title: savedToPhotos ? "Saved to Photos" : "Save to Photos",
                    systemImage: savedToPhotos ? "checkmark" : "photo.on.rectangle",
                    isEnabled: !savedToPhotos
                ) {
                    Task { await saveToPhotos(url) }
                }
                HStack(spacing: Theme.Space.s) {
                    SecondaryButton(title: "Save to Files", systemImage: "folder") { isSavingToFiles = true }
                    SecondaryButton(title: "Share", systemImage: "square.and.arrow.up") { shareItem = url }
                }
                Button("Back to editing") {
                    model.path.removeLast()
                }
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
                .minimumHitTarget()
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func startExport() {
        guard let renderer = model.renderer, let document = model.document else {
            model.present(.metalUnavailable)
            return
        }

        isExporting = true
        savedToPhotos = false
        startedAt = Date()
        elapsed = 0

        let title = (model.projectTitle ?? model.recipe?.title ?? "Reframe")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day().hour().minute()).replacingOccurrences(of: "[/:, ]", with: "-", options: .regularExpression)
        let request = VideoExporter.Request(
            timeline: document.timeline,
            assets: model.assets,
            settings: model.exportSettings,
            outputURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(title.isEmpty ? "Reframe" : title) \(stamp).mp4")
        )

        // Keep the screen awake for the render; the display is the only thing keeping the app
        // in the foreground.
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let exporter = VideoExporter(renderer: renderer)
            do {
                let url = try await exporter.export(request, resolver: model.resolver) { update in
                    Task { @MainActor in progress = update }
                }
                await MainActor.run {
                    outputURL = url
                    isExporting = false
                    Haptics.success()
                }
            } catch let error as ReframeError {
                await MainActor.run {
                    isExporting = false
                    if case .exportCancelled = error { return }
                    model.present(error)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    model.present(.exportFailed(detail: "\(error)"))
                }
            }
        }
    }

    private func saveToPhotos(_ url: URL) async {
        // Add-only authorisation: Reframe never needs to read your whole library to save a file.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            model.present(.photosAddOnlyDenied)
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            await MainActor.run {
                savedToPhotos = true
                Haptics.success()
            }
        } catch {
            model.present(.exportFailed(detail: error.localizedDescription))
        }
    }

    // MARK: - Bindings

    private var sizeBinding: Binding<Int> {
        Binding(
            get: { model.exportSettings.shortSideTier },
            set: { tier in
                var settings = ExportSettings.matching(
                    canvas: canvas, shortSide: tier,
                    preferHEVC: model.exportSettings.preferHEVC, quality: model.exportSettings.quality
                )
                settings.fps = model.exportSettings.fps
                model.exportSettings = settings
            }
        )
    }

    private var fpsBinding: Binding<Int> {
        Binding(get: { model.exportSettings.fps }, set: { model.exportSettings.fps = $0 })
    }

    private var hevcBinding: Binding<Bool> {
        Binding(get: { model.exportSettings.preferHEVC }, set: { model.exportSettings.preferHEVC = $0 })
    }
}

/// The finished movie, for `fileExporter`.
struct ExportedMovie: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Movie, .movie] }
    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
