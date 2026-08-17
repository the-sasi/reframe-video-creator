import CoreVideo
import Foundation
import MediaIO
import RecipeCore
import Vision

/// Text extraction from the reference.
///
/// Two responsibilities that are easy to conflate and shouldn't be: finding out *where and how*
/// text appears (which becomes a reusable slot), and finding out *what it says* (which is a
/// hint the user can size their own copy against, and is never reproduced — see
/// docs/02-licensing.md).
///
/// It also actively discards creator watermarks and handles, so a reference's `@username` can
/// never end up in somebody else's video.
public struct TextAnalyzer: Sendable {

    /// One OCR hit at one moment.
    private struct Observation {
        var text: String
        var rect: NormalizedRect
        var confidence: Double
        var time: Double
    }

    /// A track under construction.
    private struct OpenTrack {
        var canonicalText: String
        var observations: [Observation]
        var lastSeen: Double
        var colorSamples: [ColorAnalyzer.RGB]
        var earlyWidths: [Double]
    }

    /// Observations further apart than this end a track. Generous enough to survive a frame
    /// where OCR blinks out, tight enough that the same caption reappearing later is a new slot.
    private let trackGapTolerance: Double = 0.6
    /// Below this, an observation is noise — motion-blurred background signage, mostly.
    private let minimumObservationConfidence: Double = 0.35
    /// Tracks with fewer observations than this are discarded.
    private let minimumObservationCount = 2

    private let colorAnalyzer = ColorAnalyzer()

    public init() {}

    public func analyze(
        source: MediaSource,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [DetectedTextTrack] {
        let stream = FrameStream(source: source, configuration: .textRecognition)
        let expected = stream.estimatedFrameCount

        var open: [OpenTrack] = []
        var closed: [OpenTrack] = []
        var processed = 0

        for try await frame in stream.frames() {
            let observations = recognizeText(in: frame.pixelBuffer, at: frame.time)
            processed += 1
            progress?(processed, expected)

            // Close tracks that have not been seen recently.
            var stillOpen: [OpenTrack] = []
            for track in open {
                if frame.time - track.lastSeen > trackGapTolerance {
                    closed.append(track)
                } else {
                    stillOpen.append(track)
                }
            }
            open = stillOpen

            for observation in observations {
                if let index = matchIndex(for: observation, in: open) {
                    open[index].observations.append(observation)
                    open[index].lastSeen = observation.time
                    // Longer readings are better readings — OCR mid-reveal returns fragments.
                    if observation.text.count > open[index].canonicalText.count {
                        open[index].canonicalText = observation.text
                    }
                    if open[index].observations.count <= 6 {
                        open[index].earlyWidths.append(observation.rect.width)
                    }
                } else {
                    var track = OpenTrack(
                        canonicalText: observation.text,
                        observations: [observation],
                        lastSeen: observation.time,
                        colorSamples: [],
                        earlyWidths: [observation.rect.width]
                    )
                    // Sample colour once, at first sighting, while we have the frame in hand.
                    track.colorSamples = sampleColors(
                        in: frame.pixelBuffer, region: observation.rect
                    )
                    open.append(track)
                }
            }
        }

        closed.append(contentsOf: open)
        return closed
            .filter { $0.observations.count >= minimumObservationCount }
            .map { finalize($0, sourceDuration: source.info.duration) }
            .sorted { $0.start < $1.start }
    }

    // MARK: - OCR

    private func recognizeText(in buffer: CVPixelBuffer, at time: Double) -> [Observation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Reels are stylised type, not prose. Language correction "fixes" a product name into
        // a dictionary word, which is exactly wrong when the point is to measure its length.
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return [] }

        return results.compactMap { result in
            guard let candidate = result.topCandidates(1).first,
                  Double(candidate.confidence) >= minimumObservationConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let box = result.boundingBox
            return Observation(
                text: text,
                rect: NormalizedRect.fromVision(
                    x: box.origin.x, y: box.origin.y,
                    width: box.size.width, height: box.size.height
                ),
                confidence: Double(candidate.confidence),
                time: time
            )
        }
    }

