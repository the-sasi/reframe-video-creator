import Foundation

/// An undoable timeline edit.
///
/// Modelled as an enum rather than a protocol with existentials, for three reasons that all
/// matter here: `Codable` conformance is free (so the undo stack can be persisted with the
/// project and survive a force-quit), exhaustiveness is compiler-checked, and each case carries
/// **both the new and the previous value**, which makes `revert` trivially correct instead of
/// something that has to be kept in sync with `apply`.
public enum EditCommand: Codable, Sendable, Hashable {

    // MARK: Clips
    case trimClip(id: UUID, duration: Double, sourceStart: Double,
                  wasDuration: Double, wasSourceStart: Double)
    case splitClip(id: UUID, atLocalTime: Double, newClipID: UUID, wasDuration: Double)
    case deleteClip(index: Int, clip: VideoClip)
    case insertClip(index: Int, clip: VideoClip)
    case moveClip(from: Int, to: Int)
    case replaceClipAsset(id: UUID, assetID: UUID?, wasAssetID: UUID?)
    case setClipSpeed(id: UUID, speed: Double, wasSpeed: Double)
    case setClipCrop(id: UUID, start: NormalizedRect, end: NormalizedRect,
                     wasStart: NormalizedRect, wasEnd: NormalizedRect)
    case setClipGrade(id: UUID, grade: ColorGrade, wasGrade: ColorGrade)
    case setClipEffects(id: UUID, vignette: Double, grain: Double,
                        wasVignette: Double, wasGrain: Double)
    case setClipVolume(id: UUID, volume: Double, wasVolume: Double)
    case setTransition(clipID: UUID, transition: Transition?, wasTransition: Transition?)

    // MARK: Text
    case addTextLayer(layer: TextLayer)
    case deleteTextLayer(index: Int, layer: TextLayer)
    case setTextContent(id: UUID, text: String, wasText: String)
    case setTextFrame(id: UUID, frame: NormalizedRect, wasFrame: NormalizedRect)
    case setTextTiming(id: UUID, start: Double, end: Double, wasStart: Double, wasEnd: Double)
    case setTextStyle(id: UUID, style: TextLayerStyle, wasStyle: TextLayerStyle)

    // MARK: Audio & overlays
    case addAudioClip(clip: AudioClip)
    case deleteAudioClip(index: Int, clip: AudioClip)
    case setAudioVolume(id: UUID, volume: Double, wasVolume: Double)
    case addOverlay(layer: OverlayLayer)
    case deleteOverlay(index: Int, layer: OverlayLayer)
    case setOverlayFrame(id: UUID, frame: NormalizedRect, wasFrame: NormalizedRect)

    // MARK: Document
    case setCanvas(canvas: CanvasSpec, wasCanvas: CanvasSpec)

    /// Shown in the undo affordance: "Undo Trim Clip".
    public var name: String {
        switch self {
        case .trimClip: return "Trim Clip"
        case .splitClip: return "Split Clip"
        case .deleteClip: return "Delete Clip"
        case .insertClip: return "Add Clip"
        case .moveClip: return "Reorder Clips"
        case .replaceClipAsset: return "Replace Photo"
        case .setClipSpeed: return "Change Speed"
        case .setClipCrop: return "Adjust Framing"
        case .setClipGrade: return "Adjust Colour"
        case .setClipEffects: return "Adjust Effects"
        case .setClipVolume: return "Change Volume"
        case .setTransition: return "Change Transition"
        case .addTextLayer: return "Add Text"
        case .deleteTextLayer: return "Delete Text"
        case .setTextContent: return "Edit Text"
        case .setTextFrame: return "Move Text"
        case .setTextTiming: return "Retime Text"
        case .setTextStyle: return "Style Text"
        case .addAudioClip: return "Add Audio"
        case .deleteAudioClip: return "Remove Audio"
        case .setAudioVolume: return "Change Volume"
        case .addOverlay: return "Add Logo"
        case .deleteOverlay: return "Remove Logo"
        case .setOverlayFrame: return "Move Logo"
        case .setCanvas: return "Change Size"
        }
    }

