import Photos
import ReframeKit
import SwiftUI

/// Export, save, share. No watermark, ever.
struct ExportView: View {
    @Environment(AppModel.self) private var model

    @State private var progress: ExportProgress?
    @State private var outputURL: URL?
    @State private var isExporting = false
    @State private var savedToPhotos = false
    @State private var shareItem: URL?
    @State private var task: Task<Void, Never>?

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
                    title: isExporting ? "Exporting…" : "Export",
                    systemImage: "square.and.arrow.up",
                    isEnabled: !isExporting,
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
        .onDisappear { task?.cancel() }
    }

    // MARK: - Settings

    private var settings: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Size").font(Theme.Font.sectionTitle)
                Picker("Size", selection: sizeBinding) {
                    Text("720p").tag(SizeOption.hd720)
                    Text("1080p").tag(SizeOption.hd1080)
                    Text("4K").tag(SizeOption.uhd4K)
                }
                .pickerStyle(.segmented)

                if model.exportSettings.width >= 2160 {
                    Label(
                        "4K takes noticeably longer and warms the phone. If it fails, the error offers a 720p retry.",
                        systemImage: "thermometer.medium"
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Frame rate").font(Theme.Font.sectionTitle)
                Picker("Frame rate", selection: fpsBinding) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.segmented)

                if model.exportSettings.fps == 60,
                   (model.document?.timeline.duration ?? 0) > 45 {
                    Label(
                        "60fps on a long video takes noticeably longer and gets warm.",
                        systemImage: "info.circle"
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.warning)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Toggle(isOn: hevcBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use HEVC").font(Theme.Font.body)
                        Text("Around 40% smaller. Turn off for maximum compatibility with older devices and some websites.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .tint(Theme.Palette.accent)
            }

            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            let duration = model.document?.timeline.duration ?? 0
            let bytes = model.exportSettings.estimatedBytes(duration: duration)

            HStack {
                Text("Estimated size")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(.callout, design: .rounded, weight: .medium))
            }
            HStack {
                Text("Length")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text(PreviewPane.timecode(duration))
                    .font(.system(.callout, design: .rounded, weight: .medium).monospacedDigit())
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

                    // A real bar only where there is a real denominator — the video phase knows
                    // exactly how many frames it must write. Everything else is a named state.
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .tint(Theme.Palette.accent)
                            .frame(maxWidth: 240)
                        Text("\(progress.framesWritten) of \(progress.totalFrames) frames")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    } else {
                        ProgressView().controlSize(.regular)
                    }
                }
            }

            Button("Cancel") {
                task?.cancel()
                isExporting = false
            }
            .font(Theme.Font.callout)
            .foregroundStyle(Theme.Palette.secondaryText)
            .minimumHitTarget()

            Spacer(minLength: 0)
        }
    }

    // MARK: - Finished

    private func finished(url: URL) -> some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: Theme.Space.l)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.Palette.success)

            Text("Your video is ready")
                .font(Theme.Font.screenTitle)

            VStack(spacing: Theme.Space.s) {
                PrimaryButton(
                    title: savedToPhotos ? "Saved to Photos" : "Save to Photos",
                    systemImage: savedToPhotos ? "checkmark" : "photo.on.rectangle",
                    isEnabled: !savedToPhotos
                ) {
                    Task { await saveToPhotos(url) }
                }

                SecondaryButton(title: "Share", systemImage: "square.and.arrow.up") {
                    shareItem = url
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

        let request = VideoExporter.Request(
            timeline: document.timeline,
            assets: model.assets,
            settings: model.exportSettings,
            outputURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Reframe-\(Int(Date().timeIntervalSince1970)).mp4")
        )

        task = Task {
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

    private enum SizeOption: Hashable { case hd720, hd1080, uhd4K }

    // 4K is now always offered. The previous gate was a guess at physical memory carrying a
    // VERIFY REQUIRED, and a guess that silently removes a capability is worse than letting the
    // export try and fail — especially since the failure path already offers a 720p retry.
    // Hiding an option on unmeasured grounds is not caution, it is a different kind of wrong.

    private var sizeBinding: Binding<SizeOption> {
        Binding(
            get: {
                switch model.exportSettings.shortSideTier {
                case 720: return .hd720
                case 2160: return .uhd4K
                default: return .hd1080
                }
            },
            set: { option in
                let fps = model.exportSettings.fps
                let hevc = model.exportSettings.preferHEVC
                let quality = model.exportSettings.quality
                let canvas = model.document?.timeline.canvas ?? .reel1080
                let tier: Int
                switch option {
                case .hd720: tier = 720
                case .hd1080: tier = 1080
                case .uhd4K: tier = 2160
                }
                var settings = ExportSettings.matching(canvas: canvas, shortSide: tier, preferHEVC: hevc, quality: quality)
                settings.fps = fps
                model.exportSettings = settings
            }
        )
    }

    private var fpsBinding: Binding<Int> {
        Binding(
            get: { model.exportSettings.fps },
            set: { model.exportSettings.fps = $0 }
        )
    }

    private var hevcBinding: Binding<Bool> {
        Binding(
            get: { model.exportSettings.preferHEVC },
            set: { model.exportSettings.preferHEVC = $0 }
        )
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
