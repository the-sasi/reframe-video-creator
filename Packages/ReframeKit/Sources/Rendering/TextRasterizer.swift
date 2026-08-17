import CoreGraphics
import CoreText
import Foundation
import Metal
import RecipeCore

/// Text laid out and rasterised into GPU textures.
///
/// Layout happens on the CPU and is cached; animation is applied per-frame by the renderer from
/// each word's `opacity`, `offsetY` and `scale`. So a word-by-word reveal costs one cache lookup
/// and N quad draws, not N rasterisations per frame.
public struct RasterizedText: @unchecked Sendable {
    public struct Piece {
        public let texture: MTLTexture
        /// Where this word sits on the canvas, normalised, before animation offsets.
        public let rect: NormalizedRect
    }
    public let pieces: [Piece]
}

/// Core Text -> `CGContext` -> `MTLTexture`, cached by `(string, style, pixel size)`.
///
/// Deliberately not `AVVideoCompositionCoreAnimationTool`: that path corrupts colour on HDR
/// export, has a documented regression where overlays are absent for the first ~1 s, softens
/// composited overlays, and is export-only — which would reintroduce exactly the preview/export
/// divergence this architecture is built to avoid.
///
/// Core Text rather than UIKit so `Rendering` links no UI framework and the engine's tests run
/// on macOS.
public final class TextRasterizer: @unchecked Sendable {

    private let device: MTLDevice
    private let cache = NSCache<NSString, CacheEntry>()
    private let lock = NSLock()

    private final class CacheEntry {
        let value: RasterizedText
        init(_ value: RasterizedText) { self.value = value }
    }

    public init(device: MTLDevice) {
        self.device = device
        // Bounded, and dropped wholesale on memory pressure by `evictAll()`.
        cache.countLimit = 64
    }

    public func evictAll() {
        cache.removeAllObjects()
    }

    public func rasterize(_ draw: TextDraw, canvas: CanvasSpec) -> RasterizedText? {
        let key = cacheKey(draw, canvas: canvas) as NSString

        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        guard let result = build(draw, canvas: canvas) else { return nil }

        lock.lock()
        cache.setObject(CacheEntry(result), forKey: key)
        lock.unlock()
        return result
    }

    /// Keyed on everything that affects the *pixels*, and nothing that affects only animation —
    /// per-word opacity and offset must not invalidate the cache, or the cache is useless
    /// during exactly the animation it exists to make cheap.
    private func cacheKey(_ draw: TextDraw, canvas: CanvasSpec) -> String {
        let words = draw.words.map(\.text).joined(separator: "\u{1F}")
        return [
            words,
            draw.fontCategory.rawValue,
            String(format: "%.4f", draw.sizeRatio),
            String(format: "%.3f,%.3f,%.3f", draw.color.x, draw.color.y, draw.color.z),
            draw.hasShadow ? "s1" : "s0",
            draw.alignment.rawValue,
            String(format: "%.3f,%.3f", draw.frame.width, draw.frame.height),
            "\(canvas.width)x\(canvas.height)",
        ].joined(separator: "|")
    }

    // MARK: - Layout & rasterisation

