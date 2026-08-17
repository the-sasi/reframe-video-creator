import Foundation

/// Optimal assignment for a rectangular cost matrix — the Kuhn–Munkres (Hungarian) algorithm
/// in its O(n³) shortest-augmenting-path form.
///
/// Auto Arrange is exactly the assignment problem: N slots, M photos, a cost for every pairing,
/// and a requirement to minimise the total. Greedy "best photo for slot 1, then best remaining
/// for slot 2" is the obvious approach and it is *wrong* in a way users notice — it spends the
/// only good close-up on slot 1 and leaves slot 4, which needed it, with nothing.
///
/// At our scale (≤30 × ≤30) the cubic cost is microseconds, so there is no reason to accept a
/// worse answer. Pure arithmetic, no dependencies, and tested against brute force on random
/// 6×6 matrices.
public struct HungarianSolver: Sendable {

    public init() {}

    /// Returns `assignment[row] = column`, or `-1` for an unassigned row.
    /// Requires `rows <= columns`; callers pad the matrix if that does not hold.
    public func solve(cost: [[Double]]) -> [Int] {
        let n = cost.count
        guard n > 0 else { return [] }
        let m = cost[0].count
        guard m >= n else { return Array(repeating: -1, count: n) }

        // 1-indexed throughout; index 0 is the algorithm's sentinel column.
        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: m + 1)
        var p = [Int](repeating: 0, count: m + 1)
        var way = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minValues = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)

            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0

                for j in 1...m where !used[j] {
                    let current = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if current < minValues[j] {
                        minValues[j] = current
                        way[j] = j0
                    }
                    if minValues[j] < delta {
                        delta = minValues[j]
                        j1 = j
                    }
                }

                guard delta.isFinite else { break }

                for j in 0...m {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minValues[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0

            // Walk the augmenting path back, flipping assignments.
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var assignment = [Int](repeating: -1, count: n)
        for j in 1...m where p[j] > 0 {
            assignment[p[j] - 1] = j - 1
        }
        return assignment
    }

    /// Total cost of an assignment. Used by the diversity refiner to check that a proposed swap
    /// actually improves things.
    public func totalCost(of assignment: [Int], in cost: [[Double]]) -> Double {
        var total = 0.0
        for (row, column) in assignment.enumerated() where column >= 0 && row < cost.count {
            total += cost[row][column]
        }
        return total
    }
}
