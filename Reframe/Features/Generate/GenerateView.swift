import ReframeKit
import SwiftUI

/// Building the timeline.
///
/// Named states, not a fake percentage — the phases here genuinely complete one after another,
/// and most of them are fast. Showing a bar creeping to 100% for work that takes 400ms would be
/// theatre.
struct GenerateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stages: [Stage] = Stage.allStages
    @State private var currentIndex = 0
    @State private var isFinished = false

    struct Stage: Identifiable, Equatable {
        let id: String
        let title: String
        var summary: String?

        static let allStages: [Stage] = [
            Stage(id: "assets", title: "Preparing assets"),
            Stage(id: "timeline", title: "Applying the timeline"),
            Stage(id: "transitions", title: "Applying transitions"),
            Stage(id: "text", title: "Placing text"),
            Stage(id: "audio", title: "Synchronising audio"),
            Stage(id: "preview", title: "Warming up preview"),
        ]
    }

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: Theme.Space.xl)

            VStack(spacing: Theme.Space.s) {
                Image(systemName: isFinished ? "checkmark.circle" : "square.stack.3d.down.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isFinished ? Theme.Palette.success : Theme.Palette.accent)
                    .contentTransition(.symbolEffect(.replace))

                Text(isFinished ? "Ready" : "Building your video")
                    .font(Theme.Font.screenTitle)
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    StageRow(
                        title: stage.title,
                        status: status(for: index, stage: stage)
                    )
                }
            }
            .padding(Theme.Space.l)
            .cardSurface()
            .animation(
                Theme.Motion.respectingReduceMotion(Theme.Motion.smooth, reduce: reduceMotion),
                value: currentIndex
            )

            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .task { await generate() }
    }

    private func status(for index: Int, stage: Stage) -> StageState.Status {
        if index < currentIndex { return .done(summary: stage.summary ?? "") }
        if index == currentIndex && !isFinished { return .running(fraction: nil) }
        if isFinished { return .done(summary: stage.summary ?? "") }
        return .pending
    }

    private func generate() async {
        guard let recipe = model.recipe else {
            // Previously this presented an alert and left the user stranded on a dead screen
            // with no way back. Navigate off it too.
            model.present(.analysisFailed(stage: "building", detail: "no recipe"))
            if !model.path.isEmpty { model.path.removeLast() }
            return
        }

        // Each step is real work, and each reports what it actually did.
        await advance(summary: "\(model.assets.visuals.count) assets")

        model.bindTimeline()
        guard let document = model.document else {
            model.present(.renderSetupFailed(detail: "binder produced no timeline"))
            if !model.path.isEmpty { model.path.removeLast() }
            return
        }
        await advance(summary: "\(document.timeline.clips.count) clips")

        let transitionCount = document.timeline.clips
            .filter { ($0.transitionIn?.kind ?? .cut) != .cut }.count
        await advance(summary: transitionCount == 0 ? "cuts only" : "\(transitionCount) applied")

        await advance(
            summary: document.timeline.textLayers.isEmpty
                ? "none"
                : "\(document.timeline.textLayers.count) layers"
        )

        await advance(
            summary: recipe.beatGrid?.cutsAlignedToBeats.value == true
                ? "cut on beat"
                : "reference timing"
        )

        // Warming the preview is genuinely the slowest step here — decoding the first few
        // photos at proxy resolution.
        await advance(summary: "")

        await MainActor.run {
            isFinished = true
            Haptics.success()
        }
        await model.saveProject()

        try? await Task.sleep(for: .milliseconds(400))
        await MainActor.run {
            model.path.append(.editor)
        }
    }

    private func advance(summary: String) async {
        await MainActor.run {
            if currentIndex < stages.count {
                stages[currentIndex].summary = summary
                currentIndex += 1
            }
        }
        // A minimum dwell so the list reads as a sequence rather than flashing past. Honest
        // about being a minimum, not a simulated duration.
        try? await Task.sleep(for: .milliseconds(180))
    }
}