    private func build(_ draw: TextDraw, canvas: CanvasSpec) -> RasterizedText? {
        let pointSize = draw.sizeRatio * Double(canvas.height)
        guard pointSize >= 4 else { return nil }

        let font = Self.font(for: draw.fontCategory, size: pointSize)
        let frameWidthPixels = draw.frame.width * Double(canvas.width)

        // Measure every word, then wrap greedily. Greedy wrapping is what people expect from a
        // caption; Core Text's paragraph layout would be better typography and worse at telling
        // us where each individual word landed, which is what word-by-word reveal needs.
        struct Measured {
            let text: String
            let width: Double
            let ascent: Double
            let descent: Double
        }

        let spaceWidth = Self.measure(" ", font: font).width

        let measured: [Measured] = draw.words.map { word in
            let m = Self.measure(word.text, font: font)
            return Measured(text: word.text, width: m.width, ascent: m.ascent, descent: m.descent)
        }

        var lines: [[Int]] = []
        var currentLine: [Int] = []
        var currentWidth = 0.0
        for (index, word) in measured.enumerated() {
            let additional = currentLine.isEmpty ? word.width : spaceWidth + word.width
            if !currentLine.isEmpty, currentWidth + additional > frameWidthPixels {
                lines.append(currentLine)
                currentLine = [index]
                currentWidth = word.width
            } else {
                currentLine.append(index)
                currentWidth += additional
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        guard !lines.isEmpty else { return nil }

        let lineHeight = (measured.first?.ascent ?? pointSize) + (measured.first?.descent ?? 0)
        let lineSpacing = lineHeight * 1.18
        let totalHeight = lineSpacing * Double(lines.count)

        // Vertically centre the block in its frame. The recipe's frame is where the reference's
        // text *was*; centring within it survives the user's copy being a different length.
        let frameCenterY = (draw.frame.y + draw.frame.height / 2) * Double(canvas.height)
        var cursorY = frameCenterY - totalHeight / 2

        var pieces: [RasterizedText.Piece] = []
        pieces.reserveCapacity(measured.count)

        for line in lines {
            let lineWidth = line.enumerated().reduce(0.0) { partial, element in
                partial + measured[element.element].width
                    + (element.offset > 0 ? spaceWidth : 0)
            }

            var cursorX: Double
            switch draw.alignment {
            case .leading:
                cursorX = draw.frame.x * Double(canvas.width)
            case .trailing:
                cursorX = (draw.frame.x + draw.frame.width) * Double(canvas.width) - lineWidth
            case .center:
                cursorX = (draw.frame.x + draw.frame.width / 2) * Double(canvas.width) - lineWidth / 2
            }

            for (offset, wordIndex) in line.enumerated() {
                let word = measured[wordIndex]
                if offset > 0 { cursorX += spaceWidth }

                guard let texture = rasterizeWord(
                    word.text, font: font, color: draw.color,
                    hasShadow: draw.hasShadow,
                    width: word.width, ascent: word.ascent, descent: word.descent
                ) else {
                    cursorX += word.width
                    continue
                }

                // The texture is padded for the shadow, so its rect is wider than the glyphs.
                let padding = draw.hasShadow ? Self.shadowPadding(for: pointSize) : 0
                let rect = NormalizedRect(
                    x: (cursorX - padding) / Double(canvas.width),
                    y: (cursorY - padding) / Double(canvas.height),
                    width: (word.width + padding * 2) / Double(canvas.width),
                    height: (lineHeight + padding * 2) / Double(canvas.height)
                )
                pieces.append(RasterizedText.Piece(texture: texture, rect: rect))
                cursorX += word.width
            }
            cursorY += lineSpacing
        }

        guard !pieces.isEmpty else { return nil }
        return RasterizedText(pieces: pieces)
    }

    private static func shadowPadding(for pointSize: Double) -> Double {
        max(2, pointSize * 0.09)
    }

    private static func measure(_ text: String, font: CTFont) -> (width: Double, ascent: Double, descent: Double) {
        let attributed = NSAttributedString(
            string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (Double(width), Double(ascent), Double(descent))
    }

    private func rasterizeWord(
        _ text: String, font: CTFont, color: SIMD4<Float>, hasShadow: Bool,
        width: Double, ascent: Double, descent: Double
    ) -> MTLTexture? {
        let pointSize = CTFontGetSize(font)
        let padding = hasShadow ? Self.shadowPadding(for: Double(pointSize)) : 0
        let pixelWidth = Int(ceil(width + padding * 2))
        let pixelHeight = Int(ceil(ascent + descent + padding * 2))
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 4096, pixelHeight < 4096 else {
            return nil
        }

        let bytesPerRow = pixelWidth * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)

        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(true)

            if hasShadow {
                // Soft drop shadow. Reels are watched over unpredictable footage, and a shadow
                // is the difference between readable and not — which is why the binder defaults
                // it on when the analyser could not tell.
                context.setShadow(
                    offset: CGSize(width: 0, height: -padding * 0.35),
                    blur: CGFloat(padding * 1.1),
                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
                )
            }

            let cgColor = CGColor(
                red: CGFloat(color.x), green: CGFloat(color.y),
                blue: CGFloat(color.z), alpha: CGFloat(color.w)
            )
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            // CGContext's origin is bottom-left; place the baseline `descent` up from it.
            context.textPosition = CGPoint(x: padding, y: padding + descent)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: pixelWidth, height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        buffer.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    // MARK: - Fonts

    /// Maps a category to a concrete face.
    ///
    /// The recipe stores a *category*, never a family, because identifying a typeface from a
    /// 1080p frame is not solvable. This is where that honest category becomes something
    /// drawable — and the mapping is a product decision, not a claim about the reference.
    static func font(for category: FontCategory, size: Double) -> CTFont {
        let size = CGFloat(size)

        func systemFont(traits: CTFontSymbolicTraits) -> CTFont {
            let base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
        }

        /// Named faces fall back to the system font if the name is unavailable, rather than to
        /// something arbitrary.
        func named(_ name: String, fallbackTraits: CTFontSymbolicTraits) -> CTFont {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let actualName = CTFontCopyPostScriptName(font) as String
            return actualName.contains(name.prefix(4)) ? font : systemFont(traits: fallbackTraits)
        }

        switch category {
        case .sansSerif:
            return systemFont(traits: .traitBold)
        case .displayBold:
            return systemFont(traits: .traitBold)
        case .condensed:
            return systemFont(traits: [.traitBold, .traitCondensed])
        case .serif:
            return named("Georgia-Bold", fallbackTraits: .traitBold)
        case .handwritten:
            return named("SnellRoundhand-Black", fallbackTraits: .traitItalic)
        case .monospace:
            return named("Menlo-Bold", fallbackTraits: [.traitBold, .traitMonoSpace])
        }
    }
}
