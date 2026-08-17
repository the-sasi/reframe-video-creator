import ReframeKit
import SwiftUI
import UIKit

/// The timeline.
///
/// UIKit, not SwiftUI. This is the most latency-sensitive interaction in the app and it needs
/// precise control over scroll offset, deceleration and a continuous pinch-driven time base —
/// things SwiftUI's gesture composition does not expose well, and where the consensus for
/// intricate scrubbing widgets remains UIKit.
///
/// The playhead is **fixed at centre** and the timeline moves under it. Scrubbing then costs no
/// hand-eye tracking and works one-handed, which is the whole reason for the inversion.
struct TimelineView: UIViewRepresentable {

    let timeline: Timeline
    let beatGrid: BeatGrid?
    @Binding var currentTime: Double
    @Binding var selectedClipID: UUID?
    let isPlaying: Bool
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void
    let onSelect: (UUID?) -> Void

    func makeUIView(context: Context) -> TimelineScrollView {
        let view = TimelineScrollView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        view.configure(timeline: timeline, beatGrid: beatGrid)
        return view
    }

    func updateUIView(_ uiView: TimelineScrollView, context: Context) {
        context.coordinator.parent = self
        uiView.configure(timeline: timeline, beatGrid: beatGrid)
        uiView.selectedClipID = selectedClipID
        // Only drive the scroll position from the model while playing. During a drag the
        // gesture owns the offset, and writing it back would fight the user's finger.
        if isPlaying || !uiView.isTracking {
            uiView.setTime(currentTime, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        var parent: TimelineView
        weak var view: TimelineScrollView?

        init(parent: TimelineView) {
            self.parent = parent
        }

        func timeChanged(_ time: Double, isUserDriven: Bool) {
            guard isUserDriven else { return }
            parent.onScrub(time)
        }

        func scrubEnded() {
            parent.onScrubEnd()
        }

        func selected(_ id: UUID?) {
            parent.onSelect(id)
        }
    }
}

/// The scroll view itself.
@MainActor
final class TimelineScrollView: UIView, UIScrollViewDelegate {

    weak var coordinator: TimelineView.Coordinator?

    private let scrollView = UIScrollView()
    private let contentView = TimelineContentView()
    private let playheadLine = UIView()

    private var timeline = Timeline()
    private var beatGrid: BeatGrid?
    private var snapTargets: [SnapTarget] = []

    /// Seconds per point. Pinch changes this; 0.5s–40s visible across the width.
    private var secondsPerPoint: Double = 0.02
    private var isApplyingProgrammaticOffset = false

    /// Whether a finger is currently on the timeline. `updateUIView` checks this so the model
    /// never writes the scroll offset out from under an in-progress drag.
    var isTracking: Bool { scrollView.isTracking || scrollView.isDragging }

    var selectedClipID: UUID? {
        didSet {
            guard oldValue != selectedClipID else { return }
            contentView.selectedClipID = selectedClipID
            contentView.setNeedsDisplay()
        }
    }

    // Track heights: video strip dominates, text and audio are thin ribbons. Three lanes
    // maximum on screen — a denser timeline on a phone is a desktop idea.
    static let videoTrackHeight: CGFloat = 56
    static let textTrackHeight: CGFloat = 18
    static let audioTrackHeight: CGFloat = 22
    static let trackSpacing: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        scrollView.addSubview(contentView)

        // The playhead is a fixed centre line, not a moving marker.
        playheadLine.backgroundColor = UIColor(Theme.Palette.accent)
        playheadLine.layer.cornerRadius = 1
        addSubview(playheadLine)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        scrollView.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        playheadLine.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        updateContentSize()
    }

    func configure(timeline: Timeline, beatGrid: BeatGrid?) {
        let changed = timeline != self.timeline
        self.timeline = timeline
        self.beatGrid = beatGrid
        guard changed else { return }

        snapTargets = timeline.snapTargets(beatGrid: beatGrid)
        contentView.timeline = timeline
        contentView.beatGrid = beatGrid
        contentView.secondsPerPoint = secondsPerPoint
        contentView.setNeedsDisplay()
        updateContentSize()
    }

    private func updateContentSize() {
        guard bounds.width > 0 else { return }
        let width = CGFloat(max(timeline.duration, 0.1) / secondsPerPoint)
        let height = Self.videoTrackHeight + Self.textTrackHeight + Self.audioTrackHeight
            + Self.trackSpacing * 2

        contentView.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
        scrollView.contentSize = CGSize(width: width, height: bounds.height)
        // Half-width insets at both ends: the playhead can reach 0 and the true end.
        scrollView.contentInset = UIEdgeInsets(
            top: 0, left: bounds.width / 2, bottom: 0, right: bounds.width / 2
        )
    }

    // MARK: - Time <-> offset

    var currentTime: Double {
        Double(scrollView.contentOffset.x + bounds.width / 2) * secondsPerPoint
    }

    func setTime(_ time: Double, animated: Bool) {
        guard bounds.width > 0 else { return }
        let x = CGFloat(time / secondsPerPoint) - bounds.width / 2
        guard abs(x - scrollView.contentOffset.x) > 0.5 else { return }
        isApplyingProgrammaticOffset = true
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
        isApplyingProgrammaticOffset = false
    }

    // MARK: - Gestures

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let anchorTime = currentTime
            let proposed = secondsPerPoint / Double(gesture.scale)
            // Clamp to a sensible visible span rather than to raw zoom, so the limits mean the
            // same thing on every device width.
            let visibleSpan = proposed * Double(bounds.width)
            guard visibleSpan > 0.5, visibleSpan < 40 else {
                gesture.scale = 1
                return
            }
            secondsPerPoint = proposed
            contentView.secondsPerPoint = secondsPerPoint
            contentView.setNeedsDisplay()
            updateContentSize()
            setTime(anchorTime, animated: false)
            gesture.scale = 1

        case .ended, .cancelled:
            coordinator?.scrubEnded()

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: contentView).x
        let time = Double(x) * secondsPerPoint
        let tapped = timeline.clips.first { time >= $0.start && time < $0.end }
        selectedClipID = tapped?.id
        Haptics.grab()
        coordinator?.selected(tapped?.id)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingProgrammaticOffset else { return }
        coordinator?.timeChanged(currentTime, isUserDriven: scrollView.isTracking || scrollView.isDecelerating)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { snapToNearestTarget() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        snapToNearestTarget()
    }

