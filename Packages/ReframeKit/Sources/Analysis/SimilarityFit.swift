import Foundation

/// Euclidean distance between two points.
///
/// Hand-written rather than `simd_distance` so this file depends on nothing but Foundation —
/// `SIMD2` is a stdlib type, and dropping `import simd` is what lets the whole fit be
/// typechecked and unit-tested off Darwin.
@inline(__always)
private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

/// Least-squares fit of a 2D similarity transform (uniform scale, rotation, translation) to a
/// set of point correspondences.
///
/// This is how camera motion is recovered from an optical-flow field: each flow vector is a
/// correspondence `(x, y) -> (x + u, y + v)`, and the transform that best explains all of them
/// *is* the camera move. A closed-form solution (the 2D case of Umeyama's method) rather than an
/// iterative solver — it is exact, it cannot fail to converge, and it runs in one pass.
///
/// Pure arithmetic with no framework dependency, so tests can synthesise a known 1.17x zoom and
/// assert the fit recovers 1.17.
public struct SimilarityFit: Sendable, Hashable {
    public var scale: Double
    public var rotation: Double
    public var translationX: Double
    public var translationY: Double
    /// Mean Euclidean distance between each transformed source point and its target, in the
    /// same units as the input. Low residual means the motion genuinely was a similarity
    /// transform; high residual means it was something else — parallax, a moving subject, a
    /// cut — and the caller should distrust the parameters.
    public var residual: Double
    public var pointCount: Int

    public static let identity = SimilarityFit(
        scale: 1, rotation: 0, translationX: 0, translationY: 0, residual: 0, pointCount: 0
    )

    public init(
        scale: Double, rotation: Double, translationX: Double,
        translationY: Double, residual: Double, pointCount: Int
    ) {
        self.scale = scale
        self.rotation = rotation
        self.translationX = translationX
        self.translationY = translationY
        self.residual = residual
        self.pointCount = pointCount
    }

    /// Fits `source[i] -> target[i]`.
    ///
    /// Runs twice: once over all points, then again over the 80% with the smallest residual.
    /// The trimmed second pass is what makes this robust to a moving subject — a person walking
    /// through a static shot contributes flow vectors that disagree with the camera, and
    /// without trimming they drag the fit toward a pan that never happened.
    public static func fit(source: [SIMD2<Double>], target: [SIMD2<Double>]) -> SimilarityFit {
        guard source.count == target.count, source.count >= 3 else { return .identity }

        let first = solve(source: source, target: target)
        guard first.pointCount > 0 else { return .identity }

        // Trim the worst 20% and re-solve.
        let errors = zip(source, target).map { s, t -> Double in
            distance(first.apply(to: s), t)
        }
        let keepCount = max(3, Int(Double(source.count) * 0.8))
        let keptIndices = errors.enumerated()
            .sorted { $0.element < $1.element }
            .prefix(keepCount)
            .map(\.offset)

        guard keptIndices.count >= 3 else { return first }
        let trimmedSource = keptIndices.map { source[$0] }
        let trimmedTarget = keptIndices.map { target[$0] }
        return solve(source: trimmedSource, target: trimmedTarget)
    }

    private static func solve(source: [SIMD2<Double>], target: [SIMD2<Double>]) -> SimilarityFit {
        let n = Double(source.count)
        guard n >= 3 else { return .identity }

        var meanSource = SIMD2<Double>(0, 0)
        var meanTarget = SIMD2<Double>(0, 0)
        for i in source.indices {
            meanSource += source[i]
            meanTarget += target[i]
        }
        meanSource /= n
        meanTarget /= n

        // a = sum of dot products, b = sum of cross products. Together they encode the rotation
        // angle and the scale of the best-fit similarity.
        var a = 0.0
        var b = 0.0
        var sourceVariance = 0.0
        for i in source.indices {
            let p = source[i] - meanSource
            let q = target[i] - meanTarget
            a += p.x * q.x + p.y * q.y
            b += p.x * q.y - p.y * q.x
            sourceVariance += p.x * p.x + p.y * p.y
        }

        guard sourceVariance > 1e-9 else { return .identity }

        let rotation = atan2(b, a)
        let scale = (a * a + b * b).squareRoot() / sourceVariance

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let rotatedMeanSource = SIMD2<Double>(
            scale * (cosR * meanSource.x - sinR * meanSource.y),
            scale * (sinR * meanSource.x + cosR * meanSource.y)
        )
        let translation = meanTarget - rotatedMeanSource

        var fit = SimilarityFit(
            scale: scale, rotation: rotation,
            translationX: translation.x, translationY: translation.y,
            residual: 0, pointCount: source.count
        )

        var totalError = 0.0
        for i in source.indices {
            totalError += distance(fit.apply(to: source[i]), target[i])
        }
        fit.residual = totalError / n
        return fit
    }

    public func apply(to point: SIMD2<Double>) -> SIMD2<Double> {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return SIMD2<Double>(
            scale * (cosR * point.x - sinR * point.y) + translationX,
            scale * (sinR * point.x + cosR * point.y) + translationY
        )
    }
}
