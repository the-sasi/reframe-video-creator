import ReframeKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var intelligenceStatus = "Checking…"
    @State private var enhancementEnabled = true
    @State private var storageUsed: String = "—"

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: ReframeKit.version)
                LabeledContent("Project format", value: "v\(ReframeKit.schemaVersion)")
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
            } header: {
                Text("Intelligence")
            } footer: {
                Text("Reframe has no accounts, no subscriptions and no API keys. Every model it uses is already on this iPhone.")
            }

            // The privacy panel says what leaves the device. The answer is "nothing", stated in
            // those words rather than in a policy.
            Section {
                privacyRow(
                    icon: "iphone",
                    title: "Everything stays here",
                    detail: "Analysis, editing and rendering all run on this iPhone."
                )
                privacyRow(
                    icon: "wifi.slash",
                    title: "No network access",
                    detail: "Reframe makes no requests. There is no telemetry, no analytics, no crash reporting and no remote configuration."
                )
                privacyRow(
                    icon: "photo",
                    title: "Your originals are never copied",
                    detail: "Projects reference the photos in your library rather than duplicating them."
                )
                privacyRow(
                    icon: "film",
                    title: "References are not kept",
                    detail: "The reference video is released once analysis finishes. Only its structure — timings and movements — is saved."
                )
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
                Text("If something goes wrong, open this and tap Export Log. It records what ran and where it stopped — no photos, no personal content.")
            }

            Section {
                LabeledContent("Free space", value: storageUsed)
                Button("Clear preview caches", role: .destructive) {
                    model.handleMemoryPressure()
                    Haptics.grab()
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Caches are regenerated as needed. Clearing them never affects your projects.")
            }

            Section {
                Link(destination: URL(string: "https://developer.apple.com/documentation/vision")!) {
                    LabeledContent("Vision", value: "Apple")
                }
                LabeledContent("Scene detection", value: "Built in")
                LabeledContent("Beat detection", value: "Built in")
                LabeledContent("Rendering", value: "Metal")
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
        }
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
