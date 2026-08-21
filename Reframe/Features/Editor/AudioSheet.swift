import AVFoundation
import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// The mix: every track, its level and fades, ducking, and ways to add more.
///
/// Every change goes through an `EditCommand`, so audio edits sit in the same undo stack as
/// everything else rather than being a special case that silently escapes it. What is heard
/// in the preview is what the exporter writes — both come from `AudioMixPlanner`.
struct AudioSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TimelineDocument
    let currentTime: Double
    var selectedID: UUID?

    @State private var isImporting = false
    @State private var showsVoiceover = false
    @State private var note: String?
    @State private var isExtracting = false
    @State private var expandedID: UUID?

    private var timeline: Timeline { document.timeline }
    private var videoClipsWithAudio: [VideoClip] {
        timeline.clips.filter { clip in
            guard let id = clip.assetID, let asset = model.assets[id] else { return false }
            return asset.kind == .video
        }
    }

    var body: some View {
        SheetScaffold(title: "Audio") {
            List {
                tracksSection
                addSection
                if !videoClipsWithAudio.isEmpty { clipAudioSection }
                mixSection
                rhythmSection
                if let note {
                    Section { Text(note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { expandedID = selectedID ?? timeline.audio.first?.id }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio, .aiff]) { result in
            guard case .success(let url) = result else { return }
            Task { await addMusic(from: url) }
        }
        .sheet(isPresented: $showsVoiceover) {
            VoiceoverSheet { reference in
                addClip(asset: reference, role: .voice, at: currentTime)
            }
        }
    }

    // MARK: - Tracks

    @ViewBuilder
    private var tracksSection: some View {
        Section {
            if timeline.audio.isEmpty {
                Text("No audio yet. Add music, record a voiceover, or keep the reference's soundtrack.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            ForEach(timeline.audio) { clip in
                trackRow(clip)
            }
        } header: {
            Text("Tracks")
        }
    }

    private func trackRow(_ clip: AudioClip) -> some View {
        let track = model.assets[clip.assetID]
        let isExpanded = expandedID == clip.id
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                withAnimation(Theme.Motion.quick) { expandedID = isExpanded ? nil : clip.id }
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: icon(for: clip.role))
                        .foregroundStyle(Color(uiColor: TimelineContentView.color(for: clip.role)))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track?.displayName ?? clip.role.displayName)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .lineLimit(1)
                        Text("\(clip.role.displayName) · \(PreviewPane.timecode(clip.start))–\(PreviewPane.timecode(clip.end))\(clip.isMuted ? " · muted" : "")")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer()
                    Text("\(Int(clip.volume * 100))%")
                        .font(.system(.caption, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                LabeledSlider(title: "Volume", value: clip.volume, range: 0...1, format: { "\(Int($0 * 100))%" },
                              onEditingChanged: gesture("audiovol:\(clip.id)")) { value in
                    document.perform(.setAudioVolume(id: clip.id, volume: value, wasVolume: clip.volume))
                }
                let maxFade = max(0.1, clip.duration / 2)
                LabeledSlider(title: "Fade in", value: min(clip.fadeIn, maxFade), range: 0...maxFade, format: { String(format: "%.1fs", $0) },
                              onEditingChanged: gesture("audiofade:\(clip.id)")) { value in
                    document.perform(.setAudioFades(id: clip.id, fadeIn: value, fadeOut: clip.fadeOut, wasFadeIn: clip.fadeIn, wasFadeOut: clip.fadeOut))
                }
                LabeledSlider(title: "Fade out", value: min(clip.fadeOut, maxFade), range: 0...maxFade, format: { String(format: "%.1fs", $0) },
                              onEditingChanged: gesture("audiofade:\(clip.id)")) { value in
                    document.perform(.setAudioFades(id: clip.id, fadeIn: clip.fadeIn, fadeOut: value, wasFadeIn: clip.fadeIn, wasFadeOut: clip.fadeOut))
                }
                HStack(spacing: Theme.Space.s) {
                    Chip(title: clip.isMuted ? "Unmute" : "Mute", systemImage: clip.isMuted ? "speaker.slash" : "speaker.wave.2", isSelected: clip.isMuted) {
                        document.perform(.setAudioMuted(id: clip.id, isMuted: !clip.isMuted, wasMuted: clip.isMuted))
                    }
                    Chip(title: "Start at playhead", systemImage: "arrow.right.to.line") {
                        // Clamped so the track keeps at least a second under the video — a
                        // playhead parked at the end would otherwise move the whole clip past
                        // it, which plays as silence and reads as "audio is broken".
                        let overlap = min(1.0, clip.duration)
                        let start = min(max(0, currentTime), max(0, timeline.duration - overlap))
                        document.perform(.retimeAudioClip(id: clip.id, start: start, duration: clip.duration, sourceStart: clip.sourceStart,
                                                          wasStart: clip.start, wasDuration: clip.duration, wasSourceStart: clip.sourceStart))
                    }
                    Chip(title: "Fit to video", systemImage: "rectangle.expand.vertical") {
                        let sourceLength = track?.duration ?? timeline.duration
                        let duration = sourceLength > 0 ? min(timeline.duration, sourceLength - clip.sourceStart) : timeline.duration
                        document.perform(.retimeAudioClip(id: clip.id, start: 0, duration: max(0.2, duration), sourceStart: clip.sourceStart,
                                                          wasStart: clip.start, wasDuration: clip.duration, wasSourceStart: clip.sourceStart))
                    }
                    Menu {
                        ForEach([AudioRole.music, .voice, .effect, .reference], id: \.self) { role in
                            Button(role.displayName) { setRole(role, for: clip) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tag").font(.system(size: 11, weight: .semibold))
                            Text(clip.role.displayName).font(.system(size: 13, weight: .medium, design: .rounded))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .background(Theme.Palette.surfaceRaised, in: Capsule())
                    }
                }
                Button(role: .destructive) {
                    guard let index = timeline.audio.firstIndex(where: { $0.id == clip.id }) else { return }
                    document.perform(.deleteAudioClip(index: index, clip: clip))
                    if clip.assetID == model.content.musicAssetID { model.content.musicAssetID = nil }
                    if clip.assetID == model.content.voiceoverAssetID { model.content.voiceoverAssetID = nil }
                    if clip.assetID == model.content.referenceAudioAssetID { model.content.referenceAudioAssetID = nil }
                } label: {
                    Label("Remove track", systemImage: "trash")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for role: AudioRole) -> String {
        switch role {
        case .music: return "music.note"
        case .voice: return "mic"
        case .effect: return "sparkles"
        case .reference: return "waveform"
        case .clipAudio: return "film"
        }
    }

    // MARK: - Add

    private var addSection: some View {
        Section {
            Button { isImporting = true } label: { Label("Add music from Files", systemImage: "music.note.list") }
            Button { showsVoiceover = true } label: { Label("Record a voiceover", systemImage: "mic.badge.plus") }
            if model.referenceURL != nil, model.recipe?.source.hasAudio == true, model.content.referenceAudioAssetID == nil {
                Button {
                    Task {
                        isExtracting = true
                        if let asset = await model.extractReferenceAudio() {
                            model.content.referenceAudioAssetID = asset.id
                            addClip(asset: asset, role: .reference, at: 0)
                        }
                        isExtracting = false
                    }
                } label: {
                    HStack {
                        Label("Keep the reference's audio", systemImage: "waveform.badge.plus")
                        if isExtracting { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isExtracting)
            }
        } header: {
            Text("Add")
        } footer: {
            Text("MP3, M4A, AAC or WAV you own. Apple Music downloads are protected and can't be used. A voiceover is placed at the playhead and the music dips under it automatically.")
        }
    }

    // MARK: - Clip audio

    private var clipAudioSection: some View {
        Section {
            ForEach(videoClipsWithAudio) { clip in
                let name = clip.assetID.flatMap { model.assets[$0]?.displayName } ?? "Clip"
                LabeledSlider(title: name, value: clip.volume, range: 0...1, format: { $0 < 0.005 ? "muted" : "\(Int($0 * 100))%" },
                              onEditingChanged: gesture("clipvol:\(clip.id)")) { value in
                    document.perform(.setClipVolume(id: clip.id, volume: value, wasVolume: clip.volume))
                }
            }
            HStack {
                Button("Mute all clips") {
                    for clip in videoClipsWithAudio where clip.volume > 0 {
                        document.perform(.setClipVolume(id: clip.id, volume: 0, wasVolume: clip.volume))
                    }
                }
                Spacer()
                Button("All clips 80%") {
                    for clip in videoClipsWithAudio {
                        document.perform(.setClipVolume(id: clip.id, volume: 0.8, wasVolume: clip.volume))
                    }
                }
            }
            .font(.system(.caption, design: .rounded, weight: .medium))
        } header: {
            Text("Sound from your clips")
        } footer: {
            Text("Video clips start muted so the music bed is clean. Raise a clip to hear its own audio; it dips under a voiceover like everything else.")
        }
    }

    // MARK: - Mix

    private var mixSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { timeline.duckMusicUnderVoice },
                set: { document.perform(.setDucking(enabled: $0, wasEnabled: timeline.duckMusicUnderVoice)) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Duck music under voice")
                    Text("Music and clip audio drop to about a quarter while a voiceover plays, with a short ramp either side.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            .tint(Theme.Palette.accent)
        } header: {
            Text("Mix")
        }
    }

    @ViewBuilder
    private var rhythmSection: some View {
        if model.musicBeatGrid != nil || model.recipe?.beatGrid != nil {
            Section {
                if let reference = model.recipe?.beatGrid {
                    LabeledContent("Reference tempo", value: "\(Int(reference.bpm.value.rounded())) BPM")
                    LabeledContent("Reference cuts", value: reference.cutsAlignedToBeats.value ? "on the beat" : "own timing")
                }
                if let music = model.musicBeatGrid {
                    LabeledContent("Your music", value: "\(Int(music.bpm.value.rounded())) BPM")
                    let aligned = BeatRetimer.alignment(of: timeline, toBeats: music.beats)
                    LabeledContent("Cuts on your beat", value: "\(Int((aligned * 100).rounded()))%")
                    Button {
                        if let result = model.snapCutsToMusic() {
                            note = String(format: "Moved %d cuts onto the beat (about %.0f ms each).", result.movedBoundaries, result.meanShift * 1000)
                        } else {
                            note = "Every cut is already on the beat."
                        }
                        Haptics.success()
                    } label: {
                        Label("Snap cuts to my music", systemImage: "metronome")
                    }
                } else if model.isAnalyzingMusic {
                    HStack { ProgressView().controlSize(.small); Text("Finding your track's beat…").font(Theme.Font.caption) }
                }
            } header: {
                Text("Rhythm")
            } footer: {
                Text(model.musicBeatGrid != nil
                     ? "The beat ticks on the timeline are your track's. Snapping moves each cut to the nearest beat within about a seventh of a second — one undo step."
                     : "Scene lengths were taken from the reference's rhythm. Add a track and its beats appear on the timeline.")
            }
        }
    }

    // MARK: - Actions

    private func gesture(_ key: String) -> (Bool) -> Void {
        { editing in
            if editing { document.beginGesture(key: key) } else { document.endGesture() }
        }
    }

    private func setRole(_ role: AudioRole, for clip: AudioClip) {
        // Role changes are structural for the mix, so they replace the clip.
        guard let index = timeline.audio.firstIndex(where: { $0.id == clip.id }) else { return }
        var updated = clip
        updated.role = role
        document.perform(.deleteAudioClip(index: index, clip: clip))
        document.perform(.addAudioClip(clip: updated))
    }

    private func addClip(asset: AssetReference, role: AudioRole, at start: Double) {
        let timelineDuration = timeline.duration
        let length = asset.duration > 0 ? asset.duration : timelineDuration
        let clip = AudioClip(
            assetID: asset.id,
            start: max(0, min(start, max(0, timelineDuration - 0.2))),
            duration: min(length, max(0.2, timelineDuration - start)),
            sourceStart: 0,
            volume: role == .reference && timeline.audio.contains { $0.role == .music } ? 0.5 : 1.0,
            fadeIn: role == .voice ? 0.02 : 0.15,
            fadeOut: role == .voice ? 0.05 : min(0.8, timelineDuration * 0.1),
            role: role
        )
        document.perform(.addAudioClip(clip: clip))
        expandedID = clip.id
    }

    private func addMusic(from url: URL) async {
        let (reference, importNote) = await MediaImport.importAudio(from: url)
        guard let reference else {
            note = importNote
            return
        }
        model.assets.add(reference)
        // Replace an existing music bed rather than layering: one music track is the whole
        // model here, and silently stacking a second under the first would be baffling. Other
        // roles are left alone.
        if let existing = timeline.audio.first(where: { $0.role == .music }),
           let index = timeline.audio.firstIndex(where: { $0.id == existing.id }) {
            document.perform(.deleteAudioClip(index: index, clip: existing))
        }
        model.content.musicAssetID = reference.id
        addClip(asset: reference, role: .music, at: 0)
        note = nil
        await model.analyzeMusic(reference)
    }
}
