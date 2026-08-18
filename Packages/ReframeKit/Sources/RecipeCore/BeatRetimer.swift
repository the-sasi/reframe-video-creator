import Foundation

/// Moves the timeline's cuts onto a *new* beat grid — the user's own music — while keeping every
/// clip, asset and order exactly as they are.
///
/// The reference said "cut on the beat"; the binder honoured that against the reference's grid.
/// When the user brings a track at 124 BPM instead of 128, the cuts should land on *their*
/// beats. This is the same cumulative quantisation the binder uses: boundaries snap to the
/// nearest beat within tolerance, monotonicity is enforced, durations are the differences, and
/// the whole thing is one batched, undoable command.
public enum BeatRetimer {

    public struct Result: Sendable, Hashable {
        public var command: EditCommand
        /// How many boundaries actually moved.
        public var movedBoundaries: Int
        /// Mean absolute shift, in seconds, over the boundaries that moved.
        public var meanShift: Double
    }

    /// Nil when nothing would move (already on the grid, or no beats in range).
    public static func retime(
        _ timeline: Timeline,
        toBeats beats: [Double],
        tolerance: Double = 0.14,
        minimumDuration: Double? = nil
    ) -> Result? {
        let clips = timeline.clips
        guard clips.count >= 1, !beats.isEmpty else { return nil }
        let sorted = beats.sorted()
        let minimum = minimumDuration ?? timeline.canvas.frameDuration * 3

        // Boundaries: start of the first clip, then every clip end. The first boundary stays.
        var boundaries: [Double] = [clips[0].start] + clips.map(\.end)
        var moved = 0
        var totalShift = 0.0

        for i in 1..<boundaries.count {
            let original = boundaries[i]
            guard let nearest = nearestBeat(to: original, in: sorted), abs(nearest - original) <= tolerance else { continue }
            // Keep the sequence monotonic and each clip at least `minimum` long.
            let lowerBound = boundaries[i - 1] + minimum
            let candidate = max(nearest, lowerBound)
            if abs(candidate - original) > 0.001 {
                moved += 1
                totalShift += abs(candidate - original)
            }
            boundaries[i] = candidate
        }
        guard moved > 0 else { return nil }

        var commands: [EditCommand] = []
        for (index, clip) in clips.enumerated() {
            let duration = max(minimum, timeline.canvas.snapToFrame(boundaries[index + 1] - boundaries[index]))
            guard abs(duration - clip.duration) > 0.0005 else { continue }
            commands.append(
                .trimClip(id: clip.id, duration: duration, sourceStart: clip.sourceStart,
                          wasDuration: clip.duration, wasSourceStart: clip.sourceStart)
            )
        }
        guard !commands.isEmpty else { return nil }
        return Result(
            command: .batch(name: "Snap Cuts to Music", commands: commands),
            movedBoundaries: moved,
            meanShift: totalShift / Double(moved)
        )
    }

    /// How many of the timeline's cuts already sit within `tolerance` of a beat, as a fraction.
    public static func alignment(of timeline: Timeline, toBeats beats: [Double], tolerance: Double = 0.08) -> Double {
        let cuts = timeline.clips.dropFirst().map(\.start)
        guard !cuts.isEmpty, !beats.isEmpty else { return 0 }
        let sorted = beats.sorted()
        let aligned = cuts.filter { cut in
            guard let nearest = nearestBeat(to: cut, in: sorted) else { return false }
            return abs(nearest - cut) <= tolerance
        }.count
        return Double(aligned) / Double(cuts.count)
    }

    private static func nearestBeat(to time: Double, in sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        // Binary search for the insertion point, then compare neighbours.
        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < time { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { $0 >= 0 && $0 < sorted.count }.map { sorted[$0] }
        return candidates.min { abs($0 - time) < abs($1 - time) }
    }
}