    /// Snaps to clip boundaries and beats. The threshold scales with zoom so snapping feels the
    /// same at every scale, and it fires a soft haptic — the beat grid is felt as much as seen.
    private func snapToNearestTarget() {
        let time = currentTime
        let threshold = secondsPerPoint * 12

        guard let nearest = snapTargets.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(nearest.time - time) < threshold,
              abs(nearest.time - time) > 0.001 else {
            coordinator?.scrubEnded()
            return
        }

        setTime(nearest.time, animated: true)
        coordinator?.timeChanged(nearest.time, isUserDriven: true)
        Haptics.snap()
        coordinator?.scrubEnded()
    }
}

/// Draws the tracks. `draw(_:)` rather than a view hierarchy: a 40-clip timeline would otherwise
/// be a few hundred views to lay out on every zoom step.
@MainActor
final class TimelineContentView: UIView {

    var timeline = Timeline()
    var beatGrid: BeatGrid?
    var secondsPerPoint: Double = 0.02
    var selectedClipID: UUID?

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let videoHeight = TimelineScrollView.videoTrackHeight
        let textHeight = TimelineScrollView.textTrackHeight
        let audioHeight = TimelineScrollView.audioTrackHeight
        let spacing = TimelineScrollView.trackSpacing

        func x(_ time: Double) -> CGFloat { CGFloat(time / secondsPerPoint) }

        // --- Beat ticks, behind everything ---
        if let beats = beatGrid?.beats {
            context.setStrokeColor(UIColor(Theme.Palette.accent).withAlphaComponent(0.28).cgColor)
            context.setLineWidth(1)
            for beat in beats {
                let px = x(beat)
                guard px >= rect.minX - 2, px <= rect.maxX + 2 else { continue }
                context.move(to: CGPoint(x: px, y: 0))
                context.addLine(to: CGPoint(x: px, y: bounds.height))
            }
            context.strokePath()
        }

        // --- Video clips ---
        for clip in timeline.clips {
            let frame = CGRect(
                x: x(clip.start), y: 0,
                width: max(2, x(clip.duration)), height: videoHeight
            )
            guard frame.intersects(rect.insetBy(dx: -40, dy: 0)) else { continue }

            let isSelected = clip.id == selectedClipID
            let path = UIBezierPath(
                roundedRect: frame.insetBy(dx: 1, dy: 0), cornerRadius: 6
            )
            context.setFillColor(
                UIColor(isSelected ? Theme.Palette.accent.opacity(0.35) : Theme.Palette.surfaceRaised).cgColor
            )
            context.addPath(path.cgPath)
            context.fillPath()

            if isSelected {
                context.setStrokeColor(UIColor(Theme.Palette.accent).cgColor)
                context.setLineWidth(2)
                context.addPath(path.cgPath)
                context.strokePath()
            }

            // Transition marker at the incoming edge.
            if let transition = clip.transitionIn, transition.kind != .cut {
                let markerWidth = min(frame.width * 0.4, max(6, x(transition.duration)))
                let marker = CGRect(x: frame.minX, y: 0, width: markerWidth, height: videoHeight)
                context.setFillColor(UIColor.white.withAlphaComponent(0.12).cgColor)
                context.fill(marker)
            }

            // Only label clips wide enough to read; a 0.3s clip at low zoom has no room.
            if frame.width > 34 {
                let label = clip.assetID == nil ? "empty" : (clip.slotID ?? "clip")
                drawLabel(label, in: frame.insetBy(dx: 6, dy: 6), context: context)
            }
        }

        // --- Text chips ---
        let textY = videoHeight + spacing
        for layer in timeline.textLayers {
            let frame = CGRect(
                x: x(layer.start), y: textY,
                width: max(4, x(layer.duration)), height: textHeight
            )
            guard frame.intersects(rect.insetBy(dx: -40, dy: 0)) else { continue }
            let path = UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 2), cornerRadius: 4)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.32).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
            if frame.width > 44 {
                drawLabel(layer.text, in: frame.insetBy(dx: 5, dy: 2), context: context, size: 9)
            }
        }

        // --- Audio ---
        let audioY = textY + textHeight + spacing
        for clip in timeline.audio {
            let frame = CGRect(
                x: x(clip.start), y: audioY,
                width: max(4, x(clip.duration)), height: audioHeight
            )
            let path = UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 2), cornerRadius: 4)
            context.setFillColor(UIColor.systemGreen.withAlphaComponent(0.28).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }

    private func drawLabel(
        _ text: String, in rect: CGRect, context: CGContext, size: CGFloat = 10
    ) {
        // Dynamic Type reaches the timeline too — the time labels and clip names scale with the
        // user's setting rather than being fixed points.
        let scaled = UIFontMetrics(forTextStyle: .caption2).scaledValue(for: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: scaled, weight: .medium),
            .foregroundColor: UIColor(Theme.Palette.secondaryText),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(with: rect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], context: nil)
    }
}
