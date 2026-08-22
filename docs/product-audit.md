# Product audit — 2026-08-18

Inspection of the repository at commit `10839d0`, before any modification.

## Scale

| | |
|---|---|
| Swift files | 87 |
| Swift LOC | 26,501 |
| Metal LOC | 306 |
| Commits | 48 |
| Tests | 43 tests, 11 suites |
| **Navigation tests** | **0** |

## Architecture as built

```
Reframe/                 app — SwiftUI, no engine logic
├── App/                 AppModel (806 lines), ReframeApp (Route enum)
├── DesignSystem/        Theme, Components, Controls, ShareSheet, LoopingVideoView
├── Features/            Audio, Content, Editor, Export, Home, Mapping,
│                        Reference, Settings, Templates
└── Services/            MediaImport, TemplatePreviewStore, ThumbnailCache, VoiceRecorder

Packages/ReframeKit/
├── RecipeCore/          schema, Timeline, commands, binder, music planner,
│                        variations, beat retimer, starter templates, quality
├── MediaIO/             frame stream, audio decode/tools, project store, diagnostics
├── Analysis/            scene, shot, motion, text, colour, audio → recipe
├── Mapping/             Vision features, cost matrix, Hungarian solver
├── Rendering/           Metal graph, text raster, audio mix, exporter, preview
├── Intelligence/        provider abstraction, caption transcriber
└── Tools/CoreCheck/     548-line invariant checker
```

The three-model separation (`EditRecipe` → `Timeline` → `RenderPlan`) is intact and sound.
Preview and export share one render path. **This is worth preserving.**

## What genuinely works

Reference analysis (scene/shot/motion/text/colour/audio), BPM and beat grid, Vision asset
scoring with optimal Hungarian assignment, Metal compositing, AVAssetWriter export, undoable
command stack with gesture coalescing, project persistence with crash recovery, diagnostics
flight recorder, music-driven planning, variations, starter templates, template preview
rendering, caption transcription, voiceover, audio ducking.

## What is claimed but absent

Verified by grep for the *model*, not the word:

| Claimed | Reality |
|---|---|
| Keyframes | **No model exists.** `Keyframe` struct: absent. Matches were prose in comments |
| LUT | **Absent.** No `.cube` parsing, no LUT texture |
| Masks | **Absent.** No mask model |
| Chroma key | Absent |
| Blend modes | Absent |
| Speed curves | Absent — `speed` is a single scalar |
| Multi-track | Absent — see below |
| Stabilise, ripple, magnetic, stickers | Absent |

## The central architectural gap

`Timeline` is:

```swift
public var clips: [VideoClip]       // ONE sequential video track
public var textLayers: [TextLayer]  // flat array
public var overlays: [OverlayLayer] // flat array
public var audio: [AudioClip]       // flat array
```

There is **no track abstraction**. Consequences: no second video track, no PiP as a
first-class concept, no track lock/hide/mute/solo, no track reordering, no effect tracks, and
no place to hang per-track properties. Every professional-tier capability in the brief —
compositing, layered overlays, multi-track audio — is blocked behind this one gap.

`relayout()` also force-packs clips gaplessly, so gaps and absolute positioning (PRO mode)
are unrepresentable.

## Navigation — the reported bug, root-caused

Navigation state is `AppModel.path: [Route]`, mutated from **12 sites across 8 files**. Child
screens decide where the app goes next, which Rule #2 forbids.

The dead-end is reproducible and structural:

1. `AnalysisView` sets `.navigationBarBackButtonHidden(true)`
2. Its Cancel button renders only `if !isFinished`
3. On success it appends `.recipeSummary`; `.onDisappear` cancels `task`
4. User taps back from the summary → returns to `.analysis(url)`
5. `@State` survives: `isFinished == true`, `task != nil`
6. `runAnalysis()` returns immediately on `guard task == nil`

Result: **no back button, no cancel button, no forward navigation, no re-run.** Force-quit is
the only exit. This is a state-machine failure, not a missing button.

## Verification status

Compiles and passes 43 tests on `macos-26` CI, which also publishes an unsigned `.ipa`.
**Never validated end-to-end on a device.** Every performance target in `docs/08-quality.md`
remains unmeasured.
