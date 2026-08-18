import ReframeKit
import SwiftUI
import UIKit

/// What is selected in the editor. Drives the contextual toolbar and the timeline highlight.
enum EditorSelection: Hashable {
    case clip(UUID)
    case text(UUID)
    case audio(UUID)

    var clipID: UUID? { if case .clip(let id) = self { return id } else { return nil } }
    var textID: UUID? { if case .text(let id) = self { return id } else { return nil } }
    var audioID: UUID? { if case .audio(let id) = self { return id } else { return nil } }
}

/// Everything the timeline needs to talk back to the editor.
struct TimelineActions {
    var onScrub: (Double) -> Void
    var onScrubEnd: () -> Void
    var onSelect: (EditorSelection?) -> Void
    var perform: (EditCommand) -> Void
    var beginGesture: (String) -> Void
    var endGesture: () -> Void
}

/// The timeline.
///
/// UIKit, not SwiftUI. This is the most latency-sensitive interaction in the app and it needs
/// precise control over scroll offset, deceleration and a continuous pinch-driven time base —
/// things SwiftUI's gesture composition does not expose well, and where the consensus for
/// intricate scrubbing widgets remains UIKit.
///
/// The playhead is **fixed at centre** and the timeline moves under it. Scrubbing then costs no
/// hand-eye tracking and works one-handed, which is the whole reason for the inversion.
///
/// Direct manipulation on the tracks: tap selects; a selected clip grows trim handles that drag;
/// long-press-and-drag reorders clips; text chips and audio blocks drag to move and trim at
/// their edges. Every gesture is one undo step.
struct TimelineView: UIViewRepresentable {

    let timeline: Timeline
    let assets: AssetPool
    let beatGrid: BeatGrid?
    let waveforms: [UUID: Waveform]
    let currentTime: Double
    let selection: EditorSelection?
    let isPlaying: Bool
    let actions: TimelineActions

    /// Height the editor should give the timeline for this document.
    static func preferredHeight(for timeline: Timeline) -> CGFloat {
        TimelineScrollView.contentHeight(for: timeline) + 20
    }

    func makeUIView(context: Context) -> TimelineScrollView {
        let view = TimelineScrollView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        view.configure(timeline: timeline, assets: assets, beatGrid: beatGrid, waveforms: waveforms)
        return view
    }

    func updateUIView(_ uiView: TimelineScrollView, context: Context) {
        context.coordinator.parent = self
        uiView.configure(timeline: timeline, assets: assets, beatGrid: beatGrid, waveforms: waveforms)
        uiView.selection = selection
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
    }
}

// MARK: - Scroll view

