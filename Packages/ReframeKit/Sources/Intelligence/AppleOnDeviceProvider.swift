import Foundation
import RecipeCore

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model, used strictly as a garnish.
///
/// Free, offline, no API key, no cloud — and unavailable on most devices, since Apple
/// Intelligence is per-device rather than per-OS. Every method here falls back to
/// `HeuristicProvider` rather than propagating a failure, because "the model is not there" is
/// the ordinary case.
///
/// The context window is a fixed 4,096 tokens per session, covering prompt *and* response, and
/// exceeding it throws `exceededContextWindowSize` and poisons the session. So this uses one
/// short-lived session per request rather than accumulating one across a whole recipe.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleOnDeviceProvider: IntelligenceProvider {

    public let identifier = "apple-on-device"
    public let displayName = "Apple Intelligence (on device)"

    private let fallback = HeuristicProvider()

    public init() {}

    public var isAvailable: Bool {
        get async {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default: return false
            }
        }
    }

    // MARK: - Slot description

    @Generable
    struct SlotDescription {
        @Guide(description: "A short noun phrase describing what belongs in this shot, at most 5 words. No punctuation at the end.")
        var phrase: String
    }

    public func describeSlot(_ context: SlotContext) async -> Confident<String> {
        let prompt = """
        Shot \(context.index + 1) of \(context.total) in a short vertical video.
        Framing: \(context.framing.displayName). Duration: \(String(format: "%.1f", context.duration))s.
        Camera: \(context.move.displayName). Narrative role: \(context.role.displayName).
        Describe what kind of photo belongs here.
        """

        do {
            let session = LanguageModelSession(
                instructions: "You name video shot types concisely for a photo-picking UI. Answer with a short noun phrase only."
            )
            let response = try await session.respond(to: prompt, generating: SlotDescription.self)
            let phrase = response.content.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, phrase.count < 60 else {
                return await fallback.describeSlot(context)
            }
            return Confident(phrase, confidence: 0.7, basis: "Apple on-device model")
        } catch {
            return await fallback.describeSlot(context)
        }
    }

    // MARK: - Copy

    @Generable
    struct CopyOptions {
        @Guide(description: "Between 3 and 4 alternative phrasings, each shorter than the target length.")
        var options: [String]
    }

    public func suggestCopy(_ context: CopyContext) async -> [String] {
        let prompt = """
        Product: \(context.productName)
        Description: \(context.description)
        Write \(context.role == .cta ? "call-to-action" : context.role.displayName.lowercased()) text \
        for a vertical video overlay, about \(max(8, context.targetCharacterCount)) characters each.
        """

        do {
            let session = LanguageModelSession(
                instructions: "You write short, plain marketing overlays for social video. No hashtags, no emoji, no quotation marks."
            )
            let response = try await session.respond(to: prompt, generating: CopyOptions.self)
            let options = response.content.options
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 60 }
            // An empty or degenerate result is a fallback, not a failure.
            return options.isEmpty ? await fallback.suggestCopy(context) : options
        } catch {
            return await fallback.suggestCopy(context)
        }
    }

    // MARK: - Roles

    /// Deliberately not implemented against the model.
    ///
    /// Scene roles drive asset assignment, and assignment must be deterministic — running Auto
    /// Arrange twice on the same inputs has to give the same answer. A sampled model would make
    /// that untrue for a marginal gain over rules that already work.
    public func refineSceneRoles(_ context: RoleContext) async -> [SceneRole]? {
        nil
    }
}

#endif
