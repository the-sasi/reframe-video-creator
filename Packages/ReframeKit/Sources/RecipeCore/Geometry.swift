import Foundation

/// A rectangle in normalised `0...1` coordinates, origin top-left.
///
/// Recipes store geometry this way so a 9:16 recipe stays valid when bound to a 1:1 or 16:9
/// canvas — re-targeting becomes crop re-solving rather than a schema migration.
public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var area: Double { width * height }
    public var aspectRatio: Double { height > 0 ? width / height : 1 }

    /// Uniform scale about the rect's own centre. `factor > 1` zooms *out* (shows more),
    /// `factor < 1` zooms *in* (shows less) — this is a source-crop rect, so a smaller rect
    /// means a tighter shot.
    public func scaled(by factor: Double) -> NormalizedRect {
        let w = width * factor
        let h = height * factor
        return NormalizedRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
    }

    public func offset(dx: Double, dy: Double) -> NormalizedRect {
        NormalizedRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Pulls the rect back inside `0...1` without changing its size, so a pan that would run
    /// off the edge slides along it instead of revealing emptiness.
    public func clampedInsideUnitSquare() -> NormalizedRect {
        var r = self
        r.width = min(r.width, 1)
        r.height = min(r.height, 1)
        r.x = min(max(r.x, 0), 1 - r.width)
        r.y = min(max(r.y, 0), 1 - r.height)
        return r
    }

    public func interpolated(to other: NormalizedRect, t: Double) -> NormalizedRect {
        NormalizedRect(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }

    /// Intersection-over-union. Used to group OCR observations across frames into text tracks.
    public func iou(_ other: NormalizedRect) -> Double {
        let ix = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let iy = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let intersection = ix * iy
        let union = area + other.area - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Smallest rect containing both. Used to merge salient regions into one subject box.
    public func union(_ other: NormalizedRect) -> NormalizedRect {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Vision reports rects with origin bottom-left; the rest of the app is top-left.
    /// Conversion happens exactly once, here, at the boundary.
    public static func fromVision(x: Double, y: Double, width: Double, height: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: 1 - y - height, width: width, height: height)
    }
}

/// Easing applied to camera moves and text animation. Deliberately a small closed set —
/// the analyser cannot honestly distinguish more than this from a 1080p frame.
public enum Easing: String, Codable, Sendable, Hashable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return t * (2 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
        }
    }
}

/// Canvas dimensions and frame rate. Separate from `SourceInfo` because the output canvas is
/// a user choice, not a property of the reference.
public struct CanvasSpec: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    public static let reel1080 = CanvasSpec(width: 1080, height: 1920, fps: 30)
    public static let reel720 = CanvasSpec(width: 720, height: 1280, fps: 30)
    public static let square1080 = CanvasSpec(width: 1080, height: 1080, fps: 30)

    public var aspectRatio: Double { Double(width) / Double(height) }
    public var frameDuration: Double { 1.0 / Double(fps) }

    /// Snaps a time to the nearest frame boundary. Applied at every timeline edit so clip
    /// boundaries can never land between frames and produce a duplicated or dropped frame.
    public func snapToFrame(_ time: Double) -> Double {
        (time * Double(fps)).rounded() / Double(fps)
    }
}

public enum AspectPreset: String, Codable, Sendable, Hashable, CaseIterable {
    case portrait9x16
    case square1x1
    case landscape16x9
    case portrait4x5
    case other

    public init(width: Int, height: Int) {
        guard height > 0 else { self = .other; return }
        let ratio = Double(width) / Double(height)
        switch ratio {
        case ..<0.60: self = .portrait9x16
        case 0.60..<0.90: self = .portrait4x5
        case 0.90..<1.15: self = .square1x1
        case 1.15..<2.10: self = .landscape16x9
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .portrait9x16: return "9:16"
        case .square1x1: return "1:1"
        case .landscape16x9: return "16:9"
        case .portrait4x5: return "4:5"
        case .other: return "Custom"
        }
    }
}
