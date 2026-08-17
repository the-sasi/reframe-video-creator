import ReframeKit
import SwiftUI

/// Honest progress, which is harder than a fake percentage and much better.
///
/// Stages complete with a real result rather than ticking up, so what appears on screen is
/// information. Results land as they finish, so by the time the last stage completes the user
/// has already read most of the summary. Cancel is real — the pipeline checks
/// `Task.isCancelled` every frame.
struct AnalysisView: View {
    let sourceURL: URL

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var progress = AnalysisProgress.initial
    @State private var task: Task<Void, Never>?
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: Theme.Space.xl)

            VStack(spacing: Theme.Space.s) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
                    .symbolEffect(.pulse, isActive: !isFinished)

                Text(isFinished ? "Reference understood" : "Analysing your video")
                    .font(Theme.Font.screenTitle)
                    .contentTransition(.opacity)

                if !isFinished {
                    Text("Everything happens on this iPhone.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(progress.stages) { state in
                    StageRow(title: state.stage.title, status: state.status)
                }
            }
            .padding(Theme.Space.l)
            .cardSurface()
            .animation(
                Theme.Motion.respectingReduceMotion(Theme.Motion.smooth, reduce: reduceMotion),
                value: progress
            )

            Spacer(minLength: 0)

            if !isFinished {
                Button("Cancel") {
                    task?.cancel()
                    model.path.removeLast()
                }
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
                .minimumHitTarget()
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .task { await runAnalysis() }
        .onDisappear { task?.cancel() }
    }

    private func runAnalysis() async {
        guard task == nil else { return }

        let pipeline = AnalysisPipeline()

        // Progress is an AsyncStream, so the view never polls.
        let progressTask = Task {
            for await update in await pipeline.progressStream() {
                await MainActor.run { progress = update }
            }
        }

        let work = Task {
            do {
                let recipe = try await pipeline.analyze(url: sourceURL)
                await MainActor.run {
                    model.recipe = recipe
                    isFinished = true
                    Haptics.success()
                }
                // A beat to let the last stage's result land before moving on — the summary is
                // more legible if you saw it complete.
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    model.path.append(.recipeSummary)
                }
            } catch let error as ReframeError {
                await MainActor.run {
                    if case .analysisCancelled = error { return }
                    model.present(error)
                    if !model.path.isEmpty { model.path.removeLast() }
                }
            } catch is CancellationError {
                // Leaving the screen cancelled it. Nothing to report.
            } catch {
                await MainActor.run {
                    model.present(.analysisFailed(stage: "analysing", detail: "\(error)"))
                    if !model.path.isEmpty { model.path.removeLast() }
                }
            }
            progressTask.cancel()
        }

        task = work
        await work.value
    }
}
