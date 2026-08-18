import Foundation

/// Alternative treatments of the same structure and the same assets — the "generate three
/// variations" the product offers without any generative model.
///
/// Each variation is a pure function from the current timeline to one batched `EditCommand`,
/// so applying one is a single undo step and never touches the asset assignment. "Closest to
/// the reference" is what the binder produced; the others re-decide transitions, motion and
/// look while keeping every cut where it was.
public enum EditVariation: String, CaseIterable, Identifiable, Sendable {
    /// Same structure, a varied set of transitions instead of the reference's.
    case alternateTransitions
    /// Slow dissolves, gentle push-ins, a film look, fade out at the end.
    case cinematic
    /// Hard cuts, alternating push/pull, vivid colour.
    case punchy
    /// Everything static and cut — the quietest read of the same timing.
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alternateTransitions: return "Different transitions"
        case .cinematic: return "Cinematic"
        case .punchy: return "Punchy"
        case .minimal: return "Minimal"
        }
    }

    public var summary: String {
        switch self {
        case .alternateTransitions: return "Same cuts and moves; a fresh mix of dissolves, pushes and slides."
        case .cinematic: return "Slow dissolves, gentle push-ins, a film grade, and a fade to black."
        case .punchy: return "Hard cuts, alternating push and pull, vivid colour."
        case .minimal: return "Cuts only, no motion, neutral colour. Just the rhythm."
        }
    }

    /// The batched command that turns `timeline` into this variation. Nil if there is nothing
    /// to change (an empty timeline).
    public func command(for timeline: Timeline) -> EditCommand? {
        let clips = timeline.clips
        guard !clips.isEmpty else { return nil }
        var commands: [EditCommand] = []

        switch self {
        case .alternateTransitions:
            // A cycle chosen so neighbours never repeat and cuts still appear — an all-effects
            // reel reads as a slideshow from 2009.
            let cycle: [Transition?] = [
                Transition(kind: .dissolve, duration: 0.3),
                nil,
                Transition(kind: .push, duration: 0.32, direction: .left),
                nil,
                Transition(kind: .slide, duration: 0.3, direction: .up),
                Transition(kind: .zoomIn, duration: 0.36),
                nil,
            ]
            for (index, clip) in clips.enumerated() where index > 0 {
                let next = cycle[(index - 1) % cycle.count]
                if next != clip.transitionIn {
                    commands.append(.setTransition(clipID: clip.id, transition: next, wasTransition: clip.transitionIn))
                }
            }

        case .cinematic:
            let film = FilterPreset.all.first { $0.id == "film" } ?? .none
            for (index, clip) in clips.enumerated() {
                if index > 0 {
                    let isLast = index == clips.count - 1
                    let transition = isLast
                        ? Transition(kind: .fadeToBlack, duration: 0.6)
                        : Transition(kind: .dissolve, duration: min(0.6, max(0.3, clip.duration * 0.35)))
                    if transition != clip.transitionIn {
                        commands.append(.setTransition(clipID: clip.id, transition: transition, wasTransition: clip.transitionIn))
                    }
                }
                // Gentle push-in inside the clip's current fill window, alternating direction so
                // a run of stills breathes rather than zooms.
                let base = clip.cropStart.width >= clip.cropEnd.width ? clip.cropStart : clip.cropEnd
                let tight = base.scaled(by: 0.9).clampedInsideUnitSquare()
                let (start, end) = index.isMultiple(of: 2) ? (base, tight) : (tight, base)
                if start != clip.cropStart || end != clip.cropEnd {
                    commands.append(.setClipCrop(id: clip.id, start: start, end: end, wasStart: clip.cropStart, wasEnd: clip.cropEnd))
                }
                if clip.grade != film.grade {
                    commands.append(.setClipGrade(id: clip.id, grade: film.grade, wasGrade: clip.grade))
                }
                if clip.vignette != film.vignette || clip.grain != film.grain {
                    commands.append(.setClipEffects(id: clip.id, vignette: film.vignette, grain: film.grain,
                                                    wasVignette: clip.vignette, wasGrain: clip.grain))
                }
            }

        case .punchy:
            let vivid = FilterPreset.all.first { $0.id == "vivid" } ?? .none
            for (index, clip) in clips.enumerated() {
                if index > 0, clip.transitionIn != nil {
                    commands.append(.setTransition(clipID: clip.id, transition: nil, wasTransition: clip.transitionIn))
                }
                let base = clip.cropStart.width >= clip.cropEnd.width ? clip.cropStart : clip.cropEnd
                let tight = base.scaled(by: 0.84).clampedInsideUnitSquare()
                let (start, end) = index.isMultiple(of: 2) ? (base, tight) : (tight, base)
                if start != clip.cropStart || end != clip.cropEnd {
                    commands.append(.setClipCrop(id: clip.id, start: start, end: end, wasStart: clip.cropStart, wasEnd: clip.cropEnd))
                }
                if clip.grade != vivid.grade {
                    commands.append(.setClipGrade(id: clip.id, grade: vivid.grade, wasGrade: clip.grade))
                }
                if clip.vignette != 0 || clip.grain != 0 {
                    commands.append(.setClipEffects(id: clip.id, vignette: 0, grain: 0, wasVignette: clip.vignette, wasGrain: clip.grain))
                }
            }

        case .minimal:
            for (index, clip) in clips.enumerated() {
                if index > 0, clip.transitionIn != nil {
                    commands.append(.setTransition(clipID: clip.id, transition: nil, wasTransition: clip.transitionIn))
                }
                let base = clip.cropStart.width >= clip.cropEnd.width ? clip.cropStart : clip.cropEnd
                if base != clip.cropStart || base != clip.cropEnd {
                    commands.append(.setClipCrop(id: clip.id, start: base, end: base, wasStart: clip.cropStart, wasEnd: clip.cropEnd))
                }
                if !clip.grade.isNeutral {
                    commands.append(.setClipGrade(id: clip.id, grade: .neutral, wasGrade: clip.grade))
                }
                if clip.vignette != 0 || clip.grain != 0 {
                    commands.append(.setClipEffects(id: clip.id, vignette: 0, grain: 0, wasVignette: clip.vignette, wasGrain: clip.grain))
                }
            }
        }

        guard !commands.isEmpty else { return nil }
        return .batch(name: displayName, commands: commands)
    }
}
