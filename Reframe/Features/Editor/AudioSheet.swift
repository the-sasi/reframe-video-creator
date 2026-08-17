import AVFoundation
import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// Music for the timeline: add, replace, level, remove.
///
/// Every change goes through an `EditCommand`, so audio edits sit in the same undo stack as
/// everything else rather than being a special case that silently escapes it.
struct AudioSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TimelineDocument

    @State private var isImporting = false
    @State private var note: String?

    private var audioClip: AudioClip? { document.timeline.audio.first }
    private var track: AssetReference? { audioClip.flatMap { model.assets[$0.assetID] } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let clip = audioClip, let track {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(Theme.Palette.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.displayName)
                                        .font(Theme.Font.body)
                                        .lineLimit(1)
                                    Text(String(format: "%.0fs of %.0fs used", clip.duration, track.duration))
                                        .font(Theme.Font.caption)
                                        .foregroundStyle(Theme.Palette.secondaryText)
                                }
                                Spacer()
                            }

                            if track.duration < clip.duration - 0.5 {
                                Label(
                                    "This track is shorter than the video — it'll go silent near the end.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.warning)
                            }
                        }
                        .padding(.vertical, 2)
                    } else {
                        Text("No music yet.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label(
                            audioClip == nil ? "Add Music" : "Replace Music",
                            systemImage: "plus.circle"
                        )
                    }
                } header: {
                    Text("Track")
                } footer: {
                    Text("Pick an MP3, M4A or WAV from Files. Apple Music downloads are protected and can't be used.")
                }

                if let clip = audioClip {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Volume")
                                Spacer()
                                Text("\(Int(clip.volume * 100))%")
                                    .font(.system(.caption, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                            Slider(
                                value: Binding(
                                    get: { clip.volume },
                                    set: { setVolume($0, for: clip) }
                                ),
                                in: 0...1,
                                onEditingChanged: { editing in
                                    if editing {
                                        document.beginGesture(key: "audiovol:\(clip.id)")
                                    } else {
                                        document.endGesture()
                                    }
                                }
                            )
                            .tint(Theme.Palette.accent)
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("Level")
                    } footer: {
                        Text("Fades in over \(String(format: "%.2fs", clip.fadeIn)) and out over \(String(format: "%.2fs", clip.fadeOut)) automatically.")
                    }

                    Section {
                        Button(role: .destructive) {
                            removeMusic(clip)
                        } label: {
                            Label("Remove Music", systemImage: "trash")
                        }
                    }
                }

                if let beatGrid = model.recipe?.beatGrid {
                    Section {
                        LabeledContent("Reference tempo", value: "\(Int(beatGrid.bpm.value.rounded())) BPM")
                        LabeledContent(
                            "Cuts",
                            value: beatGrid.cutsAlignedToBeats.value ? "on the beat" : "reference timing"
                        )
                    } header: {
                        Text("Rhythm")
                    } footer: {
                        Text("Scene lengths were taken from the reference's rhythm. A track at a similar tempo will feel tightest.")
                    }
                }

                if let note {
                    Section {
                        Text(note)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.warning)
                    }
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
            ) { result in
                guard case .success(let url) = result else { return }
                Task { await addMusic(from: url) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Actions

    private func setVolume(_ value: Double, for clip: AudioClip) {
        document.perform(
            .setAudioVolume(id: clip.id, volume: value, wasVolume: clip.volume)
        )
    }

    private func removeMusic(_ clip: AudioClip) {
        guard let index = document.timeline.audio.firstIndex(where: { $0.id == clip.id }) else {
            return
        }
        document.perform(.deleteAudioClip(index: index, clip: clip))
        model.content.musicAssetID = nil
    }

    private func addMusic(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/audio-\(UUID().uuidString).\(url.pathExtension)"
        let destination = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
            note = "Couldn't read that file."
            return
        }

        let asset = AVURLAsset(url: destination)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false

        guard duration > 0, hasAudio else {
            try? FileManager.default.removeItem(at: destination)
            note = "That track is protected and can't be used. Apple Music downloads won't work — try a file you own."
            DiagnosticsLog.shared.warning("editor", "audio unreadable/DRM: \(url.lastPathComponent)")
            return
        }

        let reference = AssetReference(
            kind: .audio,
            origin: .sandboxRelativePath(relative),
            displayName: url.deletingPathExtension().lastPathComponent,
            pixelWidth: 0, pixelHeight: 0, duration: duration
        )
        model.assets.add(reference)
        model.content.musicAssetID = reference.id

        // Replace rather than layer: one music bed is the whole model here, and silently
        // stacking a second track under the first would be baffling.
        if let existing = audioClip,
           let index = document.timeline.audio.firstIndex(where: { $0.id == existing.id }) {
            document.perform(.deleteAudioClip(index: index, clip: existing))
        }

        let timelineDuration = document.timeline.duration
        let clip = AudioClip(
            assetID: reference.id,
            start: 0,
            duration: min(timelineDuration, duration),
            sourceStart: 0,
            volume: 1.0,
            fadeIn: 0.15,
            fadeOut: min(0.8, timelineDuration * 0.1)
        )
        document.perform(.addAudioClip(clip: clip))

        note = nil
        DiagnosticsLog.shared.info(
            "editor", "music added: \(reference.displayName) \(String(format: "%.1fs", duration))"
        )
    }
}