    /// Matches an observation to an open track by position *and* content.
    ///
    /// Position alone merges a title and the caption that replaces it in the same spot;
    /// content alone splits a track whenever OCR misreads one frame. Requiring both, with a
    /// generous similarity threshold, handles the word-by-word case where the string genuinely
    /// grows frame to frame.
    private func matchIndex(for observation: Observation, in tracks: [OpenTrack]) -> Int? {
        var bestIndex: Int?
        var bestScore = 0.0

        for (index, track) in tracks.enumerated() {
            guard let last = track.observations.last else { continue }
            let overlap = last.rect.iou(observation.rect)
            guard overlap > 0.35 else { continue }

            let similarity = Self.similarity(track.canonicalText, observation.text)
            let growing = observation.text.hasPrefix(track.canonicalText)
                || track.canonicalText.hasPrefix(observation.text)
            guard similarity > 0.55 || growing else { continue }

            let score = overlap * 0.5 + max(similarity, growing ? 0.8 : 0) * 0.5
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Token-level Jaccard similarity. Cheap, and adequate — we are distinguishing "is this the
    /// same caption" from "is this a different caption", not doing fuzzy search.
    static func similarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(separator: " ").map(String.init))
        let setB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !setA.isEmpty || !setB.isEmpty else { return 1 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    // MARK: - Colour

    /// Samples pixels inside the text's bounding box and splits them into two clusters.
    ///
    /// The text colour is the *smaller* cluster: within a tight box around a line of type, the
    /// glyphs cover fewer pixels than the background behind them. This is a heuristic and it is
    /// reported as such — outlined or shadowed text gives it trouble, and heavy display faces
    /// on a plain background can invert the assumption.
    private func sampleColors(in buffer: CVPixelBuffer, region: NormalizedRect) -> [ColorAnalyzer.RGB] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let x0 = max(0, Int(region.x * Double(width)))
        let y0 = max(0, Int(region.y * Double(height)))
        let x1 = min(width, Int((region.x + region.width) * Double(width)))
        let y1 = min(height, Int((region.y + region.height) * Double(height)))
        guard x1 > x0, y1 > y0 else { return [] }

        let src = base.assumingMemoryBound(to: UInt8.self)
        var samples: [ColorAnalyzer.RGB] = []
        let strideY = max(1, (y1 - y0) / 24)
        let strideX = max(1, (x1 - x0) / 48)

        for y in Swift.stride(from: y0, to: y1, by: strideY) {
            let row = src + y * bytesPerRow
            for x in Swift.stride(from: x0, to: x1, by: strideX) {
                let p = row + x * 4
                samples.append(
                    ColorAnalyzer.RGB(
                        r: Double(p[2]) / 255,
                        g: Double(p[1]) / 255,
                        b: Double(p[0]) / 255
                    )
                )
            }
        }
        return samples
    }

    private func textColor(from samples: [ColorAnalyzer.RGB]) -> String {
        guard samples.count >= 8 else { return "#FFFFFF" }
        let clusters = colorAnalyzer.dominantColors(from: samples, k: 2)
        guard clusters.count == 2 else { return clusters.first?.hexString ?? "#FFFFFF" }
        // `dominantColors` orders by population, so the second cluster is the minority — the
        // glyphs, under the assumption above.
        return clusters[1].hexString
    }

    // MARK: - Finalisation

    private func finalize(_ track: OpenTrack, sourceDuration: Double) -> DetectedTextTrack {
        let times = track.observations.map(\.time)
        let start = times.min() ?? 0
        let end = times.max() ?? start

        // Median rect: text can wobble frame to frame, and averaging lets one bad OCR box drag
        // the slot off-centre.
        let rect = medianRect(track.observations.map(\.rect))
        let meanConfidence = track.observations.map(\.confidence).reduce(0, +)
            / Double(track.observations.count)

        // Monotonic width growth during the first observations is the signature of a
        // word-by-word or type-on reveal.
        var growth = 0
        for i in 1..<max(1, track.earlyWidths.count)
        where track.earlyWidths[i] > track.earlyWidths[i - 1] * 1.08 {
            growth += 1
        }

        return DetectedTextTrack(
            text: track.canonicalText,
            start: start,
            end: min(sourceDuration, end + 0.1),  // OCR drops out slightly before text does
            frame: rect,
            meanConfidence: meanConfidence,
            sizeRatio: rect.height,
            colorHex: textColor(from: track.colorSamples),
            isLikelyWatermark: Self.isLikelyWatermark(
                text: track.canonicalText,
                rect: rect,
                coverage: (end - start) / max(sourceDuration, 0.001)
            ),
            observationCount: track.observations.count,
            entryExtentGrowth: growth
        )
    }

    private func medianRect(_ rects: [NormalizedRect]) -> NormalizedRect {
        guard !rects.isEmpty else { return .full }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return NormalizedRect(
            x: median(rects.map(\.x)),
            y: median(rects.map(\.y)),
            width: median(rects.map(\.width)),
            height: median(rects.map(\.height))
        )
    }

    // MARK: - Watermark rejection

    private static let watermarkPhrases = [
        "follow", "subscribe", "link in bio", "swipe up", "dm me",
        "tap here", "click link", "shop now at", "made with", "created with",
    ]

    /// Structural enforcement of §39: creator identity never reaches the output.
    ///
    /// Three independent signals, any of which is enough:
    /// - an `@handle`, which is an identity marker and nothing else;
    /// - platform-UI and growth-hack phrases;
    /// - small text, parked in a corner, present for most of the video — the shape of a
    ///   watermark regardless of what it says.
    static func isLikelyWatermark(text: String, rect: NormalizedRect, coverage: Double) -> Bool {
        let lowered = text.lowercased()

        if lowered.hasPrefix("@") { return true }
        if lowered.range(of: #"(^|\s)@[a-z0-9._]{2,}"#, options: .regularExpression) != nil {
            return true
        }
        if watermarkPhrases.contains(where: { lowered.contains($0) }) { return true }

        let isSmall = rect.height < 0.035
        let inCorner = (rect.centerY < 0.14 || rect.centerY > 0.88)
            && (rect.centerX < 0.30 || rect.centerX > 0.70)
        let persistent = coverage > 0.75
        return isSmall && inCorner && persistent
    }
}
