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
    /// Set when analysis fails. The screen stays put and offers retry/diagnostics/back rather
    /// than bouncing the user somewhere else with an alert.
    @State private var failure: ReframeError?

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

            exits
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
        // Back is hidden only while work is genuinely in flight, so the gesture cannot
        // orphan a running pipeline. The moment it finishes or fails, the exits below take
        // over — the previous version hid it permanently, which is what made this screen a
        // dead end once analysis completed.
        .navigationBarBackButtonHidden(!isFinished && failure == nil)
        .navigationBarTitleDisplayMode(.inline)
        .task { await runAnalysis() }
        .onDisappear { task?.cancel() }
    }

    /// There is always a way out of this screen. That is the invariant the dead-end bug broke.
    @ViewBuilder
    private var exits: some View {
        if let failure {
            VStack(spacing: Theme.Space.s) {
                Text(failure.presentation.title)
                    .font(Theme.Font.sectionTitle)
                Text(failure.presentation.message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise") {
                    self.failure = nil
                    progress = .initial
                    task = nil
                    Task { await runAnalysis() }
                }
                HStack(spacing: Theme.Space.l) {
                    Button("Choose Another") { model.goBack() }
                    Button("Diagnostics") { model.navigate(to: .settings) }
                }
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
            }
            .padding(.horizontal, Theme.Space.m)
        } else if isFinished {
            // Reachable by navigating back from the summary. The recipe already exists, so the
            // useful action is to carry on with it — never to re-run and discard it.
            VStack(spacing: Theme.Space.s) {
                PrimaryButton(title: "Continue", systemImage: "arrow.right") {
                    model.navigate(to: .recipeSummary)
                }
                Button("Start Over") { model.goBack() }
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .minimumHitTarget()
            }
            .padding(.horizontal, Theme.Space.m)
        } else {
            Button("Cancel") {
                task?.cancel()
                model.cancelCurrent()
            }
            .font(Theme.Font.callout)
            .foregroundStyle(Theme.Palette.secondaryText)
            .minimumHitTarget()
        }
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
                    // Kept only so the soundtrack can be extracted if the user asks on the
                    // next screen. Analysis itself is finished with the file.
                    model.referenceURL = sourceURL
                    isFinished = true
                    Haptics.success()
                }
                // A beat to let the last stage's result land before moving on — the summary is
                // more legible if you saw it complete.
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    model.navigate(to: .recipeSummary)
                }
            } catch let error as ReframeError {
                await MainActor.run {
                    if case .analysisCancelled = error { return }
                    // Stay put and offer recovery here. Popping the screen and showing an alert
                    // discarded the context the user needed to decide what to do.
                    failure = error
                    DiagnosticsLog.shared.failure("analysis", error.logDetail)
                }
            } catch is CancellationError {
                // Leaving the screen cancelled it. Nothing to report.
            } catch {
                await MainActor.run {
                    failure = .analysisFailed(stage: "analysing", detail: "\(error)")
                }
            }
            progressTask.cancel()
        }

        task = work
        await work.value
    }
}
