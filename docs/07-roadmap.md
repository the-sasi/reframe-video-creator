# 07 — Phases, MVP scope, and what happens next

## Phasing

| Phase | Scope | State |
|---|---|---|
| **1 — Editor foundation** | Import, timeline, preview, trim/split, text, basic transitions, export | ✅ Built |
| **2 — Reference analysis** | Scene detection, timing, motion, OCR, audio | ✅ Built |
| **3 — Template engine** | `EditRecipe` schema, slots, transitions, beat timing, binder | ✅ Built |
| **4 — Asset mapping** | Feature extraction, cost matrix, Hungarian, diversity refinement | ✅ Built |
| **5 — AI-assisted generation** | Optional `FoundationModels` copy & role refinement | ✅ Built (optional path) |
| **6 — Advanced AI** | Generative B-roll, image animation, background generation | ⬜ **Not built — see below** |

Phases 1–4 were built in dependency order but shipped as one vertical slice, because a video
editor without export is not testable and a recipe without a binder is not observable.

### On Phase 6

The brief says generative AI must be optional, and asks that the app be useful without it. It is
worth being blunt about why phase 6 is empty rather than partially stubbed: **there is currently
no free, offline, on-device image-to-video model that runs acceptably on an iPhone.** Every
credible option is a paid API — which §3 forbids as a mandatory dependency, and which as an
*optional* dependency would still mean building a billing-shaped hole into a personal app.

`EffectTemplate` has a case reserved and `IntelligenceProvider` has room for a generative
method. Nothing calls them. That is the honest position, and it will change when the model
landscape does, not before.

---

## MVP scope, as delivered

Checked against §48 line by line:

| # | Requirement | Where |
|---|---|---|
| 1 | Import reference video | `Features/Reference/ReferenceImportView.swift` |
| 2 | Analyse scene boundaries | `Analysis/SceneDetector.swift` |
| 3 | Extract timing | `Analysis/RecipeCompiler.swift` |
| 4 | Detect basic transitions | `SceneDetector.detectGradualTransitions` |
| 5 | Import user images | `Features/Content/ContentImportView.swift` |
| 6 | Map images to slots | `Mapping/AssetMapper.swift` |
| 7 | Apply zoom/pan | `Rendering/RenderPlanner.swift` (Ken Burns from `CameraMove`) |
| 8 | Apply transitions | `Rendering/TransitionLibrary.swift` + `Shaders.metal` |
| 9 | Add user text | `RecipeCore/RecipeBinder.swift` + `TextRasterizer.swift` |
| 10 | Render 9:16 | `Rendering/VideoExporter.swift` |
| 11 | Save to Photos | `Features/Export/ExportService.swift` |

And the exclusions, honoured: no generative video, no cloud infrastructure, no social features,
no accounts, no subscriptions, no analytics. There is a test —
`ZeroCostArchitectureTests.testNoAPIKeysAnywhere` — that greps the source tree for provider key
patterns and fails the build if one appears. The constraint is enforced by CI, not by intent.

---

## First-build checklist

This tree was written on Windows and **has never been compiled**. Expect the first `⌘B` on macOS
to surface issues in roughly this order. None of these are design problems; they are the normal
cost of authoring without a compiler.

1. **Signing** — set your team on the `Reframe` target. Bundle id is `com.reframe.app`; change it.
2. **`AVAssetExportSession` deprecations** — `status` is deprecated on iOS 18+ in favour of an
   API that has been reported as documentation-only. We use `AVAssetWriter` directly and avoid
   the question, but the `ExportService` capability probe touches `AVAssetExportSession` and may
   warn.
3. **Vision Swift-API naming** — iOS 18 added a Swift-only Vision API that drops the `VN` prefix
   (`RecognizeTextRequest` vs `VNRecognizeTextRequest`) with a different async shape. The code
   uses the **classic `VN`-prefixed API throughout** because it is stable across more OS versions
   and its behaviour is better documented. Both exist in iOS 26; no migration is required, but do
   not mix them in one file.
4. **`MTLPixelFormat` / `CVPixelBuffer` plumbing** — `CVMetalTextureCache` interop is the most
   likely source of a first-run black frame. `MetalRenderer` logs pixel-format mismatches
   explicitly for this reason.
5. **Metal shader compilation** — `Shaders.metal` must be in the app target's *Compile Sources*,
   not the package's. The Xcode project places it there; XcodeGen's `project.yml` mirrors that.
6. **Concurrency** — Swift 6 strict mode will flag anything I got wrong about `Sendable` across
   the Vision and AVFoundation boundaries. `MetalRenderer` is deliberately
   `@unchecked Sendable` with a comment explaining the serial-queue confinement.

Then, before trusting any number in [08](08-quality.md), run the benchmark suite on a real
device. The instrumentation exists; the measurements do not.

---

## Future extension strategy

Ordered by value per unit of risk.

1. **Recipe marketplace, locally.** Recipes are asset-free JSON with no reference pixels, so they
   are already shareable as files. A share/import affordance is a day of work and turns every
   analysis into reusable capital.
2. **Re-target aspect ratio.** Normalised rects mean a 9:16 recipe can bind to 1:1 or 16:9 with
   only crop re-solving. Saliency already tells us where the subject is.
3. **Multi-reference blending.** Take pacing from one reference and typography from another.
   The schema separates them cleanly enough that this is a merge function, not a rewrite.
4. **Speech-driven cutting.** `SpeechTranscriber` already gives timed segments; cutting on
   sentence boundaries for talking-head references is a small addition to `RecipeCompiler`.
5. **iPad + Mac Catalyst.** The engine has no UIKit dependency; only the timeline view and
   preview host would need work.
6. **Optional cloud providers.** `IntelligenceProvider` exists precisely so this can be added
   without touching the core. It should stay unimplemented until there is a reason.

Explicitly **not** on the roadmap: accounts, sync, subscriptions, telemetry, a backend of any
kind. §32 asked for simple, local, fast, maintainable. Every item above preserves that.
