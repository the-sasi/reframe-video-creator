import MetalKit
import ReframeKit
import SwiftUI

/// Hosts the `MTKView` the preview engine draws into.
///
/// The view *is* the clock: `MTKViewDelegate.draw(in:)` fires at the display rate, advances
/// time, and renders one plan — the same `plan()`/`render()` pair the exporter calls.
struct PreviewSurface: UIViewRepresentable {
    let engine: PreviewEngine

    func makeUIView(context: Context) -> MTKView {
        let view = engine.makeView()
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

/// Preview plus transport, sized to the canvas aspect ratio.
struct PreviewPane: View {
    let engine: PreviewEngine
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            Color.black

            PreviewSurface(engine: engine)
                .aspectRatio(
                    Double(engine.timeline.canvas.width) / Double(engine.timeline.canvas.height),
                    contentMode: .fit
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .onTapGesture { engine.togglePlayback() }

            if let error = engine.lastError {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .light))
                    Text(error.presentation.title)
                        .font(Theme.Font.callout)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .overlay(alignment: .bottom) {
            transport
        }
    }

    private var transport: some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                engine.togglePlayback()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .minimumHitTarget()
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            Text(Self.timecode(engine.currentTime))
                .font(.system(.caption, design: .rounded, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            Text("/")
                .font(Theme.Font.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text(Self.timecode(engine.duration))
                .font(.system(.caption, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}