    /// Continuous gestures produce one command per frame of drag. Commands sharing a
    /// coalescing key merge into a single undo step, so a 200-frame trim is one undo.
    /// Structural edits return nil — they must never merge.
    public var coalescingKey: String? {
        switch self {
        case .trimClip(let id, _, _, _, _): return "trim:\(id)"
        case .setClipCrop(let id, _, _, _, _): return "crop:\(id)"
        case .setClipGrade(let id, _, _): return "grade:\(id)"
        case .setClipEffects(let id, _, _, _, _): return "effects:\(id)"
        case .setClipVolume(let id, _, _): return "clipvol:\(id)"
        case .setClipSpeed(let id, _, _): return "speed:\(id)"
        case .setTextFrame(let id, _, _): return "textframe:\(id)"
        case .setTextTiming(let id, _, _, _, _): return "texttime:\(id)"
        case .setTextContent(let id, _, _): return "textcontent:\(id)"
        case .setAudioVolume(let id, _, _): return "audiovol:\(id)"
        case .setOverlayFrame(let id, _, _): return "overlayframe:\(id)"
        default: return nil
        }
    }

    /// Whether applying this changes clip layout and therefore needs a `relayout()`.
    public var affectsLayout: Bool {
        switch self {
        case .trimClip, .splitClip, .deleteClip, .insertClip, .moveClip, .setClipSpeed:
            return true
        default:
            return false
        }
    }

    /// Merges `newer` into `self`, keeping this command's "was" values and the newer one's
    /// "new" values. Precondition: same coalescing key.
    public func coalesced(with newer: EditCommand) -> EditCommand {
        switch (self, newer) {
        case (.trimClip(let id, _, _, let wd, let ws), .trimClip(_, let d, let s, _, _)):
            return .trimClip(id: id, duration: d, sourceStart: s, wasDuration: wd, wasSourceStart: ws)
        case (.setClipCrop(let id, _, _, let ws, let we), .setClipCrop(_, let s, let e, _, _)):
            return .setClipCrop(id: id, start: s, end: e, wasStart: ws, wasEnd: we)
        case (.setClipGrade(let id, _, let wg), .setClipGrade(_, let g, _)):
            return .setClipGrade(id: id, grade: g, wasGrade: wg)
        case (.setClipEffects(let id, _, _, let wv, let wgr),
              .setClipEffects(_, let v, let gr, _, _)):
            return .setClipEffects(id: id, vignette: v, grain: gr, wasVignette: wv, wasGrain: wgr)
        case (.setClipVolume(let id, _, let wv), .setClipVolume(_, let v, _)):
            return .setClipVolume(id: id, volume: v, wasVolume: wv)
        case (.setClipSpeed(let id, _, let ws), .setClipSpeed(_, let s, _)):
            return .setClipSpeed(id: id, speed: s, wasSpeed: ws)
        case (.setTextFrame(let id, _, let wf), .setTextFrame(_, let f, _)):
            return .setTextFrame(id: id, frame: f, wasFrame: wf)
        case (.setTextTiming(let id, _, _, let wsr, let wen), .setTextTiming(_, let s, let e, _, _)):
            return .setTextTiming(id: id, start: s, end: e, wasStart: wsr, wasEnd: wen)
        case (.setTextContent(let id, _, let wt), .setTextContent(_, let t, _)):
            return .setTextContent(id: id, text: t, wasText: wt)
        case (.setAudioVolume(let id, _, let wv), .setAudioVolume(_, let v, _)):
            return .setAudioVolume(id: id, volume: v, wasVolume: wv)
        case (.setOverlayFrame(let id, _, let wf), .setOverlayFrame(_, let f, _)):
            return .setOverlayFrame(id: id, frame: f, wasFrame: wf)
        default:
            return newer
        }
    }
}

/// The subset of `TextLayer` the style sheet edits, bundled so one gesture is one command.
public struct TextLayerStyle: Codable, Sendable, Hashable {
    public var fontCategory: FontCategory
    public var sizeRatio: Double
    public var colorHex: String
    public var hasShadow: Bool
    public var alignment: TextAlignment
    public var entry: TextEntryAnimation
    public var exit: TextExitAnimation

