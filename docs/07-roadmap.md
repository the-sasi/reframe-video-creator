# 07 — Phases, scope, and what happens next

## Phasing

| Phase | Scope | State |
|---|---|---|
| **1 — Editor foundation** | Import, timeline, preview, trim/split, text, transitions, export | ✅ Built, rebuilt Aug 2026 (direct-manipulation timeline, contextual tools) |
| **2 — Reference analysis** | Scene detection, timing, motion, OCR, audio, composition | ✅ Built; motion/dissolve/fade detection corrected Aug 2026 |
| **3 — Template engine** | `EditRecipe` schema, slots, transitions, beat timing, binder, fidelity modes, subject-aware crop | ✅ Built |
| **4 — Asset mapping** | Feature extraction (saliency, aesthetics, sharpness, faces, prints), Hungarian, diversity, pins, chronology | ✅ Built |
| **5 — Audio** | Mix planner, music / voice / reference / clip audio, ducking, voiceover recording, extraction, waveforms | ✅ Built |
| **6 — Captions & text** | On-device transcription → timed captions; fonts, weights, outline, pill, presets | ✅ Built (captions optional, iOS 26) |
| **7 — Product** | Templates library, autosave, recovery, thumbnails, rename/duplicate/favourite, export presets, appearance | ✅ Built |
| **7b — Music-driven editing** | `MusicSectionizer` (intro/build/peak/release/outro from energy), `MusicEditPlanner` (beats + sections → recipe), `EditQuality` score with arrange-repair, "Edit to Music" flow | ✅ Built Aug 2026 |
| **8 — Device validation** | Real references, real photos, measured performance | ⬜ **Owner's step** — see [09](09-device-testing.md) |
| **9 — Advanced editing** | Keyframes, picture-in-picture, masks, LUTs, speed ramps, reverse/freeze | ⬜ Not built — P2, see below |
| **10 — Generative** | B-roll, image animation, background generation | ⬜ Not built — see below |

### On phase 9

The brief lists keyframes, PiP, masking, LUTs, reverse and freeze-frame. None of these is
required for the hero flow, all of them are real work, and several would change the render
plan's shape. They are ordered here by value per unit of risk:

1. **Keyframes on clip position/scale/opacity and text opacity/scale.** The crop rects already
   *are* two keyframes with an easing; generalising `cropStart/cropEnd` to `[CropKeyframe]` and
   adding an opacity track is a contained schema change with a straightforward planner change.
2. **Freeze frame and reverse.** Both are `sourceTime` mappings in the planner
   (`sourceTime = constant`, `sourceTime = end - t·speed`) plus a sequential-decoder path that can
   read backwards. Reverse needs a decode-to-cache pass for long clips.
3. **Picture-in-picture / stickers.** `OverlayLayer` already renders any image at any rect; PiP
   is an overlay whose asset is a video, which the frame providers already handle. Needs a UI.
4. **Masks.** A per-layer mask texture (rect / circle / gradient) is one more sampler in the
   layer shader. Custom shapes are a rasterisation problem the text pipeline already solved.
5. **LUTs.** A 3D texture sampler and a licence-checked LUT source. Grade + presets cover most of
   the practical need; LUTs are last.

### On phase 10

The brief says generative AI must be optional, and asks that the app be useful without it.
There is currently no free, offline, on-device image-to-video model that runs acceptably on an
iPhone. Every credible option is a paid API — forbidden as a mandatory dependency, and as an
optional one it would still mean building a billing-shaped hole into a personal app.
`IntelligenceProvider` has room for it. It stays empty until the model landscape changes.

---

## Scope, as delivered (Aug 2026)

| Area | Where |
|---|---|
| Import reference (Photos, Files, Share → Reframe) | `ReferenceImportView`, `AppModel.handleIncomingURL`, `Info.plist` document types |
| Analyse scenes / motion / composition / text / audio | `Analysis/*` |
| Fidelity modes | `RecipeBinder.Options.fidelity`, `RecipeSummaryView` |
| Reference audio: keep / extract / save to Files | `AudioExtractor`, `RecipeSummaryView`, `AudioSheet` |
| Import photos / clips / music; record voiceover | `ContentImportView`, `MediaImport`, `VoiceRecorder`, `VoiceoverSheet` |
| Analyse assets, map, pin, shuffle | `AssetFeatureExtractor`, `AssetMapper`, `MappingView` |
| Subject-aware crop, aspect retargeting | `RecipeBinder.fillWindow`, `CanvasSheet`, `StyleSheet` smart crop |
| Preview with playing video and mixed audio | `PreviewEngine`, `PreviewFrameProvider`, `AudioMixBuilder` |
| Timeline: trim, split, reorder, text/audio drag | `TimelineView` |
| Text: fonts, presets, outline, pill, animation, timing, captions | `TextSheet`, `CaptionsSheet`, `TextRasterizer` |
| Audio: tracks, levels, fades, ducking, clip sound | `AudioSheet`, `AudioMixPlanner` |
| Transitions, speed, replace, canvas, look | `EditorSheets`, `StyleSheet` |
| Export presets, sizes, quality, Photos / Files / share | `ExportView`, `VideoExporter` |
| Projects: autosave, recovery, thumbnails, rename, duplicate, favourite, search, sort | `AppModel`, `HomeView`, `ProjectStore` |
| Templates: library, starters, save, import, export | `TemplateLibraryView`, `StarterTemplates` |
| Diagnostics: text and JSON export | `DiagnosticsLog`, `DiagnosticsView` |

Exclusions honoured: no generative video, no cloud infrastructure, no social features, no
accounts, no subscriptions, no analytics. `ZeroCostArchitectureTests` greps the source tree for
provider key patterns and fails the build if one appears.

---

## First-device checklist

The build has been compiled and unit-tested by CI only. Expect the first device run to find
things in roughly this order; each is a diagnostics-log line away from a fix:

1. **Timing feel.** Beat quantisation and transition durations were tuned against synthetic
   references. Real music will say whether 120 ms is the right snap tolerance.
2. **Preview video sync.** The AVPlayer-per-clip approach infers playback rate from the
   timeline; a stutter on speed-changed clips would show up here.
3. **Memory on 4K exports.** The still cache is byte-budgeted at ~120 MB; the number to watch is
   peak footprint in the log during a 4K export of a 20-photo project.
4. **Caption language pack.** First use downloads assets via the system; the flow is written
   against the iOS 26 API as documented and needs one real run.
5. **Thermal behaviour** during a 60 s 1080p60 export.

Then, before trusting any number in [08](08-quality.md), run the matrix in
[09](09-device-testing.md) and write the measurements down.

---

## Future extension strategy

Ordered by value per unit of risk.

1. **Keyframes** — see phase 9 above.
2. **Multi-reference blending.** Pacing from one reference, typography from another. The schema
   separates them cleanly enough that this is a merge function.
3. **Speech-driven cutting.** `CaptionTranscriber` already gives timed segments; cutting on
   sentence boundaries for talking-head references is a small addition to `RecipeCompiler`.
4. **iPad + Mac Catalyst.** The engine has no UIKit dependency; only the timeline view and
   preview host would need work.
5. **Optional cloud providers.** `IntelligenceProvider` exists precisely so this can be added
   without touching the core. It should stay unimplemented until there is a reason.

Explicitly **not** on the roadmap: accounts, sync, subscriptions, telemetry, a backend of any
kind.
