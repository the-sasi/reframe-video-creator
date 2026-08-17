import Accelerate
import CoreVideo
import Foundation

/// A frame decomposed into HSV planes plus a tiny luma thumbnail.
///
/// This is the analysis representation. Scene detection needs HSV (the proven basis for
/// content-difference cut detection); the dissolve test needs a small luma image it can afford
/// to keep dozens of.
public struct FrameSignature: Sendable {
    public let width: Int
    public let height: Int
    /// Normalised 0...1. Hue is 0...1 rather than 0...360 so all three channels share a scale
    /// and the weighted delta is meaningful without per-channel normalisation.
    public let hue: [Float]
    public let saturation: [Float]
    public let value: [Float]
    /// Fixed-size luma thumbnail (`thumbWidth` x `thumbHeight`), cheap to retain in a window.
    public let lumaThumb: [Float]
    /// Mean and standard deviation of luma. A collapsing standard deviation is the signature
    /// of a fade to a flat frame.
    public let lumaMean: Float
    public let lumaStdDev: Float

    public static let thumbWidth = 24
    public static let thumbHeight = 42

    public var pixelCount: Int { width * height }
}

public enum PixelAccess {

    /// Converts a BGRA pixel buffer into HSV planes and a luma thumbnail in a single pass.
    ///
    /// Written as one scalar loop rather than a partly-vectorised pipeline on purpose: hue
    /// requires per-pixel branching that vectorises badly, and splitting the work into vDSP
    /// passes would mean four traversals of the buffer plus temporaries. At analysis
    /// resolution (256 px longest edge, ~110k pixels) this is a few milliseconds a frame, and
    /// it is obviously correct, which the alternative would not be.
    public static func signature(from pixelBuffer: CVPixelBuffer) -> FrameSignature? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let count = width * height
        var hue = [Float](repeating: 0, count: count)
        var saturation = [Float](repeating: 0, count: count)
        var value = [Float](repeating: 0, count: count)

        let tw = FrameSignature.thumbWidth
        let th = FrameSignature.thumbHeight
        var thumb = [Float](repeating: 0, count: tw * th)
        var thumbCounts = [Float](repeating: 0, count: tw * th)

        let src = base.assumingMemoryBound(to: UInt8.self)
        let inv255: Float = 1.0 / 255.0

        hue.withUnsafeMutableBufferPointer { hp in
        saturation.withUnsafeMutableBufferPointer { sp in
        value.withUnsafeMutableBufferPointer { vp in
        thumb.withUnsafeMutableBufferPointer { tp in
        thumbCounts.withUnsafeMutableBufferPointer { cp in
            for y in 0..<height {
                let row = src + y * bytesPerRow
                let ty = min(th - 1, y * th / height)
                for x in 0..<width {
                    let p = row + x * 4
                    // BGRA byte order.
                    let b = Float(p[0]) * inv255
                    let g = Float(p[1]) * inv255
                    let r = Float(p[2]) * inv255

                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let delta = maxC - minC

                    var h: Float = 0
                    if delta > 1e-6 {
                        if maxC == r {
                            h = (g - b) / delta
                            if h < 0 { h += 6 }
                        } else if maxC == g {
                            h = (b - r) / delta + 2
                        } else {
                            h = (r - g) / delta + 4
                        }
                        h /= 6  // 0...1, so all three channels share a scale
                    }

                    let i = y * width + x
                    hp[i] = h
                    sp[i] = maxC > 1e-6 ? delta / maxC : 0
                    vp[i] = maxC

                    // Rec. 709 luma, accumulated into the thumbnail by box average.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let tx = min(tw - 1, x * tw / width)
                    let ti = ty * tw + tx
                    tp[ti] += luma
                    cp[ti] += 1
                }
            }
            for i in 0..<(tw * th) where cp[i] > 0 {
                tp[i] /= cp[i]
            }
        }}}}}

        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(thumb, 1, nil, 1, &mean, &stdDev, vDSP_Length(thumb.count))

        return FrameSignature(
            width: width, height: height,
            hue: hue, saturation: saturation, value: value,
            lumaThumb: thumb, lumaMean: mean, lumaStdDev: stdDev
        )
    }

    /// Mean absolute difference between two equal-length planes, via Accelerate.
    public static func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))
        vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(diff.count))
        var mean: Float = 0
        vDSP_meanv(diff, 1, &mean, vDSP_Length(diff.count))
        return mean
    }

    /// Hue is circular: 0.02 and 0.98 are adjacent reds, not opposite. Treating hue linearly
    /// makes every red-to-red frame look like a cut, which is a classic way to get a detector
    /// that fires constantly on warm footage.
    public static func meanCircularHueDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                for i in 0..<ap.count {
                    let d = abs(ap[i] - bp[i])
                    total += min(d, 1 - d)
                }
            }
        }
        // Max circular distance is 0.5; rescale to 0...1 so it weighs the same as S and V.
        return (total / Float(a.count)) * 2
    }

    /// Residual of the linear-blend model `frame ≈ (1-α)·from + α·to`.
    ///
    /// The classic dissolve test. A true cross-fade satisfies this with a small residual; a cut
    /// or a camera move does not. Runs on luma thumbnails, which is why they are worth keeping.
    public static func blendResidual(
        frame: [Float], from: [Float], to: [Float], alpha: Float
    ) -> Float {
        guard frame.count == from.count, frame.count == to.count, !frame.isEmpty else { return .infinity }
        var predicted = [Float](repeating: 0, count: frame.count)
        var scaledFrom = [Float](repeating: 0, count: frame.count)
        var oneMinus = 1 - alpha
        var a = alpha
        vDSP_vsmul(from, 1, &oneMinus, &scaledFrom, 1, vDSP_Length(frame.count))
        vDSP_vsmul(to, 1, &a, &predicted, 1, vDSP_Length(frame.count))
        vDSP_vadd(scaledFrom, 1, predicted, 1, &predicted, 1, vDSP_Length(frame.count))
        return meanAbsoluteDifference(frame, predicted)
    }
}
