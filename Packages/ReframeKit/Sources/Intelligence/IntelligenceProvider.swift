import Foundation
import RecipeCore

/// Optional intelligence. The app is fully functional with none of it.
///
/// Everything structural — cuts, camera moves, shot scale, beat grids, asset assignment — is
/// decided by deterministic algorithms, because those questions are geometric and temporal
/// rather than semantic. What is left is *naming and phrasing*, which is genuinely where a
/// language model helps and is exactly why this protocol exists and why it is optional.
///
/// Every method has a total fallback. A missing, disabled, throttled or context-exhausted model
/// is the normal path on most devices, not an error path.
public protocol IntelligenceProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get async }

    /// A human phrase for a slot: "detail shot of petals" rather than "scene 4, tight framing".
    func describeSlot(_ context: SlotContext) async -> Confident<String>

    /// Alternative phrasings for a call to action. Never applied automatically.
    func suggestCopy(_ context: CopyContext) async -> [String]

    /// Improves the heuristic role assignment. Returns nil for "keep what the heuristics
    /// decided" — the common case.
    func refineSceneRoles(_ context: RoleContext) async -> [SceneRole]?
}

public struct SlotContext: Sendable, Hashable {
    public var index: Int
    public var total: Int
    public var role: SceneRole
    public var framing: ShotFraming
    public var duration: Double
    public var move: CameraMoveKind

    public init(
        index: Int, total: Int, role: SceneRole,
        framing: ShotFraming, duration: Double, move: CameraMoveKind
    ) {
        self.index = index
        self.total = total
        self.role = role
        self.framing = framing
        self.duration = duration
        self.move = move
    }
}

public struct CopyContext: Sendable, Hashable {
    public var productName: String
    public var description: String
    public var role: TextRole
    /// How long the reference's text was, so suggestions fit the layout.
    public var targetCharacterCount: Int

    public init(productName: String, description: String, role: TextRole, targetCharacterCount: Int) {
        self.productName = productName
        self.description = description
        self.role = role
        self.targetCharacterCount = targetCharacterCount
    }
}

public struct RoleContext: Sendable, Hashable {
    public var durations: [Double]
    public var framings: [ShotFraming]
    public var currentRoles: [SceneRole]

    public init(durations: [Double], framings: [ShotFraming], currentRoles: [SceneRole]) {
        self.durations = durations
        self.framings = framings
        self.currentRoles = currentRoles
    }
}

// MARK: - Heuristic (always available)

/// The baseline. Deterministic, instant, offline, present on every device.
///
/// This is what the app actually uses almost all of the time, and it is good enough that the
/// on-device model is a garnish rather than a dependency.
public struct HeuristicProvider: IntelligenceProvider {
    public let identifier = "heuristic"
    public let displayName = "On this iPhone (built in)"
    public var isAvailable: Bool { get async { true } }

    public init() {}

    public func describeSlot(_ context: SlotContext) async -> Confident<String> {
        let position: String
        switch context.role {
        case .opening: position = "Opening"
        case .closing: position = "Final"
        case .hero: position = "Hero"
        case .detail: position = "Detail"
        case .wide: position = "Establishing"
        case .body: position = "Scene \(context.index + 1)"
        }

        var phrase = "\(position) · \(context.framing.displayName.lowercased())"
        if context.move != .none {
            phrase += " · \(context.move.displayName.lowercased())"
        }
        phrase += String(format: " · %.1fs", context.duration)

        return Confident(phrase, confidence: 1.0, basis: "templated from slot properties")
    }

    public func suggestCopy(_ context: CopyContext) async -> [String] {
        // Deliberately templated, not clever. These are starting points a person edits, and
        // pretending otherwise would be worse than being obviously a template.
        let name = context.productName.isEmpty ? "this" : context.productName
        switch context.role {
        case .cta:
            return ["DM TO ORDER", "ORDER NOW", "TAP TO SHOP", "AVAILABLE NOW"]
        case .title:
            return [name.uppercased(), name]
        case .subtitle:
            return context.description.isEmpty ? [] : [context.description]
        case .caption, .watermark:
            return []
        }
    }

    public func refineSceneRoles(_ context: RoleContext) async -> [SceneRole]? {
        nil  // The heuristics upstream already did this; there is nothing to add.
    }
}

// MARK: - Resolution

/// Picks the best available provider, falling back to heuristics.
///
/// Resolution order is Apple on-device -> heuristic. There is no cloud provider, and adding one
/// would require explicit per-use consent, a named model, a statement of exactly what bytes are
/// sent, and a global off switch defaulting to off — see docs/08-quality.md.
public actor IntelligenceService {

    private var resolved: (any IntelligenceProvider)?
    private let heuristic = HeuristicProvider()
    /// User-facing switch. Off means heuristics only, always.
    public private(set) var isEnhancementEnabled: Bool

    public init(isEnhancementEnabled: Bool = true) {
        self.isEnhancementEnabled = isEnhancementEnabled
    }

    public func setEnhancementEnabled(_ enabled: Bool) {
        isEnhancementEnabled = enabled
        resolved = nil
    }

    public func provider() async -> any IntelligenceProvider {
        if let resolved { return resolved }

        guard isEnhancementEnabled else {
            resolved = heuristic
            return heuristic
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let apple = AppleOnDeviceProvider()
            if await apple.isAvailable {
                resolved = apple
                return apple
            }
        }
        #endif

        resolved = heuristic
        return heuristic
    }

    /// For the Settings screen: says which provider is actually in use, and never implies a
    /// capability the device does not have.
    public func statusDescription() async -> String {
        let provider = await self.provider()
        return provider.displayName
    }
}
