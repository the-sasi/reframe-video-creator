import ReframeKit
import SwiftUI

/// Direct manipulation of text on the preview.
///
/// The sheet works but is a column of sliders, which is a poor way to answer "is it in the
/// right place" — you adjust, look away to the preview, adjust again. Dragging the thing itself
/// closes that loop, and it is how every editor people already know behaves.
///
/// Overlaid on the preview at exactly the canvas's fitted rect, so a box drawn here lands where
/// the renderer will draw the glyphs.
struct TextOverlayEditor: View {
    let document: TimelineDocument
    let currentTime: Double
    @Binding var selectedTextID: UUID?

    /// The preview's fitted rect, in this view's coordinate space.
    let canvasSize: CGSize

    @State private var dragStartFrame: NormalizedRect?
    @State private var overlayDragStart: NormalizedRect?
    @State private var overlayResizeStart: NormalizedRect?
    @State private var selectedOverlayID: UUID?

    private var visibleLayers: [TextLayer] {
        document.timeline.textLayers.filter { $0.isVisible(at: currentTime) }
    }

    private var visibleOverlays: [OverlayLayer] {
        document.timeline.overlays.filter { $0.isVisible(at: currentTime) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Logos and stickers: drag to move, corner handle to resize. Below the text boxes
            // so a caption over a logo stays grabbable.
            ForEach(visibleOverlays) { overlay in
                let rect = CGRect(
                    x: overlay.frame.x * canvasSize.width, y: overlay.frame.y * canvasSize.height,
                    width: max(30, overlay.frame.width * canvasSize.width),
                    height: max(30, overlay.frame.height * canvasSize.height)
                )
                let isSelected = selectedOverlayID == overlay.id
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Palette.accent : .white.opacity(0.35),
                                  style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [4, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Circle()
                                .fill(Theme.Palette.accent)
                                .frame(width: 18, height: 18)
                                .overlay { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Palette.onAccent) }
                                .offset(x: 9, y: 9)
                                .gesture(resizeGesture(for: overlay))
                        }
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(overlayDragGesture(for: overlay))
                    .onTapGesture {
                        withAnimation(Theme.Motion.quick) {
                            selectedOverlayID = isSelected ? nil : overlay.id
                            if !isSelected { selectedTextID = nil }
                        }
                        Haptics.grab()
                    }
                    .accessibilityLabel("Logo")
                    .accessibilityHint("Drag to reposition; drag the corner to resize")
            }

            ForEach(visibleLayers) { layer in
                let rect = screenRect(for: layer)
                let isSelected = selectedTextID == layer.id

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.Palette.accent : .white.opacity(0.45),
                        style: StrokeStyle(
                            lineWidth: isSelected ? 2 : 1,
                            dash: isSelected ? [] : [4, 4]
                        )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Theme.Palette.accent.opacity(0.12) : .clear)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        if isSelected {
                            Text(layer.text)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.Palette.onAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.Palette.accent, in: Capsule())
                                .offset(y: -20)
                                .lineLimit(1)
                        }
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(dragGesture(for: layer))
                    .onTapGesture {
                        withAnimation(Theme.Motion.quick) {
                            selectedTextID = isSelected ? nil : layer.id
                        }
                        Haptics.grab()
                    }
                    .accessibilityLabel("Text: \(layer.text)")
                    .accessibilityHint("Drag to reposition")
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        // Only intercept touches on the boxes themselves, so tapping elsewhere still
        // play/pauses the preview.
        .allowsHitTesting(!visibleLayers.isEmpty || !visibleOverlays.isEmpty)
    }

    private func overlayDragGesture(for overlay: OverlayLayer) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if overlayDragStart == nil {
                    overlayDragStart = overlay.frame
                    selectedOverlayID = overlay.id
                    document.beginGesture(key: "overlayframe:\(overlay.id)")
                    Haptics.grab()
                }
                guard let start = overlayDragStart else { return }
                var frame = start
                frame.x = min(max(0, start.x + value.translation.width / canvasSize.width), 1 - start.width)
                frame.y = min(max(0, start.y + value.translation.height / canvasSize.height), 1 - start.height)
                document.perform(.setOverlayFrame(id: overlay.id, frame: frame, wasFrame: start))
            }
            .onEnded { _ in
                document.endGesture()
                overlayDragStart = nil
                Haptics.snap()
            }
    }

    /// Corner handle: scales the overlay about its top-left, keeping its aspect.
    private func resizeGesture(for overlay: OverlayLayer) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if overlayResizeStart == nil {
                    overlayResizeStart = overlay.frame
                    document.beginGesture(key: "overlayframe:\(overlay.id)")
                }
                guard let start = overlayResizeStart else { return }
                let aspect = start.height > 0 ? start.width / start.height : 1
                let widthPoints = start.width * canvasSize.width + value.translation.width
                let width = min(1 - start.x, max(0.05, widthPoints / canvasSize.width))
                let height = min(1 - start.y, width / max(aspect, 0.01) * (canvasSize.width / canvasSize.height))
                document.perform(.setOverlayFrame(
                    id: overlay.id,
                    frame: NormalizedRect(x: start.x, y: start.y, width: width, height: height),
                    wasFrame: start
                ))
            }
            .onEnded { _ in
                document.endGesture()
                overlayResizeStart = nil
                Haptics.snap()
            }
    }

    private func screenRect(for layer: TextLayer) -> CGRect {
        CGRect(
            x: layer.frame.x * canvasSize.width,
            y: layer.frame.y * canvasSize.height,
            width: max(44, layer.frame.width * canvasSize.width),
            height: max(30, layer.frame.height * canvasSize.height)
        )
    }

    private func dragGesture(for layer: TextLayer) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = layer.frame
                    selectedTextID = layer.id
                    // One undo step for the whole drag, not one per frame of movement.
                    document.beginGesture(key: "textframe:\(layer.id)")
                    Haptics.grab()
                }
                guard let start = dragStartFrame else { return }

                var frame = start
                frame.x = min(max(0, start.x + value.translation.width / canvasSize.width), 1 - start.width)
                frame.y = min(max(0, start.y + value.translation.height / canvasSize.height), 1 - start.height)

                document.perform(
                    .setTextFrame(id: layer.id, frame: frame, wasFrame: start)
                )
            }
            .onEnded { _ in
                document.endGesture()
                dragStartFrame = nil
                Haptics.snap()
            }
    }
}

/// Computes where the canvas actually sits inside a container, matching `.scaledToFit`.
///
/// The overlay has to agree with the `MTKView` to the pixel, otherwise a box drawn here is not
/// where the text is.
func fittedCanvasSize(container: CGSize, canvas: CanvasSpec) -> CGSize {
    guard container.width > 0, container.height > 0, canvas.height > 0 else { return .zero }
    let canvasAspect = CGFloat(canvas.width) / CGFloat(canvas.height)
    let containerAspect = container.width / container.height

    if containerAspect > canvasAspect {
        let height = container.height
        return CGSize(width: height * canvasAspect, height: height)
    }
    let width = container.width
    return CGSize(width: width, height: width / canvasAspect)
}
