import Foundation

/// A cheap sanity score for automatically generated edits.
///
/// This is not a film critic. Its one job is catching *obviously* bad output before the user
/// sees it — the same photo three times in a row, a clip two frames long, an empty slot, a
/// planned beat-cut edit whose cuts drift off the grid. The caller uses it two ways: pick the
/// better of a few candidate arrangements, and log the issues so a bad edit is diagnosable.
///
/// Pure and deterministic — timeline in, verdict out — so it runs in CoreCheck on any platform.
public struct EditQuality: Sendable, Hashable {

    public struct Issue: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case emptySlot          // a clip with no asset assigned
            case adjacentRepeat     // same asset in consecutive clips
            case overusedAsset      // one asset carrying too much of the edit
            case tooShortClip       // clip shorter than perception allows
            case offGridCut         // beat-planned edit with cuts off the grid
            case lowDiversity       // few distinct assets across many slots
            case longStillScene     // many seconds of a single photo
        }

        public var kind: Kind
        /// Index of the offending clip, where one clip is to blame.
        public var clipIndex: Int?
        public var detail: String

        public init(kind: Kind, clipIndex: Int? = nil, detail: String) {
            self.kind = kind
            self.clipIndex = clipIndex
            self.detail = detail
        }
    }

    /// 0...1. Weighted mean of the component scores.
    public var total: Double
    /// 0...1 each.
    public var rhythm: Double
    public var diversity: Double
    public var continuity: Double
    public var coverage: Double
    public var issues: [Issue]

    /// Below this, an automatic edit should be repaired (re-arranged) before presenting.
    public static let acceptableThreshold = 0.55

    public var isAcceptable: Bool { total >= Self.acceptableThreshold }

    /// One line for the diagnostics log.
    public var summary: String {
        String(
            format: "quality %.2f (rhythm %.2f, diversity %.2f, continuity %.2f, coverage %.2f), %d issue(s)",
            total, rhythm, diversity, continuity, coverage, issues.count
        )
    }

    // MARK: - Scoring

    /// A still photo can hold a shot for a while; past this it reads as a stalled video.
    public static let longStillThreshold: Double = 7.0

    public static func score(
        timeline: Timeline,
        beatGrid: BeatGrid? = nil,
        assets: AssetPool? = nil
    ) -> EditQuality {
        let clips = timeline.clips
        guard !clips.isEmpty else {
            return EditQuality(
                total: 0, rhythm: 0, diversity: 0, continuity: 0, coverage: 0,
                issues: [Issue(kind: .emptySlot, detail: "timeline has no clips")]
            )
        }

        var issues: [Issue] = []
        let frame = timeline.canvas.frameDuration

        // --- Coverage: every slot filled, no unusably short clips. ---
        var filled = 0
        for (index, clip) in clips.enumerated() {
            if clip.assetID == nil {
                issues.append(Issue(kind: .emptySlot, clipIndex: index, detail: "scene \(index + 1) has no asset"))
            } else {
                filled += 1
            }
            if clip.duration < frame * 3 {
                issues.append(Issue(
                    kind: .tooShortClip, clipIndex: index,
                    detail: String(format: "scene %d is %.0f ms", index + 1, clip.duration * 1000)
                ))
            }
        }
        let shortCount = issues.filter { $0.kind == .tooShortClip }.count
        let coverage = (Double(filled) / Double(clips.count)) * max(0, 1 - Double(shortCount) / Double(clips.count))

        // --- Long stills: a photo dragged across many seconds of timeline. Flagged, and a
        // mild penalty at the end — arrangement can't fix it, but the log should say it. ---
        if let assets {
            for (index, clip) in clips.enumerated() {
                guard let id = clip.assetID, let asset = assets[id], asset.kind == .image else { continue }
                if clip.duration > longStillThreshold {
                    issues.append(Issue(
                        kind: .longStillScene, clipIndex: index,
                        detail: String(format: "scene %d is %.0fs of a single photo", index + 1, clip.duration)
                    ))
                }
            }
        }

        // --- Continuity: no asset twice in a row. ---
        var adjacentRepeats = 0
        for index in 1..<clips.count {
            if let id = clips[index].assetID, id == clips[index - 1].assetID {
                adjacentRepeats += 1
                issues.append(Issue(
                    kind: .adjacentRepeat, clipIndex: index,
                    detail: "scenes \(index) and \(index + 1) show the same asset"
                ))
            }
        }
        let continuity = clips.count > 1
            ? 1 - Double(adjacentRepeats) / Double(clips.count - 1)
            : 1

        // --- Diversity: distinct assets vs slots, and no single asset dominating. ---
        let assetIDs = clips.compactMap(\.assetID)
        let counts = Dictionary(grouping: assetIDs, by: { $0 }).mapValues(\.count)
        let distinct = counts.count
        var diversity = 1.0
        if !assetIDs.isEmpty {
            // Distinct assets over filled slots. With fewer assets than slots reuse is
            // expected — the dominance check below is what catches *lopsided* reuse.
            diversity = Double(distinct) / Double(max(1, min(assetIDs.count, clips.count)))
            if let (id, worst) = counts.max(by: { $0.value < $1.value }), assetIDs.count >= 4 {
                let share = Double(worst) / Double(assetIDs.count)
                // With fewer assets than slots, some asset must repeat; only lopsidedness
                // beyond the even-spread expectation is a defect.
                let expectedShare = Double((assetIDs.count + distinct - 1) / distinct) / Double(assetIDs.count)
                if share > max(0.4, expectedShare + 0.12) {
                    diversity *= max(0.3, 1.4 - share * 2)
                    issues.append(Issue(
                        kind: .overusedAsset,
                        detail: "one asset (\(id.uuidString.prefix(8))) fills \(Int(share * 100))% of scenes"
                    ))
                }
            }
            if distinct == 1 && clips.count >= 3 {
                issues.append(Issue(kind: .lowDiversity, detail: "every scene uses the same asset"))
            }
        } else {
            diversity = 0
        }

        // --- Rhythm: if this edit claims beat alignment, measure it. ---
        var rhythm = 1.0
        if let grid = beatGrid, grid.cutsAlignedToBeats.value, !grid.beats.isEmpty, clips.count > 1 {
            let tolerance = max(0.08, frame * 2)
            var aligned = 0
            var boundaries = 0
            for clip in clips.dropLast() {
                let end = clip.end
                guard end > 0.01 else { continue }
                boundaries += 1
                if grid.nearestBeat(to: end, tolerance: tolerance) != nil { aligned += 1 }
            }
            if boundaries > 0 {
                rhythm = Double(aligned) / Double(boundaries)
                if rhythm < 0.5 {
                    issues.append(Issue(
                        kind: .offGridCut,
                        detail: "only \(aligned)/\(boundaries) cuts land on the beat grid"
                    ))
                }
            }
        }

        var total = coverage * 0.35 + continuity * 0.25 + diversity * 0.20 + rhythm * 0.20
        // An empty slot is a hard failure: a black scene cannot be averaged away by good
        // rhythm elsewhere. The cap keeps the ordering (fewer holes still scores higher)
        // while guaranteeing the edit reads as needing repair.
        if issues.contains(where: { $0.kind == .emptySlot }) {
            total = min(total, Self.acceptableThreshold - 0.1)
        }
        let longStills = issues.filter { $0.kind == .longStillScene }.count
        if longStills > 0 {
            total = max(0, total - 0.05 * Double(longStills))
        }
        return EditQuality(
            total: min(max(total, 0), 1),
            rhythm: rhythm, diversity: min(max(diversity, 0), 1),
            continuity: continuity, coverage: coverage,
            issues: issues
        )
    }
}
