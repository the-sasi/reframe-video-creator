import Foundation
import RecipeCore

/// Decides which photo fills which slot.
///
/// Three stages, in increasing subtlety:
///
/// 1. **Score** every (slot, asset) pair into a cost matrix.
/// 2. **Solve** the assignment optimally with `HungarianSolver` — globally best, not greedy.
/// 3. **Refine** with pairwise swaps against an adjacency-diversity penalty, which the
///    assignment problem structurally cannot express (the cost of putting a photo in slot 3
///    depends on what ended up in slot 2, and linear assignment has no way to say that).
///
/// Every stage is deterministic. Running Auto Arrange twice on the same inputs gives the same
/// answer, which matters because the alternative — a shuffle that changes under you — is
/// indistinguishable from a bug.
public struct AssetMapper: Sendable {

    public struct Weights: Sendable {
        public var framingMismatch: Double
        public var aesthetics: Double
        public var utilityPenalty: Double
        public var aspectMismatch: Double
        public var sourceKindMismatch: Double
        public var insufficientDuration: Double
        public var reusePenalty: Double
        /// Cost added when adjacent slots hold visually near-identical assets.
        public var adjacentSimilarity: Double
        /// Feature-print distance below which two assets are "near-duplicates".
        public var duplicateDistanceThreshold: Double
        /// Penalty for soft focus, scaled by (1 - sharpness).
        public var softness: Double
        /// Gentle preference for keeping the user's photos in the order they were taken. A
        /// tie-breaker, not a rule — a travel sequence stays chronological unless something
        /// clearly fits a slot better out of order.
        public var chronology: Double
        /// Mild preference for an asset whose subject sits where the reference's did. The
        /// binder re-anchors the crop around the subject anyway, so this only nudges.
        public var subjectPosition: Double

        public init(
            framingMismatch: Double = 1.0,
            aesthetics: Double = 0.8,
            utilityPenalty: Double = 3.0,
            aspectMismatch: Double = 0.5,
            sourceKindMismatch: Double = 0.35,
            insufficientDuration: Double = 1.2,
            reusePenalty: Double = 2.5,
            adjacentSimilarity: Double = 1.5,
            duplicateDistanceThreshold: Double = 0.55,
            softness: Double = 0.45,
            chronology: Double = 0.3,
            subjectPosition: Double = 0.2
        ) {
            self.framingMismatch = framingMismatch
            self.aesthetics = aesthetics
            self.utilityPenalty = utilityPenalty
            self.aspectMismatch = aspectMismatch
            self.sourceKindMismatch = sourceKindMismatch
            self.insufficientDuration = insufficientDuration
            self.reusePenalty = reusePenalty
            self.adjacentSimilarity = adjacentSimilarity
            self.duplicateDistanceThreshold = duplicateDistanceThreshold
            self.softness = softness
            self.chronology = chronology
            self.subjectPosition = subjectPosition
        }

        public static let `default` = Weights()
    }

    private let weights: Weights
    private let solver = HungarianSolver()

    public init(weights: Weights = .default) {
        self.weights = weights
    }

    // MARK: - Entry point

