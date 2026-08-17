import Accelerate
import CoreGraphics
import Foundation
import RecipeCore

/// Dominant-colour extraction and grade inference.
///
/// k-means over downsampled pixels. Deterministic by construction: centroids are seeded by
/// even spacing through the sorted-by-luma sample set rather than randomly, so the same frames
/// always produce the same palette in the same order. Random seeding would make recipe JSON
/// differ run to run, which would break the determinism guarantee for no benefit.
public struct ColorAnalyzer: Sendable {

    public struct RGB: Sendable, Hashable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public var hexString: String {
            String(
                format: "#%02X%02X%02X",
                Int((min(max(r, 0), 1) * 255).rounded()),
                Int((min(max(g, 0), 1) * 255).rounded()),
                Int((min(max(b, 0), 1) * 255).rounded())
            )
        }

        public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        public var saturation: Double {
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            return maxC > 1e-6 ? (maxC - minC) / maxC : 0
        }

        public func distanceSquared(to other: RGB) -> Double {
            let dr = r - other.r
            let dg = g - other.g
            let db = b - other.b
            return dr * dr + dg * dg + db * db
        }
    }

    public init() {}

    /// k-means with deterministic seeding and a fixed iteration cap.
    public func dominantColors(from samples: [RGB], k: Int = 3, iterations: Int = 8) -> [RGB] {
        guard !samples.isEmpty else { return [] }
        guard samples.count > k else { return samples }

        // Deterministic seeding: sort by luma, take evenly spaced picks. Spreads the initial
        // centroids across the tonal range, which converges faster than random seeding *and*
        // gives the same answer every time.
        let sorted = samples.sorted { $0.luma < $1.luma }
        var centroids: [RGB] = (0..<k).map { i in
            sorted[min(sorted.count - 1, i * sorted.count / max(1, k - 1))]
        }

        var assignments = [Int](repeating: 0, count: samples.count)

        for _ in 0..<iterations {
            var changed = false
            for (i, sample) in samples.enumerated() {
                var best = 0
                var bestDistance = Double.infinity
                for (j, centroid) in centroids.enumerated() {
                    let d = sample.distanceSquared(to: centroid)
                    if d < bestDistance {
                        bestDistance = d
                        best = j
                    }
                }
                if assignments[i] != best {
                    assignments[i] = best
                    changed = true
                }
            }

            var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, sample) in samples.enumerated() {
                let c = assignments[i]
                sums[c].r += sample.r
                sums[c].g += sample.g
                sums[c].b += sample.b
                counts[c] += 1
            }
            for j in 0..<k where counts[j] > 0 {
                let n = Double(counts[j])
                centroids[j] = RGB(r: sums[j].r / n, g: sums[j].g / n, b: sums[j].b / n)
            }

            if !changed { break }
        }

        // Order by cluster population so "dominant" actually means dominant.
        var counts = [Int](repeating: 0, count: k)
        for assignment in assignments { counts[assignment] += 1 }
        return zip(centroids, counts)
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Samples pixels from a CGImage on a stride, for palette extraction.
    public func sample(image: CGImage, maxSamples: Int = 2000) -> [RGB] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        // Render into a known layout rather than trusting the source's — CGImage can be any of
        // a dozen pixel formats and reading them all correctly is not worth it.
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }

        let totalPixels = width * height
        let stride = max(1, totalPixels / maxSamples)
        var samples: [RGB] = []
        samples.reserveCapacity(min(maxSamples, totalPixels))

        var index = 0
        while index < totalPixels {
            let offset = index * 4
            let alpha = Double(buffer[offset + 3]) / 255
            // Skip transparent pixels — a logo's background is not part of its palette.
            if alpha > 0.5 {
                samples.append(
                    RGB(
                        r: Double(buffer[offset]) / 255,
                        g: Double(buffer[offset + 1]) / 255,
                        b: Double(buffer[offset + 2]) / 255
                    )
                )
            }
            index += stride
        }
        return samples
    }

    public func palette(from samples: [RGB]) -> ScenePalette {
        guard !samples.isEmpty else {
            return ScenePalette(dominant: [], brightness: 0.5, saturation: 0.5, contrast: 1)
        }
        let dominant = dominantColors(from: samples, k: 3)
        let lumas = samples.map(\.luma)
        let meanLuma = lumas.reduce(0, +) / Double(lumas.count)
        let variance = lumas.reduce(0) { $0 + pow($1 - meanLuma, 2) } / Double(lumas.count)
        let meanSaturation = samples.map(\.saturation).reduce(0, +) / Double(samples.count)

        return ScenePalette(
            dominant: dominant.map(\.hexString),
            brightness: meanLuma,
            saturation: meanSaturation,
            // Standard deviation of luma, rescaled so ~0.29 (a well-exposed frame) maps to 1.0.
            contrast: min(2.0, variance.squareRoot() / 0.29)
        )
    }

    /// Infers a grade that would move the user's asset toward the reference's look.
    ///
    /// Deliberately gentle and clamped. An aggressive automatic grade applied to somebody
    /// else's photographs looks like a bug, not a feature, and the binder leaves this off by
    /// default — it is opt-in from the Style sheet.
    public func inferGrade(assetPalette: ScenePalette, referencePalette: ScenePalette) -> ColorGrade {
        let exposureDelta = (referencePalette.brightness - assetPalette.brightness) * 0.5
        let saturationRatio = assetPalette.saturation > 0.01
            ? referencePalette.saturation / assetPalette.saturation
            : 1
        let contrastRatio = assetPalette.contrast > 0.01
            ? referencePalette.contrast / assetPalette.contrast
            : 1

        return ColorGrade(
            exposure: min(max(exposureDelta, -0.25), 0.25),
            contrast: min(max(1 + (contrastRatio - 1) * 0.4, 0.85), 1.25),
            saturation: min(max(1 + (saturationRatio - 1) * 0.4, 0.80), 1.30),
            temperature: 0  // Not inferable from a palette without a white-balance reference.
        )
    }
}