    public init(
        fontCategory: FontCategory, sizeRatio: Double, colorHex: String,
        hasShadow: Bool, alignment: TextAlignment,
        entry: TextEntryAnimation, exit: TextExitAnimation
    ) {
        self.fontCategory = fontCategory
        self.sizeRatio = sizeRatio
        self.colorHex = colorHex
        self.hasShadow = hasShadow
        self.alignment = alignment
        self.entry = entry
        self.exit = exit
    }

    public init(layer: TextLayer) {
        self.init(
            fontCategory: layer.fontCategory, sizeRatio: layer.sizeRatio,
            colorHex: layer.colorHex, hasShadow: layer.hasShadow,
            alignment: layer.alignment, entry: layer.entry, exit: layer.exit
        )
    }

    public func applied(to layer: inout TextLayer) {
        layer.fontCategory = fontCategory
        layer.sizeRatio = sizeRatio
        layer.colorHex = colorHex
        layer.hasShadow = hasShadow
        layer.alignment = alignment
        layer.entry = entry
        layer.exit = exit
    }
}

// MARK: - Application

extension EditCommand {

    public func apply(to timeline: inout Timeline) throws {
        try mutate(&timeline, reverting: false)
        if affectsLayout { timeline.relayout() }
    }

    public func revert(from timeline: inout Timeline) throws {
        try mutate(&timeline, reverting: true)
        if affectsLayout { timeline.relayout() }
    }

