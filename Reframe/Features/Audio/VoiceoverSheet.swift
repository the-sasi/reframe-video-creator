import ReframeKit
import SwiftUI

/// Record a voiceover: big red button, live meter, pause/resume, retake, use.
///
/// Returns the recorded asset via `onUse` — the caller decides whether it becomes the project's
/// voiceover (content screen) or an audio clip at the playhead (editor).
struct VoiceoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()
    @State private var errorText: String?

    /// Called with the finished recording. The reference is already in the pool.
    let onUse: (AssetReference) -> Void

    var body: some View {
        SheetScaffold(title: "Voiceover", detents: [.medium]) {
            VStack(spacing: Theme.Space.l) {
                Spacer(minLength: Theme.Space.s)

                meter

                Text(timecode)
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.Palette.primaryText)

                Text(statusLine)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40)

                if let errorText {
                    Text(errorText)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.danger)
                        .multilineTextAlignment(.center)
                }

                controls

                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
        }
        .onDisappear {
            if case .finished = recorder.state { return }
            recorder.discard()
        }
    }

    private var timecode: String {
        let seconds: Double
        if case .finished(_, let duration) = recorder.state { seconds = duration } else { seconds = recorder.elapsed }
        return PreviewPane.timecode(seconds)
    }

    private var statusLine: String {
        switch recorder.state {
        case .idle: return "Tap to start. Everything stays on this iPhone."
        case .recording: return "Recording… speak naturally."
        case .paused: return "Paused. Tap to continue or finish."
        case .finished: return "Done. Use it, or record again."
        }
    }

    private var meter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<24, id: \.self) { i in
                let threshold = Double(i) / 24
                let active = recorder.isRecording && recorder.level > threshold
                Capsule()
                    .fill(active ? Theme.Palette.accent : Theme.Palette.surfaceRaised)
                    .frame(width: 5, height: 10 + CGFloat(i % 5) * 6)
                    .animation(.linear(duration: 0.06), value: active)
            }
        }
        .frame(height: 44)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            RecordButton(systemImage: "mic.fill", tint: Theme.Palette.danger) {
                Task {
                    do { try await recorder.start(); errorText = nil }
                    catch let error as ReframeError { errorText = error.presentation.message; if case .microphoneDenied = error { model.present(error) } }
                    catch { errorText = "\(error)" }
                }
            }
        case .recording:
            HStack(spacing: Theme.Space.xl) {
                RecordButton(systemImage: "pause.fill", tint: Theme.Palette.secondaryText, size: 56) { recorder.pause() }
                RecordButton(systemImage: "stop.fill", tint: Theme.Palette.danger) { _ = recorder.stop() }
            }
        case .paused:
            HStack(spacing: Theme.Space.xl) {
                RecordButton(systemImage: "mic.fill", tint: Theme.Palette.danger, size: 56) { recorder.resume() }
                RecordButton(systemImage: "stop.fill", tint: Theme.Palette.secondaryText) { _ = recorder.stop() }
            }
        case .finished(_, let duration):
            VStack(spacing: Theme.Space.s) {
                PrimaryButton(title: "Use This Take", systemImage: "checkmark") {
                    guard let path = relativePath else { return }
                    let reference = AssetReference(
                        kind: .audio, origin: .sandboxRelativePath(path),
                        displayName: "Voiceover \(Date().formatted(date: .omitted, time: .shortened))",
                        pixelWidth: 0, pixelHeight: 0, duration: duration
                    )
                    model.assets.add(reference)
                    onUse(reference)
                    Haptics.success()
                    dismiss()
                }
                Button("Record again") { recorder.discard() }
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .minimumHitTarget()
            }
        }
    }

    private var relativePath: String? {
        guard case .finished(let url, _) = recorder.state else { return nil }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(documents) else { return nil }
        return String(full.dropFirst(documents.count).drop(while: { $0 == "/" }))
    }
}

private struct RecordButton: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 76
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint, in: Circle())
                .shadow(color: tint.opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .pressable()
    }
}