    public func map(
        recipe: EditRecipe,
        assets: AssetPool,
        features: [UUID: AssetFeatures],
        /// Varies the diversity refinement without changing the cost model, so "Shuffle" gives
        /// a genuinely different-but-still-good arrangement rather than a random one.
        shuffleSeed: Int = 0,
        /// Slots the user has pinned, with their current asset. Left untouched; the solver
        /// works around them.
        locked: AssetAssignment = AssetAssignment()
    ) -> AssetAssignment {
        let allSlots = recipe.scenes
        let candidates = assets.visuals
        guard !allSlots.isEmpty, !candidates.isEmpty else { return AssetAssignment() }

        // Pinned slots keep exactly what they have. Everything below solves the remainder.
        var result = AssetAssignment()
        var lockedAssetUse: [UUID: Int] = [:]
        for scene in allSlots where locked.isLocked(scene.slot.id) {
            if let assetID = locked[scene.slot.id], assets[assetID] != nil {
                result.assetBySlot[scene.slot.id] = assetID
                result.reasonBySlot[scene.slot.id] = "pinned by you"
                result.lockedSlots.insert(scene.slot.id)
                lockedAssetUse[assetID, default: 0] += 1
            }
        }
        let slots = allSlots.filter { !result.isLocked($0.slot.id) }
        guard !slots.isEmpty else { return result }

        // Chronological rank of each asset, for the ordering tie-breaker.
        let chronological = candidates
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.creationDate, rhs.element.creationDate) {
                case let (a?, b?) where a != b: return a < b
                default: return lhs.offset < rhs.offset
                }
            }
            .map { $0.element.id }
        var chronoRank: [UUID: Double] = [:]
        for (index, id) in chronological.enumerated() {
            chronoRank[id] = candidates.count > 1 ? Double(index) / Double(candidates.count - 1) : 0.5
        }

        // When there are fewer assets than slots, repeat the asset list. Each repetition costs
        // `reusePenalty` more, so the solver exhausts fresh photos before reusing any, and
        // reuses the *best* ones when it must. Assets already pinned elsewhere start one
        // repetition in — they have been used once.
        let repeats = max(1, Int(ceil(Double(slots.count) / Double(candidates.count))) + (lockedAssetUse.isEmpty ? 0 : 1))
        var columnAsset: [AssetReference] = []
        var columnRepeat: [Int] = []
        for r in 0..<repeats {
            for asset in candidates {
                columnAsset.append(asset)
                columnRepeat.append(r + (lockedAssetUse[asset.id] ?? 0))
            }
        }

        var cost = [[Double]](
            repeating: [Double](repeating: 0, count: columnAsset.count),
            count: slots.count
        )
        let slotSpan = max(1, allSlots.count - 1)
        for (row, scene) in slots.enumerated() {
            let slotPosition = Double(scene.index) / Double(slotSpan)
            for column in columnAsset.indices {
                let asset = columnAsset[column]
                var value = pairCost(
                    scene: scene,
                    canvas: recipe.canvas,
                    asset: asset,
                    features: features[asset.id]
                ) + Double(columnRepeat[column]) * weights.reusePenalty
                if let rank = chronoRank[asset.id] {
                    value += abs(rank - slotPosition) * weights.chronology
                }
                cost[row][column] = value
            }
        }

        var assignment = solver.solve(cost: cost)
        assignment = refineForDiversity(
            assignment: assignment,
            cost: cost,
            columnAsset: columnAsset,
            features: features,
            seed: shuffleSeed
        )

        for (row, column) in assignment.enumerated() where column >= 0 {
            let scene = slots[row]
            let asset = columnAsset[column]
            result.assetBySlot[scene.slot.id] = asset.id
            result.reasonBySlot[scene.slot.id] = reason(
                scene: scene, asset: asset, features: features[asset.id],
                isReuse: columnRepeat[column] > 0
            )
        }
        return result
    }

    // MARK: - Scoring

    /// Cost of putting `asset` in `scene`. Lower is better; all terms are non-negative so the
    /// solver's optimum is meaningful.
    func pairCost(
        scene: SceneTemplate,
        canvas: CanvasSpec,
        asset: AssetReference,
        features: AssetFeatures?
    ) -> Double {
        var cost = 0.0

        // --- Shot scale ---
        if let assetFraming = features?.framing {
            let slotFraming = scene.slot.framing.value
            let distance = abs(Self.framingIndex(slotFraming) - Self.framingIndex(assetFraming))
            // Scale the penalty by how confident we are the slot's framing is right. An
            // uncertain slot should not strongly reject a photo.
            cost += Double(distance) * weights.framingMismatch * scene.slot.framing.confidence
        } else {
            // Unknown framing is a mild penalty, not a disqualification.
            cost += 0.3 * weights.framingMismatch
        }

        // --- Quality ---
        if let score = features?.aestheticScore {
            // Documented range is roughly -1...1.
            let normalized = min(1, max(0, (score + 1) / 2))
            var weight = weights.aesthetics
            // The hero shot is the one people look at. Weight quality much harder there, and
            // barely at all for a 0.4 s flash the eye cannot evaluate.
            switch scene.role.value {
            case .hero: weight *= 2.2
            case .opening, .closing: weight *= 1.5
            case .detail, .wide, .body: weight *= scene.duration < 0.5 ? 0.5 : 1.0
            }
            cost += (1 - normalized) * weight
        }

        // Screenshots and receipts. A large flat penalty rather than exclusion, so a project
        // that contains nothing else still produces a video.
        if features?.isUtility == true {
            cost += weights.utilityPenalty
        }

        // Soft focus. Weighted like aesthetics: hard on the shots people look at.
        if let sharpness = features?.sharpness {
            let weight = scene.role.value == .hero ? weights.softness * 1.8 : weights.softness
            cost += (1 - sharpness) * weight
        }

        // Subject placement. Only when both sides know where their subject is.
        if let assetSubject = features?.salientRect,
           let slotSubject = scene.slot.subjectRect, slotSubject.confidence >= 0.4 {
            let dx = assetSubject.centerX - slotSubject.value.centerX
            let dy = assetSubject.centerY - slotSubject.value.centerY
            cost += min(1, (dx * dx + dy * dy).squareRoot()) * weights.subjectPosition
        }

        // --- Framing loss ---
        // How much of the photo has to be thrown away to fill the canvas.
        let assetAspect = features?.aspectRatio ?? asset.aspectRatio
        let canvasAspect = canvas.aspectRatio
        let cropLoss = assetAspect > canvasAspect
            ? 1 - canvasAspect / assetAspect
            : 1 - assetAspect / canvasAspect
        cost += cropLoss * weights.aspectMismatch

        // --- Stills vs footage ---
        switch scene.sourceKind {
        case .video where asset.kind != .video:
            cost += weights.sourceKindMismatch
        case .image where asset.kind == .video:
            // Putting footage where the reference had a still is fine — it just becomes a
            // gentler choice than the reverse.
            cost += weights.sourceKindMismatch * 0.4
        default:
            break
        }

        // A video too short for its slot would have to freeze or loop.
        if asset.kind == .video, asset.duration > 0, asset.duration < scene.duration {
            let shortfall = (scene.duration - asset.duration) / max(scene.duration, 0.001)
            cost += shortfall * weights.insufficientDuration
        }

        return cost
    }

    private static func framingIndex(_ framing: ShotFraming) -> Int {
        switch framing {
        case .closeUp: return 0
        case .medium: return 1
        case .wide: return 2
        }
    }

    // MARK: - Diversity

    /// Fixes the one thing linear assignment cannot see: two near-identical photos landing in
    /// consecutive slots, which reads as a stutter even when each individual choice was optimal.
    ///
    /// Hill-climbing over pairwise swaps. Deterministic given `seed` — the seed only changes
    /// the order pairs are considered, so "Shuffle" explores a different local optimum rather
    /// than randomising the result.
    private func refineForDiversity(
        assignment: [Int],
        cost: [[Double]],
        columnAsset: [AssetReference],
        features: [UUID: AssetFeatures],
        seed: Int
    ) -> [Int] {
        guard assignment.count > 2 else { return assignment }

        var current = assignment
        var order = Array(assignment.indices)
        if seed != 0 {
            // A fixed permutation from the seed. Not random — reproducible for a given seed.
            var state = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1)
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let j = Int(state >> 33) % (i + 1)
                order.swapAt(i, j)
            }
        }

        func totalCost(_ candidate: [Int]) -> Double {
            var total = solver.totalCost(of: candidate, in: cost)
            for i in 0..<(candidate.count - 1) {
                let a = candidate[i]
                let b = candidate[i + 1]
                guard a >= 0, b >= 0 else { continue }
                total += adjacencyPenalty(
                    columnAsset[a], columnAsset[b], features: features
                )
            }
            return total
        }

        var bestCost = totalCost(current)
        var improved = true
        var passes = 0

        // Two passes is empirically enough to clear adjacent duplicates, and bounding it means
        // Auto Arrange has a predictable worst case.
        while improved, passes < 2 {
            improved = false
            passes += 1
            for i in order.indices {
                for j in (i + 1)..<order.count {
                    var candidate = current
                    candidate.swapAt(order[i], order[j])
                    let candidateCost = totalCost(candidate)
                    if candidateCost < bestCost - 1e-9 {
                        current = candidate
                        bestCost = candidateCost
                        improved = true
                    }
                }
            }
        }
        return current
    }

    private func adjacencyPenalty(
        _ a: AssetReference, _ b: AssetReference, features: [UUID: AssetFeatures]
    ) -> Double {
        // The same photo twice in a row is always wrong, regardless of feature prints.
        if a.id == b.id { return weights.adjacentSimilarity * 2 }

        guard let featuresA = features[a.id],
              let featuresB = features[b.id],
              let distance = featuresA.featureDistance(to: featuresB) else { return 0 }

        guard distance < weights.duplicateDistanceThreshold else { return 0 }
        // Ramp: identical images cost the full penalty, marginally-similar ones cost little.
        let similarity = 1 - distance / weights.duplicateDistanceThreshold
        return similarity * weights.adjacentSimilarity
    }

    // MARK: - Explanation

    /// The caption under each assignment on the mapping screen. Says the actual reason, so a
    /// surprising choice is arguable rather than mysterious.
    private func reason(
        scene: SceneTemplate, asset: AssetReference,
        features: AssetFeatures?, isReuse: Bool
    ) -> String {
        var parts: [String] = []

        if let framing = features?.framing {
            if framing == scene.slot.framing.value {
                parts.append("\(framing.displayName.lowercased()) matches slot")
            } else {
                parts.append(framing.displayName.lowercased())
            }
        }
        if let score = features?.aestheticScore, score > 0.35 {
            parts.append("high quality")
        }
        if let sharpness = features?.sharpness, sharpness < 0.35 {
            parts.append("a little soft")
        }
        if let faces = features?.faceCount, faces > 0 {
            parts.append(faces == 1 ? "face" : "\(faces) faces")
        }
        if scene.role.value == .hero {
            parts.append("best available for hero")
        }
        if asset.kind == .video {
            parts.append("video")
        }
        if features?.isUtility == true {
            parts.append("looks like a screenshot")
        }
        if isReuse {
            parts.append("reused — add more photos to avoid")
        }

        return parts.isEmpty ? "best remaining fit" : parts.joined(separator: " · ")
    }

    // MARK: - Per-slot ranking

    /// Ranks every asset for one slot, for the "tap to swap" sheet. Same cost function as the
    /// solver, so the sheet's order agrees with the automatic choice instead of contradicting it.
    public func ranking(
        for scene: SceneTemplate,
        canvas: CanvasSpec,
        assets: AssetPool,
        features: [UUID: AssetFeatures]
    ) -> [(asset: AssetReference, reason: String)] {
        assets.visuals
            .map { asset in
                (
                    asset,
                    pairCost(scene: scene, canvas: canvas, asset: asset, features: features[asset.id])
                )
            }
            .sorted { $0.1 < $1.1 }
            .map { asset, _ in
                (asset, reason(scene: scene, asset: asset, features: features[asset.id], isReuse: false))
            }
    }
}
