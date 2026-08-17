# 01 — Product & system architecture

## The three models

The central design idea is that **style, document and frame are three different things**, and
conflating any two of them is what makes video editors hard to change.

```
EditRecipe ──(+ AssetPool, + UserTextInput)──▶ Timeline ──(+ time t)──▶ RenderPlan
   style                                       document                  frame
```

### `EditRecipe` — the style

Asset-free, reusable, portable. Describes *shapes of scenes*, not scenes: "slot 3 wants a tight
shot, holds 0.8 s, pushes in from 1.00 to 1.18 anchored slightly left, enters on a 0.2 s
dissolve, lands on beat 7." It contains no file paths and no pixels. Two different projects can
share one recipe; one project can swap recipes and keep its assets.

This is the artefact the brief calls the most important intellectual component, and everything
else is arranged around producing and consuming it cleanly.

### `Timeline` — the document

Concrete. Clips point at real assets, text layers carry the user's actual words, durations are
resolved. This is the only thing the editor mutates, and it mutates it exclusively through
undoable `EditCommand`s. It is a Codable value type, so snapshotting is cheap (copy-on-write)
and serialisation is free.

### `RenderPlan` — the frame

A flat, immutable draw list for one instant: which textures, which transforms, which shader,
which uniforms. Produced by a pure function. Consumed by Metal. Never persisted.

```swift
func plan(_ timeline: Timeline, at time: Double) -> RenderPlan   // pure, testable, no GPU
func render(_ plan: RenderPlan, into: MTLTexture)                // no policy, just draws
```

Splitting "what to draw" from "how to draw it" means the interesting logic — layer ordering,
transition interpolation, Ken Burns curves, text timing — is unit-testable on a Mac with no GPU,
no simulator and no device. That property paid for itself immediately: `RenderPlannerTests`
covers transition overlap and z-order without touching Metal.

---

## Why preview and export cannot diverge

This is the strongest structural guarantee in the codebase, so it is worth stating flatly.

```
                        ┌─────────────────────┐
   CADisplayLink ──────▶│                     │──▶ MTKView          (preview)
                        │  plan() → render()  │
   AssetWriter pull ───▶│                     │──▶ CVPixelBuffer    (export)
                        └─────────────────────┘
```

Both drivers call the *same two functions*. They differ only in the `FrameProvider` supplying
source pixels — `PreviewFrameProvider` serves cached proxy-resolution textures and tolerates a
miss by reusing the last good frame; `ExportFrameProvider` decodes at full resolution
sequentially and blocks until exact. Neither knows anything about layout, timing or effects.

The alternative — `AVPlayer` + `videoComposition` for preview and `AVAssetExportSession` for
export — is two pipelines with two sets of bugs. The standard advice in that world is to inject a
shared compositor "so the two paths do not silently diverge", which is a mitigation for a problem
we simply do not have.

---

## Pipeline

```
 ┌── Import ─────────────────────────────────────────────────────────┐
 │ PhotosPicker / fileImporter / Share Sheet  →  MediaSource         │
 └───────────────────────────┬───────────────────────────────────────┘
                             ▼
 ┌── AnalysisPipeline (actor, cancellable, progress-reporting) ──────┐
 │  ① FrameStream        AVAssetReader → 256 px BGRA, streamed       │
 │  ② SceneDetector      HSV delta + adaptive threshold → cuts       │
 │                       linear-blend residual → dissolves/fades     │
 │  ③ MotionAnalyzer     optical flow → similarity fit → CameraMove  │
 │  ④ ColorAnalyzer      k-means → palette, exposure, grade          │
 │  ⑤ TextAnalyzer       OCR → tracks → style → watermark filter     │
 │  ⑥ AudioAnalyzer      spectral flux → onset → BPM → beat grid     │
 └───────────────────────────┬───────────────────────────────────────┘
                             ▼  ReferenceAnalysis
 ┌── RecipeCompiler ─────────────────────────────────────────────────┐
 │  scenes → slots, roles, moves; beats → snap grid; confidences     │
 └───────────────────────────┬───────────────────────────────────────┘
                             ▼  EditRecipe   ← persisted, reusable
 ┌── Mapping ────────────────────────────────────────────────────────┐
 │  AssetFeatureExtractor  saliency, aesthetics, feature print       │
 │  AssetScorer            slot × asset cost matrix                  │
 │  HungarianSolver        optimal assignment                        │
 │  DiversityRefiner       pairwise swaps against adjacency penalty  │
 └───────────────────────────┬───────────────────────────────────────┘
                             ▼  AssetAssignment
 ┌── RecipeBinder ───────────────────────────────────────────────────┐
 │  recipe + assignment + user text → Timeline                       │
 └───────────────────────────┬───────────────────────────────────────┘
                             ▼  Timeline  ← editable, undoable
 ┌── Render ─────────────────────────────────────────────────────────┐
 │  RenderPlanner → MetalRenderer → PreviewEngine | VideoExporter    │
 └───────────────────────────┬───────────────────────────────────────┘
                             ▼
                    Photos / Files / Share
```

