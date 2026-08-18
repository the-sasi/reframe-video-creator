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
    /// Optional so the pane can be used without an editable document.
    var document: TimelineDocument?
    var currentTime: Double = 0
    @Binding var selectedTextID: UUID?

    init(
        engine: PreviewEngine,
        document: TimelineDocument? = nil,
        currentTime: Double = 0,
        selectedTextID: Binding<UUID?> = .constant(nil)
    ) {
        self.engine = engine
        self.document = document
        self.currentTime = currentTime
        self._selectedTextID = selectedTextID
    }

    var body: some View {
        GeometryReader { geometry in
            // The overlay must agree with the MTKView to the pixel, so both are laid out from
            // the same fitted size rather than one using `.aspectRatio` and the other guessing.
            let fitted = fittedCanvasSize(
                container: geometry.size, canvas: engine.timeline.canvas
            )

            ZStack {
                Color.black

                PreviewSurface(engine: engine)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    )
                    .onTapGesture {
                        selectedTextID = nil
                        engine.togglePlayback()
                    }

                if let document {
                    TextOverlayEditor(
                        document: document,
                        currentTime: currentTime,
                        selectedTextID: $selectedTextID,
                        canvasSize: fitted
                    )
                }

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
            .frame(width: geometry.size.width, height: geometry.size.height)
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