@MainActor
final class TimelineScrollView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    weak var coordinator: TimelineView.Coordinator?

    private let scrollView = UIScrollView()
    private let contentView = TimelineContentView()
    private let playheadLine = UIView()
    private let playheadKnob = UIView()

    private var timeline = Timeline()
    private var assets = AssetPool()
    private var beatGrid: BeatGrid?
    private var snapTargets: [SnapTarget] = []

    /// Seconds per point. Pinch changes this; 0.5s–40s visible across the width.
    private var secondsPerPoint: Double = 0.012
    private var isApplyingProgrammaticOffset = false

    var isTracking: Bool { scrollView.isTracking || scrollView.isDragging || activeGesture != nil }

    var selection: EditorSelection? {
        didSet {
            guard oldValue != selection else { return }
            contentView.selection = selection
            contentView.setNeedsDisplay()
        }
    }

    // Track geometry.
    static let rulerHeight: CGFloat = 16
    static let videoTrackHeight: CGFloat = 54
    static let textTrackHeight: CGFloat = 20
    static let audioTrackHeight: CGFloat = 26
    static let trackSpacing: CGFloat = 5
    static let handleWidth: CGFloat = 16

    static func audioLanes(for timeline: Timeline) -> [AudioRole] {
        var lanes: [AudioRole] = []
        for clip in timeline.audio where !lanes.contains(clip.role) { lanes.append(clip.role) }
        return Array(lanes.prefix(3))
    }

    static func contentHeight(for timeline: Timeline) -> CGFloat {
        let lanes = CGFloat(max(1, audioLanes(for: timeline).count))
        return rulerHeight + videoTrackHeight + trackSpacing + textTrackHeight
            + lanes * (audioTrackHeight + trackSpacing)
    }

    // Gestures.
    private enum ActiveGesture {
        case trimClip(id: UUID, edge: Edge, startDuration: Double, startSource: Double, startX: CGFloat)
        case reorderClip(id: UUID, fromIndex: Int, targetIndex: Int)
        case moveText(id: UUID, startStart: Double, startEnd: Double, startX: CGFloat)
        case trimText(id: UUID, edge: Edge, startStart: Double, startEnd: Double, startX: CGFloat)
        case moveAudio(id: UUID, startStart: Double, startX: CGFloat)
        case trimAudio(id: UUID, edge: Edge, startStart: Double, startDuration: Double, startSource: Double, startX: CGFloat)
    }
    private enum Edge { case leading, trailing }
    private var activeGesture: ActiveGesture?
    private var trimPan: UIPanGestureRecognizer!
    private var reorderPress: UILongPressGestureRecognizer!

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
        contentView.host = self
        scrollView.addSubview(contentView)

        // The playhead is a fixed centre line, not a moving marker.
        playheadLine.backgroundColor = UIColor(Theme.Palette.accent)
        playheadLine.layer.cornerRadius = 1
        playheadLine.isUserInteractionEnabled = false
        addSubview(playheadLine)
        playheadKnob.backgroundColor = UIColor(Theme.Palette.accent)
        playheadKnob.layer.cornerRadius = 4
        playheadKnob.isUserInteractionEnabled = false
        addSubview(playheadKnob)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        scrollView.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tap)

        // Trim / move: a pan that only begins on a handle or a movable block, and which the
        // scroll view's own pan must yield to.
        trimPan = UIPanGestureRecognizer(target: self, action: #selector(handleTrimPan(_:)))
        trimPan.delegate = self
        trimPan.maximumNumberOfTouches = 1
        contentView.addGestureRecognizer(trimPan)
        scrollView.panGestureRecognizer.require(toFail: trimPan)

        // Reorder: long-press a clip, then drag.
        reorderPress = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
        reorderPress.minimumPressDuration = 0.35
        reorderPress.delegate = self
        contentView.addGestureRecognizer(reorderPress)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        playheadLine.frame = CGRect(x: bounds.midX - 1, y: 4, width: 2, height: bounds.height - 8)
        playheadKnob.frame = CGRect(x: bounds.midX - 4, y: 0, width: 8, height: 8)
        updateContentSize()
    }

    func configure(timeline: Timeline, assets: AssetPool, beatGrid: BeatGrid?, waveforms: [UUID: Waveform]) {
        let changed = timeline != self.timeline || assets != self.assets
        let waveformsChanged = waveforms.count != contentView.waveforms.count
        self.timeline = timeline
        self.assets = assets
        self.beatGrid = beatGrid
        contentView.waveforms = waveforms
        guard changed || waveformsChanged else { return }

        snapTargets = timeline.snapTargets(beatGrid: beatGrid)
        contentView.timeline = timeline
        contentView.assets = assets
        contentView.beatGrid = beatGrid
        contentView.secondsPerPoint = secondsPerPoint
        contentView.setNeedsDisplay()
        contentView.loadThumbnails()
        updateContentSize()
    }

    private func updateContentSize() {
        guard bounds.width > 0 else { return }
        let width = CGFloat(max(timeline.duration, 0.1) / secondsPerPoint)
        let height = Self.contentHeight(for: timeline)

        contentView.frame = CGRect(x: 0, y: max(0, (bounds.height - height) / 2), width: width, height: height)
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

    private func time(atContentX x: CGFloat) -> Double { Double(x) * secondsPerPoint }
    private func x(atTime t: Double) -> CGFloat { CGFloat(t / secondsPerPoint) }

    // MARK: - Hit testing

    private enum Hit {
        case clip(VideoClip, index: Int, edge: Edge?)
        case text(TextLayer, edge: Edge?)
        case audio(AudioClip, edge: Edge?)
    }

    private func hit(at point: CGPoint) -> Hit? {
        let t = time(atContentX: point.x)
        let y = point.y - Self.rulerHeight
        let videoBottom = Self.videoTrackHeight
        let textTop = videoBottom + Self.trackSpacing
        let textBottom = textTop + Self.textTrackHeight
        let audioTop = textBottom + Self.trackSpacing
        let handleSeconds = Double(Self.handleWidth) * secondsPerPoint

        if y >= 0, y < videoBottom {
            guard let index = timeline.clips.firstIndex(where: { t >= $0.start && t < $0.end }) else { return nil }
            let clip = timeline.clips[index]
            var edge: Edge?
            if selection == .clip(clip.id) {
                if t - clip.start < handleSeconds { edge = .leading }
                else if clip.end - t < handleSeconds { edge = .trailing }
            }
            return .clip(clip, index: index, edge: edge)
        }
        if y >= textTop, y < textBottom {
            guard let layer = timeline.textLayers.last(where: { t >= $0.start && t < $0.end }) else { return nil }
            var edge: Edge?
            if t - layer.start < handleSeconds { edge = .leading }
            else if layer.end - t < handleSeconds { edge = .trailing }
            return .text(layer, edge: edge)
        }
        if y >= audioTop {
            let lanes = Self.audioLanes(for: timeline)
            let laneIndex = Int((y - audioTop) / (Self.audioTrackHeight + Self.trackSpacing))
            guard laneIndex >= 0, laneIndex < lanes.count else { return nil }
            let role = lanes[laneIndex]
            guard let clip = timeline.audio.last(where: { $0.role == role && t >= $0.start && t < $0.end }) else { return nil }
            var edge: Edge?
            if t - clip.start < handleSeconds { edge = .leading }
            else if clip.end - t < handleSeconds { edge = .trailing }
            return .audio(clip, edge: edge)
        }
        return nil
    }

    // MARK: - Gestures

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: contentView)
        if gestureRecognizer === trimPan {
            // Only vertical-ish or edge/handle starts. Horizontal pans over empty track scroll.
            guard let hit = hit(at: point) else { return false }
            switch hit {
            case .clip(_, _, let edge): return edge != nil
            case .text(let layer, _): return selection == .text(layer.id)
            case .audio(let clip, _): return selection == .audio(clip.id)
            }
        }
        if gestureRecognizer === reorderPress {
            if case .clip? = hit(at: point) { return timeline.clips.count > 1 }
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

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
            coordinator?.parent.actions.onScrubEnd()

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        let hit = hit(at: point)
        let newSelection: EditorSelection?
        switch hit {
        case .clip(let clip, _, _): newSelection = .clip(clip.id)
        case .text(let layer, _): newSelection = .text(layer.id)
        case .audio(let clip, _): newSelection = .audio(clip.id)
        case nil: newSelection = nil
        }
        // Tapping the selected thing again deselects; tapping elsewhere moves the selection.
        let resolved = newSelection == selection ? nil : newSelection
        selection = resolved
        Haptics.grab()
        coordinator?.parent.actions.onSelect(resolved)
    }

    @objc private func handleTrimPan(_ gesture: UIPanGestureRecognizer) {
        guard let actions = coordinator?.parent.actions else { return }
        let point = gesture.location(in: contentView)

        switch gesture.state {
        case .began:
            guard let hit = hit(at: point) else { gesture.state = .cancelled; return }
            switch hit {
            case .clip(let clip, _, let edge):
                guard let edge else { gesture.state = .cancelled; return }
                activeGesture = .trimClip(id: clip.id, edge: edge, startDuration: clip.duration, startSource: clip.sourceStart, startX: point.x)
                actions.beginGesture("trim:\(clip.id)")
            case .text(let layer, let edge):
                if let edge {
                    activeGesture = .trimText(id: layer.id, edge: edge, startStart: layer.start, startEnd: layer.end, startX: point.x)
                } else {
                    activeGesture = .moveText(id: layer.id, startStart: layer.start, startEnd: layer.end, startX: point.x)
                }
                actions.beginGesture("texttime:\(layer.id)")
            case .audio(let clip, let edge):
                if let edge {
                    activeGesture = .trimAudio(id: clip.id, edge: edge, startStart: clip.start, startDuration: clip.duration, startSource: clip.sourceStart, startX: point.x)
                } else {
                    activeGesture = .moveAudio(id: clip.id, startStart: clip.start, startX: point.x)
                }
                actions.beginGesture("audiotime:\(clip.id)")
            }
            Haptics.grab()

        case .changed:
            guard let activeGesture else { return }
            let deltaSeconds = time(atContentX: point.x) - time(atContentX: startX(of: activeGesture))
            applyGesture(activeGesture, delta: deltaSeconds, actions: actions)

        case .ended, .cancelled, .failed:
            actions.endGesture()
            activeGesture = nil
            contentView.setNeedsDisplay()

        default:
            break
        }
    }

    private func startX(of gesture: ActiveGesture) -> CGFloat {
        switch gesture {
        case .trimClip(_, _, _, _, let x), .moveText(_, _, _, let x), .trimText(_, _, _, _, let x),
             .moveAudio(_, _, let x), .trimAudio(_, _, _, _, _, let x):
            return x
        case .reorderClip:
            return 0
        }
    }

    /// Snaps a candidate time to the nearest target within a zoom-scaled threshold.
    private func snapped(_ time: Double, excluding: Set<Double> = []) -> Double {
        let threshold = secondsPerPoint * 10
        var candidates = snapTargets.map(\.time)
        candidates.append(currentTime)  // the playhead is always a target
        let nearest = candidates
            .filter { !excluding.contains($0) }
            .min { abs($0 - time) < abs($1 - time) }
        if let nearest, abs(nearest - time) < threshold {
            if abs(nearest - time) > 0.001 { Haptics.snap() }
            return nearest
        }
        return time
    }

    private func applyGesture(_ gesture: ActiveGesture, delta: Double, actions: TimelineActions) {
        let frame = timeline.canvas.frameDuration
        switch gesture {
        case .trimClip(let id, let edge, let startDuration, let startSource, _):
            guard let clip = timeline.clip(id: id) else { return }
            let asset = clip.assetID.flatMap { assets[$0] }
            let isVideo = asset?.kind == .video
            let sourceLength = asset?.duration ?? .infinity
            switch edge {
            case .trailing:
                var end = snapped(clip.start + startDuration + delta, excluding: [clip.start + startDuration])
                if isVideo, sourceLength.isFinite {
                    end = min(end, clip.start + (sourceLength - clip.sourceStart) / max(0.01, clip.speed))
                }
                let duration = max(frame * 2, end - clip.start)
                actions.perform(.trimClip(id: id, duration: duration, sourceStart: clip.sourceStart,
                                          wasDuration: startDuration, wasSourceStart: startSource))
            case .leading:
                // Dragging the leading edge trims the front: shorter duration, later source start
                // for video. The clip's timeline start stays put (relayout keeps things gapless).
                var trimmed = delta
                trimmed = max(-startSource / max(0.01, clip.speed) * (isVideo ? 1 : 0), trimmed)  // stills can't reveal earlier
                trimmed = min(startDuration - frame * 2, trimmed)
                let duration = startDuration - trimmed
                let source = isVideo ? startSource + trimmed * clip.speed : 0
                actions.perform(.trimClip(id: id, duration: duration, sourceStart: source,
                                          wasDuration: startDuration, wasSourceStart: startSource))
            }

        case .moveText(let id, let startStart, let startEnd, _):
            let length = startEnd - startStart
            var start = snapped(startStart + delta)
            start = min(max(0, start), max(0, timeline.duration - length))
            actions.perform(.setTextTiming(id: id, start: start, end: start + length, wasStart: startStart, wasEnd: startEnd))

        case .trimText(let id, let edge, let startStart, let startEnd, _):
            switch edge {
            case .leading:
                let start = min(max(0, snapped(startStart + delta)), startEnd - 0.2)
                actions.perform(.setTextTiming(id: id, start: start, end: startEnd, wasStart: startStart, wasEnd: startEnd))
            case .trailing:
                let end = max(startStart + 0.2, min(timeline.duration + 5, snapped(startEnd + delta)))
                actions.perform(.setTextTiming(id: id, start: startStart, end: end, wasStart: startStart, wasEnd: startEnd))
            }

        case .moveAudio(let id, let startStart, _):
            guard let clip = timeline.audio.first(where: { $0.id == id }) else { return }
            let start = max(0, snapped(startStart + delta))
            actions.perform(.retimeAudioClip(id: id, start: start, duration: clip.duration, sourceStart: clip.sourceStart,
                                             wasStart: startStart, wasDuration: clip.duration, wasSourceStart: clip.sourceStart))

        case .trimAudio(let id, let edge, let startStart, let startDuration, let startSource, _):
            let sourceLength = timeline.audio.first { $0.id == id }.flatMap { assets[$0.assetID]?.duration } ?? .infinity
            switch edge {
            case .leading:
                var trimmed = delta
                trimmed = max(-startSource, trimmed)
                trimmed = min(startDuration - 0.2, trimmed)
                actions.perform(.retimeAudioClip(id: id, start: startStart + trimmed, duration: startDuration - trimmed,
                                                 sourceStart: startSource + trimmed,
                                                 wasStart: startStart, wasDuration: startDuration, wasSourceStart: startSource))
            case .trailing:
                var end = snapped(startStart + startDuration + delta, excluding: [startStart + startDuration])
                if sourceLength.isFinite { end = min(end, startStart + sourceLength - startSource) }
                let duration = max(0.2, end - startStart)
                actions.perform(.retimeAudioClip(id: id, start: startStart, duration: duration, sourceStart: startSource,
                                                 wasStart: startStart, wasDuration: startDuration, wasSourceStart: startSource))
            }

        case .reorderClip:
            break
        }
    }

    @objc private func handleReorder(_ gesture: UILongPressGestureRecognizer) {
        guard let actions = coordinator?.parent.actions else { return }
        let point = gesture.location(in: contentView)
        switch gesture.state {
        case .began:
            guard case .clip(let clip, let index, _)? = hit(at: point) else { gesture.state = .cancelled; return }
            activeGesture = .reorderClip(id: clip.id, fromIndex: index, targetIndex: index)
            selection = .clip(clip.id)
            actions.onSelect(.clip(clip.id))
            contentView.dragging = (clip.id, point.x)
            contentView.setNeedsDisplay()
            Haptics.grab()

        case .changed:
            guard case .reorderClip(let id, let from, let previousTarget) = activeGesture else { return }
            let t = time(atContentX: point.x)
            // Target index: the clip whose midpoint the finger has crossed.
            var target = timeline.clips.count - 1
            for (i, clip) in timeline.clips.enumerated() where t < clip.start + clip.duration / 2 {
                target = i
                break
            }
            if target != previousTarget { Haptics.snap() }
            activeGesture = .reorderClip(id: id, fromIndex: from, targetIndex: target)
            contentView.dragging = (id, point.x)
            contentView.dropIndex = target
            contentView.setNeedsDisplay()

        case .ended:
            if case .reorderClip(_, let from, let target) = activeGesture, from != target {
                actions.perform(.moveClip(from: from, to: target > from ? target + 1 : target))
                Haptics.snap()
            }
            fallthrough
        case .cancelled, .failed:
            activeGesture = nil
            contentView.dragging = nil
            contentView.dropIndex = nil
            contentView.setNeedsDisplay()

        default:
            break
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingProgrammaticOffset, activeGesture == nil else { return }
        if scrollView.isTracking || scrollView.isDecelerating {
            coordinator?.parent.actions.onScrub(max(0, currentTime))
        }
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
            coordinator?.parent.actions.onScrubEnd()
            return
        }

        setTime(nearest.time, animated: true)
        coordinator?.parent.actions.onScrub(nearest.time)
        Haptics.snap()
        coordinator?.parent.actions.onScrubEnd()
    }
}

