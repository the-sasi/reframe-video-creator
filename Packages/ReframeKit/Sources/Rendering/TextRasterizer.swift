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
        /// Where this piece sits on the canvas, normalised, before animation offsets.
        public let rect: NormalizedRect
        /// Index into `TextDraw.words` for word pieces; the line index for background pieces.
        public let index: Int
    }
    /// One per drawable word, in word order. Line-break markers produce no piece, so this is
    /// indexed by `Piece.index` rather than by position.
    public let words: [Piece]
    /// One rounded box per line, drawn *behind* the words. Empty unless the style has one.
    public let backgrounds: [Piece]
    /// Which line each word landed on, keyed by word index. Lets the renderer fade a line's
    /// background with the words on it.
    public let lineOfWord: [Int: Int]
    /// Centre of the whole block on the canvas, normalised — the rotation pivot.
    public let blockCenter: SIMD2<Double>
}

/// Core Text -> `CGContext` -> `MTLTexture`, cached by `(words, style, canvas)`.
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
        let words = draw.words.map { $0.isLineBreak ? "\u{2028}" : $0.text }.joined(separator: "\u{1F}")
        let s = draw.style
        return [
            words,
            s.fontCategory.rawValue, s.fontName ?? "-", s.weight.rawValue, s.isItalic ? "i" : "r",
            String(format: "%.4f|%.3f|%.3f", s.sizeRatio, s.letterSpacing, s.lineSpacing),
            String(format: "%.3f,%.3f,%.3f,%.3f", s.color.x, s.color.y, s.color.z, s.color.w),
            s.hasShadow ? "s1" : "s0",
            s.outline.map { "o:\($0.colorHex):\($0.widthEm)" } ?? "o-",
            s.background.map { "b:\($0.colorHex):\($0.opacity):\($0.paddingEm):\($0.cornerRadiusEm)" } ?? "b-",
            s.alignment.rawValue,
            String(format: "%.3f,%.3f,%.3f,%.3f", draw.frame.x, draw.frame.y, draw.frame.width, draw.frame.height),
            "\(canvas.width)x\(canvas.height)",
        ].joined(separator: "|")
    }

    // MARK: - Layout & rasterisation

    private func build(_ draw: TextDraw, canvas: CanvasSpec) -> RasterizedText? {
        let style = draw.style
        let pointSize = style.sizeRatio * Double(canvas.height)
        guard pointSize >= 4 else { return nil }

        let font = Self.font(for: style, size: pointSize)
        let frame = style.frame(draw.frame, canvas: canvas)
        let frameWidthPixels = Double(frame.width)
        let kern = style.letterSpacing * pointSize

        // Measure every word, then wrap greedily. Greedy wrapping is what people expect from a
        // caption; Core Text's paragraph layout would be better typography and worse at telling
        // us where each individual word landed, which is what word-by-word reveal needs.
        struct Measured {
            let index: Int
            let text: String
            let width: Double
            let ascent: Double
            let descent: Double
        }

        let spaceWidth = Self.measure(" ", font: font, kern: kern).width

        var measured: [Measured] = []
        var lines: [[Int]] = []          // indices into `measured`
        var currentLine: [Int] = []
        var currentWidth = 0.0

        for (wordIndex, word) in draw.words.enumerated() {
            if word.isLineBreak {
                if !currentLine.isEmpty { lines.append(currentLine) }
                currentLine = []
                currentWidth = 0
                continue
            }
            let m = Self.measure(word.text, font: font, kern: kern)
            let entry = Measured(index: wordIndex, text: word.text, width: m.width, ascent: m.ascent, descent: m.descent)
            let slot = measured.count
            measured.append(entry)

            let additional = currentLine.isEmpty ? entry.width : spaceWidth + entry.width
            if !currentLine.isEmpty, currentWidth + additional > frameWidthPixels {
                lines.append(currentLine)
                currentLine = [slot]
                currentWidth = entry.width
            } else {
                currentLine.append(slot)
                currentWidth += additional
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        guard !lines.isEmpty, !measured.isEmpty else { return nil }

        let ascent = measured.map(\.ascent).max() ?? pointSize
        let descent = measured.map(\.descent).max() ?? 0
        let lineHeight = ascent + descent
        let lineAdvance = lineHeight * max(0.8, style.lineSpacing)
        let totalHeight = lineAdvance * Double(lines.count - 1) + lineHeight

        // Vertically centre the block in its frame. The recipe's frame is where the reference's
        // text *was*; centring within it survives the user's copy being a different length.
        let frameCenterY = Double(frame.midY)
        var cursorY = frameCenterY - totalHeight / 2

        let padding = style.hasShadow ? Self.shadowPadding(for: pointSize) : 0
        let outlinePad = style.outline.map { $0.widthEm * pointSize } ?? 0
        let texturePad = padding + outlinePad

        var wordPieces: [RasterizedText.Piece] = []
        var backgroundPieces: [RasterizedText.Piece] = []
        var lineOfWord: [Int: Int] = [:]
        wordPieces.reserveCapacity(measured.count)

        var minX = Double.infinity, maxX = -Double.infinity

        for (lineIndex, line) in lines.enumerated() {
            let lineWidth = line.enumerated().reduce(0.0) { partial, element in
                partial + measured[element.element].width + (element.offset > 0 ? spaceWidth : 0)
            }

            var cursorX: Double
            switch style.alignment {
            case .leading: cursorX = Double(frame.minX)
            case .trailing: cursorX = Double(frame.maxX) - lineWidth
            case .center: cursorX = Double(frame.midX) - lineWidth / 2
            }
            let lineStartX = cursorX
            minX = min(minX, lineStartX)
            maxX = max(maxX, lineStartX + lineWidth)

            // Background pill for this line, sized to the line's actual extent.
            if let bg = style.background, lineWidth > 0 {
                let pad = bg.paddingEm * pointSize
                let boxWidth = lineWidth + pad * 2
                let boxHeight = lineHeight + pad * 1.2
                if let texture = rasterizeBox(
                    width: boxWidth, height: boxHeight,
                    cornerRadius: bg.cornerRadiusEm * pointSize,
                    color: .fromHex(bg.colorHex), opacity: bg.opacity
                ) {
                    backgroundPieces.append(
                        RasterizedText.Piece(
                            texture: texture,
                            rect: NormalizedRect(
                                x: (lineStartX - pad) / Double(canvas.width),
                                y: (cursorY - pad * 0.6) / Double(canvas.height),
                                width: boxWidth / Double(canvas.width),
                                height: boxHeight / Double(canvas.height)
                            ),
                            index: lineIndex
                        )
                    )
                }
            }

            for (offset, slot) in line.enumerated() {
                let word = measured[slot]
                if offset > 0 { cursorX += spaceWidth }
                lineOfWord[word.index] = lineIndex

                guard let texture = rasterizeWord(
                    word.text, font: font, style: style, kern: kern,
                    width: word.width, ascent: ascent, descent: descent, pad: texturePad
                ) else {
                    cursorX += word.width
                    continue
                }

                // The texture is padded for the shadow/outline, so its rect is wider than the glyphs.
                let rect = NormalizedRect(
                    x: (cursorX - texturePad) / Double(canvas.width),
                    y: (cursorY - texturePad) / Double(canvas.height),
                    width: (word.width + texturePad * 2) / Double(canvas.width),
                    height: (lineHeight + texturePad * 2) / Double(canvas.height)
                )
                wordPieces.append(RasterizedText.Piece(texture: texture, rect: rect, index: word.index))
                cursorX += word.width
            }
            cursorY += lineAdvance
        }

        guard !wordPieces.isEmpty else { return nil }
        let blockCenter = SIMD2<Double>(
            ((minX + maxX) / 2) / Double(canvas.width),
            frameCenterY / Double(canvas.height)
        )
        return RasterizedText(
            words: wordPieces, backgrounds: backgroundPieces,
            lineOfWord: lineOfWord, blockCenter: blockCenter
        )
    }

    private static func shadowPadding(for pointSize: Double) -> Double {
        max(2, pointSize * 0.09)
    }

    private static func measure(_ text: String, font: CTFont, kern: Double) -> (width: Double, ascent: Double, descent: Double) {
        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
        ]
        if abs(kern) > 0.01 {
            attributes[kCTKernAttributeName as NSAttributedString.Key] = NSNumber(value: kern)
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        // Kerning after the last glyph is not part of the visual width.
        return (max(0, Double(width) - (abs(kern) > 0.01 ? kern : 0)), Double(ascent), Double(descent))
    }

    private func rasterizeWord(
        _ text: String, font: CTFont, style: TextDraw.Style, kern: Double,
        width: Double, ascent: Double, descent: Double, pad: Double
    ) -> MTLTexture? {
        let pointSize = Double(CTFontGetSize(font))
        let pixelWidth = Int(ceil(width + pad * 2))
        let pixelHeight = Int(ceil(ascent + descent + pad * 2))
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

            let cgColor = CGColor(
                red: CGFloat(style.color.x), green: CGFloat(style.color.y),
                blue: CGFloat(style.color.z), alpha: CGFloat(style.color.w)
            )
            var attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor,
            ]
            if abs(kern) > 0.01 {
                attributes[kCTKernAttributeName as NSAttributedString.Key] = NSNumber(value: kern)
            }
            // CGContext's origin is bottom-left; place the baseline `descent` up from it.
            let baseline = CGPoint(x: pad, y: pad + descent)

            // Outline first, as a stroked pass underneath the fill, so the fill's colour is
            // never contaminated by the stroke's at the glyph edge.
            if let outline = style.outline, outline.widthEm > 0 {
                let strokeColor = SIMD4<Float>.fromHex(outline.colorHex)
                var strokeAttributes = attributes
                strokeAttributes[kCTForegroundColorAttributeName as NSAttributedString.Key] = CGColor(
                    red: CGFloat(strokeColor.x), green: CGFloat(strokeColor.y),
                    blue: CGFloat(strokeColor.z), alpha: CGFloat(strokeColor.w)
                )
                strokeAttributes[kCTStrokeColorAttributeName as NSAttributedString.Key] = CGColor(
                    red: CGFloat(strokeColor.x), green: CGFloat(strokeColor.y),
                    blue: CGFloat(strokeColor.z), alpha: CGFloat(strokeColor.w)
                )
                // Positive stroke width = stroke only, in percent of point size. Doubled
                // because half the stroke lies inside the glyph, under the fill.
                strokeAttributes[kCTStrokeWidthAttributeName as NSAttributedString.Key] =
                    NSNumber(value: outline.widthEm * 200)
                context.saveGState()
                if style.hasShadow {
                    context.setShadow(
                        offset: CGSize(width: 0, height: -pad * 0.3),
                        blur: CGFloat(pointSize * 0.09),
                        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
                    )
                }
                context.setLineJoin(.round)
                context.textPosition = baseline
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: strokeAttributes)), context)
                context.restoreGState()
            } else if style.hasShadow {
                // Soft drop shadow. Reels are watched over unpredictable footage, and a shadow
                // is the difference between readable and not — which is why the binder defaults
                // it on when the analyser could not tell.
                context.setShadow(
                    offset: CGSize(width: 0, height: -pad * 0.35),
                    blur: CGFloat(pointSize * 0.09),
                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
                )
            }

            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = baseline
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }

        return makeTexture(from: buffer, width: pixelWidth, height: pixelHeight)
    }

    /// A rounded, filled box — the caption pill.
    private func rasterizeBox(
        width: Double, height: Double, cornerRadius: Double, color: SIMD4<Float>, opacity: Double
    ) -> MTLTexture? {
        let pixelWidth = Int(ceil(width))
        let pixelHeight = Int(ceil(height))
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 4096, pixelHeight < 4096 else { return nil }

        let bytesPerRow = pixelWidth * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setShouldAntialias(true)
            let radius = min(cornerRadius, Double(min(pixelWidth, pixelHeight)) / 2)
            let path = CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            context.addPath(path)
            context.setFillColor(
                CGColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(opacity))
            )
            context.fillPath()
            return true
        }
        guard drawn else { return nil }
        return makeTexture(from: buffer, width: pixelWidth, height: pixelHeight)
    }

    private func makeTexture(from buffer: [UInt8], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        buffer.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    // MARK: - Fonts

    /// Resolves the style to a concrete face.
    ///
    /// The recipe stores a *category*, never a family, because identifying a typeface from a
    /// 1080p frame is not solvable. This is where that honest category becomes something
    /// drawable — unless the user chose a face themselves, in which case that wins.
    static func font(for style: TextDraw.Style, size: Double) -> CTFont {
        let size = CGFloat(size)
        var traits: CTFontSymbolicTraits = []
        if style.isItalic { traits.insert(.traitItalic) }

        let weightValue: CGFloat = {
            switch style.weight {
            case .light: return -0.4
            case .regular: return 0
            case .medium: return 0.23
            case .semibold: return 0.3
            case .bold: return 0.4
            case .heavy: return 0.56
            case .black: return 0.62
            }
        }()

        func descriptor(family: String?, extraTraits: CTFontSymbolicTraits = []) -> CTFontDescriptor {
            var attributes: [CFString: Any] = [
                kCTFontTraitsAttribute: [
                    kCTFontWeightTrait: weightValue,
                    kCTFontSymbolicTrait: NSNumber(value: (traits.union(extraTraits)).rawValue),
                ] as [CFString: Any],
            ]
            if let family { attributes[kCTFontFamilyNameAttribute] = family }
            return CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        }

        func systemFont(extraTraits: CTFontSymbolicTraits = []) -> CTFont {
            let base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let want = traits.union(extraTraits)
            let weighted = CTFontCreateCopyWithAttributes(base, size, nil, descriptor(family: nil, extraTraits: extraTraits))
            return CTFontCreateCopyWithSymbolicTraits(weighted, size, nil, want, want) ?? weighted
        }

        // A named family the user chose. Verify Core Text actually resolved it rather than
        // silently substituting Helvetica for a typo.
        if let family = style.fontName, !family.isEmpty {
            let font = CTFontCreateWithFontDescriptor(descriptor(family: family), size, nil)
            let resolvedFamily = CTFontCopyFamilyName(font) as String
            if resolvedFamily.lowercased().hasPrefix(family.lowercased().prefix(5)) || family.hasPrefix(".") {
                return font
            }
        }

        switch style.fontCategory {
        case .sansSerif, .displayBold:
            return systemFont()
        case .condensed:
            return systemFont(extraTraits: .traitCondensed)
        case .serif:
            return CTFontCreateWithFontDescriptor(descriptor(family: "Georgia"), size, nil)
        case .handwritten:
            return CTFontCreateWithFontDescriptor(descriptor(family: "Snell Roundhand"), size, nil)
        case .monospace:
            return CTFontCreateWithFontDescriptor(descriptor(family: "Menlo"), size, nil)
        }
    }
}

private extension TextDraw.Style {
    /// The layer frame in canvas pixels.
    func frame(_ frame: NormalizedRect, canvas: CanvasSpec) -> CGRect {
        CGRect(
            x: frame.x * Double(canvas.width), y: frame.y * Double(canvas.height),
            width: frame.width * Double(canvas.width), height: frame.height * Double(canvas.height)
        )
    }
}