    private func mutate(_ t: inout Timeline, reverting: Bool) throws {
        switch self {

        case .trimClip(let id, let duration, let sourceStart, let wasDuration, let wasSourceStart):
            let i = try clipIndex(id, in: t)
            t.clips[i].duration = reverting ? wasDuration : duration
            t.clips[i].sourceStart = reverting ? wasSourceStart : sourceStart

        case .splitClip(let id, let localTime, let newClipID, let wasDuration):
            let i = try clipIndex(id, in: t)
            if reverting {
                t.clips.removeAll { $0.id == newClipID }
                t.clips[i].duration = wasDuration
            } else {
                var tail = t.clips[i]
                tail.id = newClipID
                tail.duration = wasDuration - localTime
                tail.sourceStart = t.clips[i].sourceTime(atLocalTime: localTime)
                // The second half inherits the remainder of the Ken Burns move, so splitting
                // a clip does not visibly change its motion.
                tail.cropStart = t.clips[i].crop(atLocalTime: localTime)
                tail.transitionIn = nil
                t.clips[i].duration = localTime
                t.clips[i].cropEnd = tail.cropStart
                t.clips.insert(tail, at: i + 1)
            }

        case .deleteClip(let index, let clip):
            if reverting {
                t.clips.insert(clip, at: min(index, t.clips.count))
            } else {
                guard index < t.clips.count else { throw ReframeError.documentCorrupt(detail: "deleteClip index") }
                t.clips.remove(at: index)
            }

        case .insertClip(let index, let clip):
            if reverting {
                t.clips.removeAll { $0.id == clip.id }
            } else {
                t.clips.insert(clip, at: min(index, t.clips.count))
            }

        case .moveClip(let from, let to):
            let (a, b) = reverting ? (to, from) : (from, to)
            guard a < t.clips.count, b <= t.clips.count else {
                throw ReframeError.documentCorrupt(detail: "moveClip index")
            }
            let clip = t.clips.remove(at: a)
            t.clips.insert(clip, at: min(b, t.clips.count))

        case .replaceClipAsset(let id, let assetID, let wasAssetID):
            let i = try clipIndex(id, in: t)
            t.clips[i].assetID = reverting ? wasAssetID : assetID

        case .setClipSpeed(let id, let speed, let wasSpeed):
            let i = try clipIndex(id, in: t)
            t.clips[i].speed = reverting ? wasSpeed : speed

        case .setClipCrop(let id, let start, let end, let wasStart, let wasEnd):
            let i = try clipIndex(id, in: t)
            t.clips[i].cropStart = reverting ? wasStart : start
            t.clips[i].cropEnd = reverting ? wasEnd : end

        case .setClipGrade(let id, let grade, let wasGrade):
            let i = try clipIndex(id, in: t)
            t.clips[i].grade = reverting ? wasGrade : grade

        case .setClipEffects(let id, let vignette, let grain, let wasVignette, let wasGrain):
            let i = try clipIndex(id, in: t)
            t.clips[i].vignette = reverting ? wasVignette : vignette
            t.clips[i].grain = reverting ? wasGrain : grain

        case .setClipVolume(let id, let volume, let wasVolume):
            let i = try clipIndex(id, in: t)
            t.clips[i].volume = reverting ? wasVolume : volume

        case .setTransition(let clipID, let transition, let wasTransition):
            let i = try clipIndex(clipID, in: t)
            t.clips[i].transitionIn = reverting ? wasTransition : transition

        case .addTextLayer(let layer):
            if reverting {
                t.textLayers.removeAll { $0.id == layer.id }
            } else {
                t.textLayers.append(layer)
            }

        case .deleteTextLayer(let index, let layer):
            if reverting {
                t.textLayers.insert(layer, at: min(index, t.textLayers.count))
            } else {
                t.textLayers.removeAll { $0.id == layer.id }
            }

        case .setTextContent(let id, let text, let wasText):
            let i = try textIndex(id, in: t)
            t.textLayers[i].text = reverting ? wasText : text

        case .setTextFrame(let id, let frame, let wasFrame):
            let i = try textIndex(id, in: t)
            t.textLayers[i].frame = reverting ? wasFrame : frame

        case .setTextTiming(let id, let start, let end, let wasStart, let wasEnd):
            let i = try textIndex(id, in: t)
            t.textLayers[i].start = reverting ? wasStart : start
            t.textLayers[i].end = reverting ? wasEnd : end

        case .setTextStyle(let id, let style, let wasStyle):
            let i = try textIndex(id, in: t)
            (reverting ? wasStyle : style).applied(to: &t.textLayers[i])

        case .addAudioClip(let clip):
            if reverting {
                t.audio.removeAll { $0.id == clip.id }
            } else {
                t.audio.append(clip)
            }

        case .deleteAudioClip(let index, let clip):
            if reverting {
                t.audio.insert(clip, at: min(index, t.audio.count))
            } else {
                t.audio.removeAll { $0.id == clip.id }
            }

        case .setAudioVolume(let id, let volume, let wasVolume):
            guard let i = t.audio.firstIndex(where: { $0.id == id }) else {
                throw ReframeError.documentCorrupt(detail: "audio clip \(id) not found")
            }
            t.audio[i].volume = reverting ? wasVolume : volume

        case .addOverlay(let layer):
            if reverting {
                t.overlays.removeAll { $0.id == layer.id }
            } else {
                t.overlays.append(layer)
            }

        case .deleteOverlay(let index, let layer):
            if reverting {
                t.overlays.insert(layer, at: min(index, t.overlays.count))
            } else {
                t.overlays.removeAll { $0.id == layer.id }
            }

        case .setOverlayFrame(let id, let frame, let wasFrame):
            guard let i = t.overlays.firstIndex(where: { $0.id == id }) else {
                throw ReframeError.documentCorrupt(detail: "overlay \(id) not found")
            }
            t.overlays[i].frame = reverting ? wasFrame : frame

        case .setCanvas(let canvas, let wasCanvas):
            t.canvas = reverting ? wasCanvas : canvas
        }
    }

    private func clipIndex(_ id: UUID, in t: Timeline) throws -> Int {
        guard let i = t.clips.firstIndex(where: { $0.id == id }) else {
            throw ReframeError.documentCorrupt(detail: "clip \(id) not found")
        }
        return i
    }

    private func textIndex(_ id: UUID, in t: Timeline) throws -> Int {
        guard let i = t.textLayers.firstIndex(where: { $0.id == id }) else {
            throw ReframeError.documentCorrupt(detail: "text layer \(id) not found")
        }
        return i
    }
}