// MARK: - Content view

/// Draws the tracks. `draw(_:)` rather than a view hierarchy: a 40-clip timeline would otherwise
/// be a few hundred views to lay out on every zoom step.
@MainActor
final class TimelineContentView: UIView {

    weak var host: TimelineScrollView?
    var timeline = Timeline()
    var assets = AssetPool()
    var beatGrid: BeatGrid?
    var waveforms: [UUID: Waveform] = [:]
    var secondsPerPoint: Double = 0.012
    var selection: EditorSelection?
    /// Clip being dragged for reorder, and the finger's x.
    var dragging: (id: UUID, x: CGFloat)?
    var dropIndex: Int?

    private var thumbnails: [UUID: UIImage] = [:]
    private var thumbnailRequests: Set<UUID> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        contentMode = .redraw
    }

    func loadThumbnails() {
        let size = CGSize(width: 54, height: 54)
        for asset in assets.visuals where thumbnails[asset.id] == nil && !thumbnailRequests.contains(asset.id) {
            thumbnailRequests.insert(asset.id)
            Task { [weak self] in
                let image = await ThumbnailCache.shared.thumbnail(for: asset, size: size)
                guard let self else { return }
                self.thumbnailRequests.remove(asset.id)
                if let image {
                    self.thumbnails[asset.id] = image
                    self.setNeedsDisplay()
                }
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        drawTimeRuler(context: context, rect: rect)

        let rulerHeight = TimelineScrollView.rulerHeight
        let videoHeight = TimelineScrollView.videoTrackHeight
        let textHeight = TimelineScrollView.textTrackHeight
        let audioHeight = TimelineScrollView.audioTrackHeight
        let spacing = TimelineScrollView.trackSpacing

        func x(_ time: Double) -> CGFloat { CGFloat(time / secondsPerPoint) }
        context.translateBy(x: 0, y: rulerHeight)
        defer { context.translateBy(x: 0, y: -rulerHeight) }

        // --- Beat ticks, behind everything ---
        if let beats = beatGrid?.beats {
            context.setStrokeColor(UIColor(Theme.Palette.accent).withAlphaComponent(0.22).cgColor)
            context.setLineWidth(1)
            for beat in beats {
                let px = x(beat)
                guard px >= rect.minX - 2, px <= rect.maxX + 2 else { continue }
                context.move(to: CGPoint(x: px, y: 0))
                context.addLine(to: CGPoint(x: px, y: bounds.height - rulerHeight))
            }
            context.strokePath()
        }

        // --- Video clips ---
        for (index, clip) in timeline.clips.enumerated() {
            let frame = CGRect(x: x(clip.start), y: 0, width: max(2, x(clip.duration)), height: videoHeight)
            guard frame.intersects(rect.insetBy(dx: -40, dy: 0)) else { continue }
            let isSelected = selection == .clip(clip.id)
            let isDragging = dragging?.id == clip.id
            drawClip(clip, frame: frame, isSelected: isSelected, isDragging: isDragging, context: context)

            // Drop indicator during reorder.
            if let dropIndex, dragging != nil, dropIndex == index {
                context.setFillColor(UIColor(Theme.Palette.accent).cgColor)
                context.fill(CGRect(x: frame.minX - 1.5, y: -2, width: 3, height: videoHeight + 4))
            }
        }
        if let dropIndex, dragging != nil, dropIndex >= timeline.clips.count, let last = timeline.clips.last {
            context.setFillColor(UIColor(Theme.Palette.accent).cgColor)
            context.fill(CGRect(x: x(last.end) - 1.5, y: -2, width: 3, height: videoHeight + 4))
        }

        // --- Text chips ---
        let textY = videoHeight + spacing
        for layer in timeline.textLayers {
            let frame = CGRect(x: x(layer.start), y: textY, width: max(4, x(layer.duration)), height: textHeight)
            guard frame.intersects(rect.insetBy(dx: -40, dy: 0)) else { continue }
            let isSelected = selection == .text(layer.id)
            let path = UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 5)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(isSelected ? 0.6 : 0.32).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
            if isSelected {
                context.setStrokeColor(UIColor.systemBlue.cgColor)
                context.setLineWidth(1.5)
                context.addPath(path.cgPath)
                context.strokePath()
                drawHandles(in: frame.insetBy(dx: 1, dy: 1), color: .systemBlue, context: context)
            }
            if frame.width > 44 {
                drawLabel(layer.text, in: frame.insetBy(dx: 6, dy: 3), context: context, size: 9, color: .white)
            }
        }

        // --- Audio lanes ---
        let lanes = TimelineScrollView.audioLanes(for: timeline)
        var laneY = textY + textHeight + spacing
        for role in lanes {
            for clip in timeline.audio where clip.role == role {
                let frame = CGRect(x: x(clip.start), y: laneY, width: max(4, x(clip.duration)), height: audioHeight)
                guard frame.intersects(rect.insetBy(dx: -40, dy: 0)) else { continue }
                let isSelected = selection == .audio(clip.id)
                let tint = Self.color(for: role)
                let path = UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 5)
                context.setFillColor(tint.withAlphaComponent(clip.isMuted ? 0.12 : (isSelected ? 0.42 : 0.24)).cgColor)
                context.addPath(path.cgPath)
                context.fillPath()

                // Waveform.
                if let waveform = waveforms[clip.assetID], !clip.isMuted {
                    let visible = frame.intersection(rect.insetBy(dx: -8, dy: 0))
                    if visible.width > 2 {
                        let columns = Int(visible.width / 2)
                        let startTime = clip.sourceStart + Double(visible.minX - frame.minX) * secondsPerPoint
                        let length = Double(visible.width) * secondsPerPoint
                        let bins = waveform.slice(start: startTime, length: length, count: max(1, columns))
                        context.setStrokeColor(tint.withAlphaComponent(0.9).cgColor)
                        context.setLineWidth(1.2)
                        let mid = frame.midY
                        let amp = (audioHeight / 2 - 3) * CGFloat(clip.volume)
                        for (i, value) in bins.enumerated() {
                            let px = visible.minX + CGFloat(i) * 2 + 1
                            let h = max(1, CGFloat(value) * amp)
                            context.move(to: CGPoint(x: px, y: mid - h))
                            context.addLine(to: CGPoint(x: px, y: mid + h))
                        }
                        context.strokePath()
                    }
                }
                // Fade ramps.
                if clip.fadeIn > 0 || clip.fadeOut > 0 {
                    context.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
                    context.setLineWidth(1)
                    if clip.fadeIn > 0 {
                        context.move(to: CGPoint(x: frame.minX, y: frame.maxY - 2))
                        context.addLine(to: CGPoint(x: min(frame.maxX, frame.minX + x(clip.fadeIn)), y: frame.minY + 2))
                    }
                    if clip.fadeOut > 0 {
                        context.move(to: CGPoint(x: max(frame.minX, frame.maxX - x(clip.fadeOut)), y: frame.minY + 2))
                        context.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - 2))
                    }
                    context.strokePath()
                }
                if isSelected {
                    context.setStrokeColor(tint.cgColor)
                    context.setLineWidth(1.5)
                    context.addPath(path.cgPath)
                    context.strokePath()
                    drawHandles(in: frame.insetBy(dx: 1, dy: 1), color: tint, context: context)
                }
                if frame.width > 60 {
                    let name = assets[clip.assetID]?.displayName ?? role.displayName
                    drawLabel(clip.isMuted ? "\(name) (muted)" : name, in: frame.insetBy(dx: 6, dy: 4), context: context, size: 9, color: .white)
                }
            }
            laneY += audioHeight + spacing
        }
    }

    private func drawClip(_ clip: VideoClip, frame: CGRect, isSelected: Bool, isDragging: Bool, context: CGContext) {
        let inset = frame.insetBy(dx: 1, dy: 0)
        let path = UIBezierPath(roundedRect: inset, cornerRadius: 7)
        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()

        // Base.
        context.setFillColor(UIColor(Theme.Palette.surfaceRaised).cgColor)
        context.fill(inset)

        // Thumbnails tiled across the clip.
        if let assetID = clip.assetID, let image = thumbnails[assetID], let cgImage = image.cgImage {
            let tileHeight = frame.height
            let imageAspect = CGFloat(cgImage.width) / CGFloat(max(1, cgImage.height))
            let tileWidth = max(20, tileHeight * imageAspect)
            var tileX = inset.minX
            // Draw with a flipped transform: CGContext y is up, and UIImage tiles look right
            // only when the image is drawn upright.
            context.saveGState()
            context.translateBy(x: 0, y: inset.maxY)
            context.scaleBy(x: 1, y: -1)
            while tileX < inset.maxX {
                context.draw(cgImage, in: CGRect(x: tileX, y: 0, width: tileWidth, height: tileHeight))
                tileX += tileWidth
            }
            context.restoreGState()
            // Slight darkening so labels read.
            context.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            context.fill(inset)
        } else if clip.assetID == nil {
            context.setFillColor(UIColor(Theme.Palette.surface).cgColor)
            context.fill(inset)
        }

        // Transition marker at the incoming edge.
        if let transition = clip.transitionIn, transition.kind != .cut {
            let markerWidth = min(inset.width * 0.4, max(6, CGFloat(transition.duration / secondsPerPoint)))
            context.setFillColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            context.fill(CGRect(x: inset.minX, y: 0, width: markerWidth, height: inset.height))
            context.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            let diamond = UIBezierPath()
            let cx = inset.minX + 7, cy = inset.height / 2
            diamond.move(to: CGPoint(x: cx, y: cy - 4)); diamond.addLine(to: CGPoint(x: cx + 4, y: cy))
            diamond.addLine(to: CGPoint(x: cx, y: cy + 4)); diamond.addLine(to: CGPoint(x: cx - 4, y: cy)); diamond.close()
            context.addPath(diamond.cgPath); context.fillPath()
        }

        // Ken Burns / speed / mute badges.
        var badges: [String] = []
        if clip.cropStart != clip.cropEnd { badges.append("↗") }
        if abs(clip.speed - 1) > 0.01 { badges.append(String(format: "%.1fx", clip.speed)) }
        if clip.assetID.flatMap({ assets[$0] })?.kind == .video, clip.volume > 0.001 { badges.append("♪") }
        if !badges.isEmpty, inset.width > 30 {
            drawLabel(badges.joined(separator: " "), in: CGRect(x: inset.minX + 4, y: inset.maxY - 14, width: inset.width - 8, height: 12), context: context, size: 8, color: .white)
        }

        // Only label clips wide enough to read; a 0.3s clip at low zoom has no room.
        if inset.width > 44 {
            let label = clip.assetID == nil ? "empty" : String(format: "%.1fs", clip.duration)
            drawLabel(label, in: CGRect(x: inset.minX + 5, y: 3, width: inset.width - 10, height: 12), context: context, size: 9, color: .white)
        }
        context.restoreGState()

        if isDragging {
            context.setFillColor(UIColor(Theme.Palette.accent).withAlphaComponent(0.25).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }
        if isSelected {
            context.setStrokeColor(UIColor(Theme.Palette.accent).cgColor)
            context.setLineWidth(2)
            context.addPath(path.cgPath)
            context.strokePath()
            drawHandles(in: inset, color: UIColor(Theme.Palette.accent), context: context)
        }
    }

    /// Trim handles: filled bars at both edges with a grip mark. Wide enough to grab.
    private func drawHandles(in frame: CGRect, color: UIColor, context: CGContext) {
        let width = TimelineScrollView.handleWidth
        for isLeading in [true, false] {
            let handle = CGRect(x: isLeading ? frame.minX : frame.maxX - width, y: frame.minY, width: width, height: frame.height)
            let path = UIBezierPath(
                roundedRect: handle,
                byRoundingCorners: isLeading ? [.topLeft, .bottomLeft] : [.topRight, .bottomRight],
                cornerRadii: CGSize(width: 6, height: 6)
            )
            context.setFillColor(color.cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
            context.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            let grip = CGRect(x: handle.midX - 1, y: handle.midY - 6, width: 2, height: 12)
            context.fill(grip)
        }
    }

    /// Time ticks along the top. The interval adapts to zoom, so labels never collide and never
    /// thin out to uselessness — at a 40-second view you get 10s marks, at half a second tenths.
    private func drawTimeRuler(context: CGContext, rect: CGRect) {
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60]
        let targetSeconds = secondsPerPoint * 60
        let interval = candidates.first { $0 >= targetSeconds } ?? 60

        let startTime = max(0, Double(rect.minX) * secondsPerPoint)
        let endTime = Double(rect.maxX) * secondsPerPoint
        guard interval > 0, endTime > startTime else { return }

        context.setStrokeColor(UIColor(Theme.Palette.separator).withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)

        var time = (startTime / interval).rounded(.down) * interval
        while time <= endTime {
            let x = CGFloat(time / secondsPerPoint)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: 6))
            let label = interval < 1
                ? String(format: "%.1f", time)
                : String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
            drawLabel(label, in: CGRect(x: x + 3, y: 0, width: 46, height: 12), context: context, size: 8,
                      color: UIColor(Theme.Palette.secondaryText))
            time += interval
        }
        context.strokePath()
    }

    private func drawLabel(_ text: String, in rect: CGRect, context: CGContext, size: CGFloat = 10, color: UIColor) {
        // Dynamic Type reaches the timeline too — the time labels and clip names scale with the
        // user's setting rather than being fixed points.
        let scaled = UIFontMetrics(forTextStyle: .caption2).scaledValue(for: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: scaled, weight: .semibold),
            .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(with: rect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], context: nil)
    }

    static func color(for role: AudioRole) -> UIColor {
        switch role {
        case .music: return .systemGreen
        case .voice: return .systemPink
        case .effect: return .systemTeal
        case .reference: return .systemPurple
        case .clipAudio: return .systemGray
        }
    }
}
