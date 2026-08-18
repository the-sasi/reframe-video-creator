import ReframeKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("reframe.appearance") private var appearance = AppearanceSetting.system.rawValue

    @State private var intelligenceStatus = "Checking…"
    @State private var enhancementEnabled = true
    @State private var storageUsed: String = "—"
    @State private var captionAvailability: CaptionTranscriber.Availability?
    @State private var isInstallingCaptions = false
    @State private var captionProgress: Double = 0

    var body: some View {
        List {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Video editing is designed dark-first, but light mode is fully supported.")
            }

            Section {
                LabeledContent("Build", value: DeviceInfo.buildDescription())
                LabeledContent("Engine", value: ReframeKit.version)
                LabeledContent("Project format", value: "v\(ReframeKit.schemaVersion)")
            } footer: {
                Text("The build line includes the commit it was made from — quote it when reporting a problem.")
            }

            Section {
                Toggle(isOn: $enhancementEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smarter suggestions")
                        Text("Uses Apple's on-device model, when your iPhone has it, to write nicer slot descriptions and suggest wording. Everything works without it.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .tint(Theme.Palette.accent)
                .onChange(of: enhancementEnabled) { _, value in
                    Task {
                        await model.intelligence.setEnhancementEnabled(value)
                        intelligenceStatus = await model.intelligence.statusDescription()
                    }
                }
                LabeledContent("Currently using", value: intelligenceStatus)
                    .font(Theme.Font.callout)

                captionsRow
            } header: {
                Text("On-device intelligence")
            } footer: {
                Text("Reframe has no accounts, no subscriptions and no API keys. Every model it uses is Apple's, already on this iPhone or downloaded from Apple by the system. Nothing here is required — the app works fully without any of it.")
            }

            // The privacy panel says what leaves the device. The answer is "nothing", stated in
            // those words rather than in a policy.
            Section {
                privacyRow(icon: "iphone", title: "Everything stays here",
                           detail: "Analysis, editing, captions and rendering all run on this iPhone.")
                privacyRow(icon: "wifi.slash", title: "Nothing is sent anywhere",
                           detail: "Reframe contacts no servers of its own and no third parties. No telemetry, no analytics, no crash reporting, no remote configuration, no accounts.")
                privacyRow(icon: "icloud.and.arrow.down", title: "iCloud photos download on demand",
                           detail: "If a photo you pick lives in iCloud rather than on this iPhone, the system fetches your own copy of it. That, and Apple's optional caption language pack, is the only network activity involved. Nothing is uploaded.")
                privacyRow(icon: "photo", title: "Your originals are never copied",
                           detail: "Projects reference the photos in your library rather than duplicating them.")
                privacyRow(icon: "film", title: "References are not kept",
                           detail: "The reference video is released once analysis finishes. Only its structure — timings and movements — is saved, unless you explicitly extract its audio.")
            } header: {
                Text("Privacy")
            }

            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("If something goes wrong, open this and export the log. It records what ran and where it stopped — no photos, no personal content.")
            }

            Section {
                LabeledContent("Free space", value: storageUsed)
                Button("Clear preview caches", role: .destructive) {
                    model.handleMemoryPressure()
                    ThumbnailCache.shared.evictAll()
                    Haptics.grab()
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Caches are regenerated as needed. Clearing them never affects your projects.")
            }

            Section {
                LabeledContent("Scene detection", value: "Built in")
                LabeledContent("Beat detection", value: "Built in")
                LabeledContent("Composition", value: "Apple Vision")
                LabeledContent("Captions", value: "Apple Speech")
                LabeledContent("Rendering", value: "Metal")
                LabeledContent("Encoding", value: "VideoToolbox")
            } header: {
                Text("What powers this")
            } footer: {
                Text("Scene and beat detection are deterministic algorithms rather than AI models — the same video always produces the same result.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            intelligenceStatus = await model.intelligence.statusDescription()
            enhancementEnabled = await model.intelligence.isEnhancementEnabled
            let bytes = await model.projectStore.availableStorageBytes()
            storageUsed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            captionAvailability = await CaptionTranscriber.availability()
        }
    }

    /// The one "model manager" the app needs: Apple's caption language pack, installed by the
    /// system on request. Shows what it is, whether it is present, and lets you fetch it ahead
    /// of time so the first caption isn't a wait.
    @ViewBuilder
    private var captionsRow: some View {
        if let availability = captionAvailability {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Caption language pack")
                    Text(
                        !availability.isSupported
                            ? (availability.reason ?? "Not available for this language.")
                            : (availability.isInstalled ? "Installed for \(languageName) · Apple, on device" : "Not installed for \(languageName) · downloaded from Apple when first used")
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                }
                Spacer()
                if availability.isSupported, !availability.isInstalled {
                    if isInstallingCaptions {
                        ProgressView(value: captionProgress).frame(width: 60)
                    } else {
                        Button("Get") {
                            Task {
                                isInstallingCaptions = true
                                try? await CaptionTranscriber.installAssetsIfNeeded { progress in
                                    Task { @MainActor in captionProgress = progress }
                                }
                                captionAvailability = await CaptionTranscriber.availability()
                                isInstallingCaptions = false
                            }
                        }
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                } else if availability.isInstalled {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
                }
            }
        }
    }

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
