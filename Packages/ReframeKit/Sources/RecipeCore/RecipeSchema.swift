import Foundation

/// Document versioning. Every persisted root object carries `schemaVersion`.
public enum RecipeSchema {
    public static let current = 1

    /// Shared encoder. Sorted keys and pretty printing are not cosmetic — they are what make
    /// recipe JSON diffable, which is how determinism regressions get caught.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Peeks at `schemaVersion` without decoding the whole document, so we can refuse a
    /// future version cleanly instead of failing with a confusing key-not-found error.
    public static func peekVersion(_ data: Data) throws -> Int {
        struct VersionProbe: Decodable { let schemaVersion: Int }
        return try decoder.decode(VersionProbe.self, from: data).schemaVersion
    }

    public static func decodeRecipe(_ data: Data) throws -> EditRecipe {
        let version = try peekVersion(data)
        guard version <= current else {
            throw ReframeError.documentTooNew(found: version, supported: current)
        }
        // v1 is the first version; when v2 lands, migrate here before decoding.
        return try decoder.decode(EditRecipe.self, from: data)
    }

    public static func decodeTimeline(_ data: Data) throws -> Timeline {
        let version = try peekVersion(data)
        guard version <= current else {
            throw ReframeError.documentTooNew(found: version, supported: current)
        }
        return try decoder.decode(Timeline.self, from: data)
    }
}

/// Deterministic identifier generation.
///
/// `RecipeCompiler` must produce byte-identical JSON for the same input, which rules out
/// `UUID()`. Ids are derived from the source fingerprint plus a stable path, so the same
/// reference always yields the same scene ids — and a diff of two recipe files shows only what
/// actually changed in the analysis.
public struct DeterministicID: Sendable {
    private let seed: String

    public init(seed: String) {
        self.seed = seed
    }

    /// A stable string id, e.g. `scene_03`. Human-readable on purpose: these appear in JSON
    /// that people read.
    public func string(_ prefix: String, _ index: Int) -> String {
        String(format: "%@_%02d", prefix, index)
    }

    /// A stable UUID derived from the seed and a path. Uses FNV-1a over the combined string,
    /// expanded to 16 bytes. Not cryptographic — it only needs to be collision-free within one
    /// document and reproducible across runs.
    public func uuid(_ path: String) -> UUID {
        var bytes = [UInt8]()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array((seed + "/" + path).utf8) {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        // Two rounds with different constants fill 16 bytes without repeating the pattern.
        var g: UInt64 = h ^ 0x9E37_79B9_7F4A_7C15
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: h))
            h >>= 8
        }
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: g))
            g >>= 8
        }
        // Stamp RFC 4122 version 4 / variant bits so this is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
