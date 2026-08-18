import Foundation

/// An undoable timeline edit.
///
/// Modelled as an enum rather than a protocol with existentials, for three reasons that all
/// matter here: `Codable` conformance is free (so the undo stack can be persisted with the
/// project and survive a force-quit), exhaustiveness is compiler-checked, and each case carries
/// **both the new and the previous value**, which makes `revert` trivially correct instead of
/// something that has to be kept in sync with `apply`.
public indirect enum EditCommand: Codable, Sendable, Hashable {

    /// Several commands as one undo step — "Apply Cinematic", "Reset all colour". Applied in
    /// order, reverted in reverse. Never coalesces.
    case batch(name: String, commands: [EditCommand])

    // MARK: Clips
    case trimClip(id: UUID, duration: Double, sourceStart: Double,
                  wasDuration: Double, wasSourceStart: Double)
    /// `wasCropEnd` is what the split rewrote: the first half's crop now ends at the split
    /// point, and reverting the duration alone left the Ken Burns move visibly changed.
    case splitClip(id: UUID, atLocalTime: Double, newClipID: UUID,
                   wasDuration: Double, wasCropEnd: NormalizedRect)
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
    case setClipFit(id: UUID, fitMode: FitMode, wasFitMode: FitMode)
    case setTransition(clipID: UUID, transition: Transition?, wasTransition: Transition?)

    // MARK: Text
    case addTextLayer(layer: TextLayer)
    case deleteTextLayer(index: Int, layer: TextLayer)
    case setTextContent(id: UUID, text: String, wasText: String)
    case setTextFrame(id: UUID, frame: NormalizedRect, wasFrame: NormalizedRect)
    case setTextTiming(id: UUID, start: Double, end: Double, wasStart: Double, wasEnd: Double)
    case setTextStyle(id: UUID, style: TextLayerStyle, wasStyle: TextLayerStyle)
    case setTextWordTimings(id: UUID, timings: [Double]?, wasTimings: [Double]?)

    // MARK: Audio & overlays
    case addAudioClip(clip: AudioClip)
    case deleteAudioClip(index: Int, clip: AudioClip)
    case setAudioVolume(id: UUID, volume: Double, wasVolume: Double)
    case setAudioFades(id: UUID, fadeIn: Double, fadeOut: Double, wasFadeIn: Double, wasFadeOut: Double)
    case setAudioMuted(id: UUID, isMuted: Bool, wasMuted: Bool)
    /// Move and/or trim in one step: `start` is the timeline position, `sourceStart` the offset
    /// into the file, `duration` how much of it plays.
    case retimeAudioClip(id: UUID, start: Double, duration: Double, sourceStart: Double,
                         wasStart: Double, wasDuration: Double, wasSourceStart: Double)
    case setDucking(enabled: Bool, wasEnabled: Bool)
    case addOverlay(layer: OverlayLayer)
    case deleteOverlay(index: Int, layer: OverlayLayer)
    case setOverlayFrame(id: UUID, frame: NormalizedRect, wasFrame: NormalizedRect)

    // MARK: Document
    case setCanvas(canvas: CanvasSpec, wasCanvas: CanvasSpec)
    case setBackground(hex: String, wasHex: String)

    /// Shown in the undo affordance: "Undo Trim Clip".
    public var name: String {
        switch self {
        case .batch(let name, _): return name
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
        case .setClipFit: return "Change Fit"
        case .setTransition: return "Change Transition"
        case .addTextLayer: return "Add Text"
        case .deleteTextLayer: return "Delete Text"
        case .setTextContent: return "Edit Text"
        case .setTextFrame: return "Move Text"
        case .setTextTiming: return "Retime Text"
        case .setTextStyle: return "Style Text"
        case .setTextWordTimings: return "Retime Words"
        case .addAudioClip: return "Add Audio"
        case .deleteAudioClip: return "Remove Audio"
        case .setAudioVolume: return "Change Volume"
        case .setAudioFades: return "Change Fades"
        case .setAudioMuted: return "Mute Audio"
        case .retimeAudioClip: return "Move Audio"
        case .setDucking: return "Change Ducking"
        case .addOverlay: return "Add Logo"
        case .deleteOverlay: return "Remove Logo"
        case .setOverlayFrame: return "Move Logo"
        case .setCanvas: return "Change Size"
        case .setBackground: return "Change Background"
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
        case .setAudioFades(let id, _, _, _, _): return "audiofade:\(id)"
        case .retimeAudioClip(let id, _, _, _, _, _, _): return "audiotime:\(id)"
        case .setOverlayFrame(let id, _, _): return "overlayframe:\(id)"
        default: return nil
        }
    }

    /// Whether applying this changes clip layout and therefore needs a `relayout()`.
    public var affectsLayout: Bool {
        switch self {
        case .trimClip, .splitClip, .deleteClip, .insertClip, .moveClip, .setClipSpeed:
            return true
        case .batch(_, let commands):
            return commands.contains { $0.affectsLayout }
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
        case (.setAudioFades(let id, _, _, let wi, let wo), .setAudioFades(_, let i, let o, _, _)):
            return .setAudioFades(id: id, fadeIn: i, fadeOut: o, wasFadeIn: wi, wasFadeOut: wo)
        case (.retimeAudioClip(let id, _, _, _, let ws, let wd, let wss),
              .retimeAudioClip(_, let s, let d, let ss, _, _, _)):
            return .retimeAudioClip(id: id, start: s, duration: d, sourceStart: ss,
                                    wasStart: ws, wasDuration: wd, wasSourceStart: wss)
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
    public var fontName: String?
    public var weight: TextWeight
    public var isItalic: Bool
    public var allCaps: Bool
    public var sizeRatio: Double
    public var letterSpacing: Double
    public var lineSpacing: Double
    public var colorHex: String
    public var opacity: Double
    public var hasShadow: Bool
    public var outline: TextOutline?
    public var background: TextBackground?
    public var rotation: Double
    public var alignment: TextAlignment
    public var entry: TextEntryAnimation
    public var exit: TextExitAnimation

    public init(
        fontCategory: FontCategory, fontName: String? = nil, weight: TextWeight = .bold,
        isItalic: Bool = false, allCaps: Bool = false,
        sizeRatio: Double, letterSpacing: Double = 0, lineSpacing: Double = 1.18,
        colorHex: String, opacity: Double = 1, hasShadow: Bool,
        outline: TextOutline? = nil, background: TextBackground? = nil, rotation: Double = 0,
        alignment: TextAlignment, entry: TextEntryAnimation, exit: TextExitAnimation
    ) {
        self.fontCategory = fontCategory
        self.fontName = fontName
        self.weight = weight
        self.isItalic = isItalic
        self.allCaps = allCaps
        self.sizeRatio = sizeRatio
        self.letterSpacing = letterSpacing
        self.lineSpacing = lineSpacing
        self.colorHex = colorHex
        self.opacity = opacity
        self.hasShadow = hasShadow
        self.outline = outline
        self.background = background
        self.rotation = rotation
        self.alignment = alignment
        self.entry = entry
        self.exit = exit
    }

    public init(layer: TextLayer) {
        self.init(
            fontCategory: layer.fontCategory, fontName: layer.fontName, weight: layer.weight,
            isItalic: layer.isItalic, allCaps: layer.allCaps,
            sizeRatio: layer.sizeRatio, letterSpacing: layer.letterSpacing,
            lineSpacing: layer.lineSpacing, colorHex: layer.colorHex, opacity: layer.opacity,
            hasShadow: layer.hasShadow, outline: layer.outline, background: layer.background,
            rotation: layer.rotation, alignment: layer.alignment,
            entry: layer.entry, exit: layer.exit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case fontCategory, fontName, weight, isItalic, allCaps, sizeRatio, letterSpacing
        case lineSpacing, colorHex, opacity, hasShadow, outline, background, rotation
        case alignment, entry, exit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontCategory = try c.decode(FontCategory.self, forKey: .fontCategory)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        weight = try c.decodeIfPresent(TextWeight.self, forKey: .weight) ?? .bold
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        allCaps = try c.decodeIfPresent(Bool.self, forKey: .allCaps) ?? false
        sizeRatio = try c.decode(Double.self, forKey: .sizeRatio)
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.18
        colorHex = try c.decode(String.self, forKey: .colorHex)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        hasShadow = try c.decode(Bool.self, forKey: .hasShadow)
        outline = try c.decodeIfPresent(TextOutline.self, forKey: .outline)
        background = try c.decodeIfPresent(TextBackground.self, forKey: .background)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        alignment = try c.decode(TextAlignment.self, forKey: .alignment)
        entry = try c.decode(TextEntryAnimation.self, forKey: .entry)
        exit = try c.decode(TextExitAnimation.self, forKey: .exit)
    }

    public func applied(to layer: inout TextLayer) {
        layer.fontCategory = fontCategory
        layer.fontName = fontName
        layer.weight = weight
        layer.isItalic = isItalic
        layer.allCaps = allCaps
        layer.sizeRatio = sizeRatio
        layer.letterSpacing = letterSpacing
        layer.lineSpacing = lineSpacing
        layer.colorHex = colorHex
        layer.opacity = opacity
        layer.hasShadow = hasShadow
        layer.outline = outline
        layer.background = background
        layer.rotation = rotation
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

        case .batch(_, let commands):
            // Reverting walks backwards so each child sees the state its own apply left behind.
            for command in reverting ? commands.reversed() : commands {
                if reverting {
                    try command.revert(from: &t)
                } else {
                    try command.apply(to: &t)
                }
            }

        case .trimClip(let id, let duration, let sourceStart, let wasDuration, let wasSourceStart):
            let i = try clipIndex(id, in: t)
            t.clips[i].duration = reverting ? wasDuration : duration
            t.clips[i].sourceStart = reverting ? wasSourceStart : sourceStart

        case .splitClip(let id, let localTime, let newClipID, let wasDuration, let wasCropEnd):
            let i = try clipIndex(id, in: t)
            if reverting {
                t.clips.removeAll { $0.id == newClipID }
                t.clips[i].duration = wasDuration
                t.clips[i].cropEnd = wasCropEnd
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

        case .setClipFit(let id, let fitMode, let wasFitMode):
            let i = try clipIndex(id, in: t)
            t.clips[i].fitMode = reverting ? wasFitMode : fitMode

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
                // Throwing rather than no-op'ing matters: `removeAll` on something that is not
                // there succeeds silently, and reverting then *inserts* it — so an ineffective
                // delete would undo into a layer appearing from nowhere.
                guard t.textLayers.contains(where: { $0.id == layer.id }) else {
                    throw ReframeError.documentCorrupt(detail: "text layer \(layer.id) not present")
                }
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

        case .setTextWordTimings(let id, let timings, let wasTimings):
            let i = try textIndex(id, in: t)
            t.textLayers[i].wordTimings = reverting ? wasTimings : timings

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
                guard t.audio.contains(where: { $0.id == clip.id }) else {
                    throw ReframeError.documentCorrupt(detail: "audio clip \(clip.id) not present")
                }
                t.audio.removeAll { $0.id == clip.id }
            }

        case .setAudioVolume(let id, let volume, let wasVolume):
            let i = try audioIndex(id, in: t)
            t.audio[i].volume = reverting ? wasVolume : volume

        case .setAudioFades(let id, let fadeIn, let fadeOut, let wasFadeIn, let wasFadeOut):
            let i = try audioIndex(id, in: t)
            t.audio[i].fadeIn = reverting ? wasFadeIn : fadeIn
            t.audio[i].fadeOut = reverting ? wasFadeOut : fadeOut

        case .setAudioMuted(let id, let isMuted, let wasMuted):
            let i = try audioIndex(id, in: t)
            t.audio[i].isMuted = reverting ? wasMuted : isMuted

        case .retimeAudioClip(let id, let start, let duration, let sourceStart,
                              let wasStart, let wasDuration, let wasSourceStart):
            let i = try audioIndex(id, in: t)
            t.audio[i].start = max(0, reverting ? wasStart : start)
            t.audio[i].duration = max(0.05, reverting ? wasDuration : duration)
            t.audio[i].sourceStart = max(0, reverting ? wasSourceStart : sourceStart)

        case .setDucking(let enabled, let wasEnabled):
            t.duckMusicUnderVoice = reverting ? wasEnabled : enabled

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
                guard t.overlays.contains(where: { $0.id == layer.id }) else {
                    throw ReframeError.documentCorrupt(detail: "overlay \(layer.id) not present")
                }
                t.overlays.removeAll { $0.id == layer.id }
            }

        case .setOverlayFrame(let id, let frame, let wasFrame):
            guard let i = t.overlays.firstIndex(where: { $0.id == id }) else {
                throw ReframeError.documentCorrupt(detail: "overlay \(id) not found")
            }
            t.overlays[i].frame = reverting ? wasFrame : frame

        case .setCanvas(let canvas, let wasCanvas):
            t.canvas = reverting ? wasCanvas : canvas

        case .setBackground(let hex, let wasHex):
            t.backgroundHex = reverting ? wasHex : hex
        }
    }

    private func audioIndex(_ id: UUID, in t: Timeline) throws -> Int {
        guard let i = t.audio.firstIndex(where: { $0.id == id }) else {
            throw ReframeError.documentCorrupt(detail: "audio clip \(id) not found")
        }
        return i
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