Each stage has one input type and one output type, and no stage reaches backwards. `Analysis`
does not know `Rendering` exists. `Rendering` has never heard of a reference video.

---

## Concurrency

Swift 6 strict concurrency, project-wide.

- `AnalysisPipeline` is an `actor`. It owns the `AVAssetReader` and the progress state.
- Per-stage work uses `withTaskGroup` where stages are independent (colour and text analysis run
  concurrently over the same frame stream; motion analysis is serialised because optical flow is
  GPU-contended and running it in parallel with itself thrashes).
- Cancellation is cooperative and checked at every frame boundary — closing the analysis screen
  actually stops the work rather than orphaning it.
- The renderer is **not** an actor. It is a class confined to a serial `DispatchQueue` because
  `MTLCommandBuffer` submission ordering matters and actor reentrancy would be a hazard. This is
  marked `@unchecked Sendable` with a comment explaining exactly why, which is the honest way to
  do it.
- Progress crosses to the UI as an `AsyncStream<AnalysisProgress>`, so the view layer never polls.

---

## Storage (§30)

```
Documents/
├── Reframe.store                      SwiftData: project index, titles, dates, thumb paths
├── Recipes/
│   └── <recipe-uuid>.editrecipe.json  reusable across projects
└── Projects/
    └── <project-uuid>.reframeproj/
        ├── project.json               Timeline + settings + recipe reference
        ├── assets.json                bookmarks + fingerprints, NOT copies
        ├── thumbnails/
        └── proxies/                   720p transcodes, regenerable, evictable
```

Rules, in priority order:

1. **Never copy the user's originals.** Assets are referenced by `PHAsset.localIdentifier` or a
   security-scoped bookmark. A 20-photo project costs kilobytes.
2. **Documents are JSON, versioned, and human-readable.** `schemaVersion` on every root object,
   with a migration hook. Debugging a bad recipe means opening a file, not attaching a debugger.
3. **The SwiftData store holds only what a list view needs** — id, title, dates, counts,
   thumbnail path. It is an index, not a document store. If it were lost, every project would
   still be recoverable by scanning `Projects/`.
4. **`proxies/` and `thumbnails/` are caches**, marked with `.isExcludedFromBackup` and
   evictable under storage pressure. Losing them costs time, never data.

Assets can go missing — the user deletes a photo. `AssetReference.resolve()` returns a
`ResolvedAsset?` and the timeline renders a labelled placeholder for `nil` rather than crashing
or silently dropping a scene.

---

## Memory (§29)

The failure mode this app must not have is being jetsammed mid-export. Four rules:

1. **Nothing decodes at full resolution unless it is about to be encoded.** Analysis runs at
   256 px. Preview runs at proxy resolution capped to the view's `drawableSize`. Only
   `ExportFrameProvider` touches full-resolution pixels, one frame at a time.
2. **Frames stream; they do not accumulate.** `FrameStream` is an `AsyncSequence` over
   `AVAssetReader` output with a bounded buffer. A 60 s reference costs one frame of resident
   memory, not 1,800.
3. **Textures come from a pool.** `TexturePool` recycles `MTLTexture`s by descriptor. Steady-state
   allocation during export is zero.
4. **Caches are bounded and pressure-aware.** `NSCache` for thumbnails and rasterised text,
   plus a `didReceiveMemoryWarning` hook that drops proxies and text textures immediately.

`PerformanceLog` records peak footprint per stage so these claims can be checked rather than
believed. They have **not** been checked yet — see [07](07-roadmap.md#first-build-checklist).

---

## Error handling (§44)

One error type, `ReframeError`, with a `UserFacingDescription` for every case: title, plain
explanation, and a **`recovery: RecoveryAction`** — a real action, not prose. Unsupported codec
offers *Convert on import*; low storage offers *Manage storage*; denied Photos access offers
*Open Settings*; a failed export offers *Retry at 720p*.

Technical detail goes to `os.Logger`, never to the screen. There is no code path that surfaces
an `NSError` domain string to the user.
