# 00 — Research findings

Everything below was checked against current sources in **August 2026**. Where a claim could not
be verified from primary sources it is marked **VERIFY REQUIRED** and the design routes around
it rather than depending on it.

---

## 1. The repositories that were suggested

### OpenCut (`OpenCut-app/OpenCut`) — MIT

Verified from the repo itself: MIT licence, ~83k lines of TypeScript, 1,598 commits, last
updated 10 Aug 2026. The project is **mid-rewrite**. The README states the new architecture is
`apps/web/` (Next.js), `apps/desktop/` (GPUI, in progress), and `rust/` (a platform-agnostic
core with a GPU compositor and WASM bindings), with business logic actively migrating from
TypeScript to Rust. Mobile is listed as an *ambition* ("Desktop, mobile, and browser from one
codebase") — there is no iOS target, no iOS build, and no shipping iOS app. The repo is
**explicitly closed to outside contributions** while the architecture settles.

**Decision: do not depend on it. Do not fork it.**

- The useful part (the Rust GPU compositor) is the part that is least finished and would need to
  be bridged to Metal through a C ABI, then have its memory behaviour re-tuned for iOS's jetsam
  limits. That is strictly more work than writing the Metal graph directly, and it buys nothing
  we do not already get from `MTLDevice`.
- A web editor's timeline model is shaped by DOM and WASM constraints we do not have.
- Depending on the pre-1.0 internals of a project that has declared it is redesigning its
  architecture and is not accepting contributions is a maintenance trap.
- **What we did take:** the *idea* of a serialisable, engine-agnostic timeline document that the
  UI never mutates directly. That is a good idea and it is not OpenCut's to own.

**OpenCut Classic** (`OpenCut-app/opencut-classic`) is the frozen predecessor still powering
opencut.app. Frozen predecessor of a project we already rejected — no.

### Remotion — free for us, wrong tool regardless

The licence is genuinely free for individuals and for-profit orgs up to 3 people, with full
commercial rights. So cost is *not* the objection. The objection is architectural: Remotion
renders React to frames via headless Chromium. Shipping a browser engine inside an iOS app to
composite video would be a catastrophic choice on memory, battery, thermals and App Store
review. **Rejected on engineering grounds, not licence grounds.**

### OpenAI Whisper — superseded on this platform

MIT, excellent, and the reference implementation is Python/PyTorch, which does not run on iOS.
The real iOS options are **WhisperKit** (Argmax, MIT — graduated to v1.0.0 on 2026-05-01 and
was folded into `argmaxinc/argmax-oss-swift` alongside SpeakerKit and TTSKit) and Apple's own
**`SpeechAnalyzer` / `SpeechTranscriber`**, new in iOS 26, on-device, with language assets
managed by the system.

**Decision: Apple `SpeechAnalyzer`, if and when transcription is actually needed.** It is
already on the device, costs zero bytes of app size, needs no model download step, no
download-failure UX, and no third-party dependency. WhisperKit would be the better choice only
if we needed Whisper-specific behaviour across many languages, which we do not.

**Analysis still does not need transcription.** The only question the recipe asks of speech
is *is there a voiceover here* — which decides whether the audio plan reports speech and whether
beat-quantised cutting makes sense. That is answered deterministically in `AudioAnalyzer` from
the STFT we have already computed: energy concentration in the 300–3400 Hz speech band, plus
whether the onset envelope's dominant modulation sits in the 3–8 Hz syllabic range rather than
at a musical beat. It is a heuristic, it is reported at ~0.7 confidence rather than dressed up
as certainty, and it costs nothing extra.

**Captions do.** `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26) is now linked, in the
`Intelligence` module, behind an availability check, for exactly one job: turning a voiceover or
kept reference audio into timed caption layers with per-word `audioTimeRange`s
(`CaptionTranscriber`, verified against the WWDC25 session 277 API surface in Aug 2026:
`analyzeSequence(from:)`, `finalizeAndFinish(through:)`, `AssetInventory.assetInstallationRequest`).
The language assets are downloaded by the system from Apple on first use — the app itself still
has no networking code. WhisperKit remains the fallback should Apple's coverage disappoint.

Deeper reasoning in [`03-ai-models.md`](03-ai-models.md).

---

## 2. FFmpeg — investigated, then deliberately excluded

Three independent findings, any one of which is disqualifying:

1. **`ffmpeg-kit` is dead.** Archived 23 Jun 2025; binaries pulled from public repos 6 Jan 2025.
   CocoaPods installs of the xcframework now fail outright. No successor has emerged that covers
   iOS the way it did — the community has fragmented across forks.
2. **LGPL does not survive contact with iOS.** The LGPL requires that a user be able to relink
   the application against a modified version of the library. There is no mechanism to do this
   on iOS. The widely-held reading — argued at length on the `mobile-ffmpeg` tracker — is that
   **LGPL FFmpeg is effectively GPL on iOS**. Static linking makes it worse, not better.
3. **Codec patents are a separate axis entirely.** FFmpeg's own legal page is explicit that
   licence compliance does not resolve patent liability, and H.264 is administered by Via
   Licensing Alliance. The `ffmpeg-kit` maintainers cited exactly this — growing legal
   uncertainty after MPEG LA's acquisition by Via-L — as a reason for retirement.

By contrast, **VideoToolbox and AVFoundation are patent-cleared by Apple** for apps running on
Apple hardware, are hardware-accelerated, and are already installed.

**What we lose:** decoding of VP9 and of AV1-in-WebM on pre-A17-Pro devices. AV1 has hardware
decode from A17 Pro onward; VP9 has no VideoToolbox path on iOS at all. This only matters for
web-downloaded references, which we are not building (§7 below), so the loss is theoretical.

**Decision: no FFmpeg, in any form.** This single decision removes the entire GPL/patent
surface from the project.

---

## 3. Rendering — the load-bearing decision

Four candidate architectures were compared. The full matrix is in
[`05-rendering.md`](05-rendering.md); the summary:

| | AVFoundation `AVVideoCompositing` | **Own Metal graph + AVAssetWriter** | FFmpeg filtergraph | Remotion / WASM |
|---|---|---|---|---|
| Still-image timelines | Awkward — needs a dummy base video track | **Native** | Native | Native |
| Preview/export parity | Two code paths that silently diverge | **One path, by construction** | N/A (no preview) | Poor |
| Known defects | CoreAnimationTool HDR breakage, 1 s overlay delay regression, blurry overlays | None inherited | — | — |
| Memory control | Framework-owned | **Ours** | Poor on iOS | Terrible |
| Licence | Clean | **Clean** | Toxic on iOS | Clean but irrelevant |

The decisive argument is that **our timelines are mostly still images**. `AVMutableComposition`
is built from `AVAssetTrack`s, and a still image is not a track. Every image-heavy editor built
on `AVVideoCompositing` ends up synthesising a dummy black video track purely to give the
compositor a clock to tick against — an artefact that then has to be maintained forever.

Worse, the idiomatic AVFoundation shape uses `AVPlayer` + `videoComposition` for preview and
`AVAssetExportSession` for export. These are different pipelines. The community best-practice
advice for this is literally *"use a dependency-injected compositor so preview and export do not
silently diverge"* — which is a workaround for a problem we can simply not have.

**Decision: own the render graph.**

```swift
func renderPlan(for timeline: Timeline, at time: Double) -> RenderPlan   // pure
func render(_ plan: RenderPlan, into texture: MTLTexture)                // pure
```

Preview drives this from a `CADisplayLink`; export drives the identical call from an
`AVAssetWriter` pull loop. Divergence is not a bug we have to avoid — it is unrepresentable.

The cost we accept: we decode user video clips ourselves (`AVAssetReader` sequentially for
export, a proxy-resolution cache for preview) and we sync preview audio ourselves. Both are
well-understood, and the still-image case — which is the overwhelmingly common one — becomes
trivial instead of contorted.

**Studied but not depended on:** `VideoLab` (MIT, ~921 stars, iOS 11+, ~20 commits, no recent
activity — effectively unmaintained) and `Cabbage` (AVFoundation-based, same staleness).
VideoLab's `RenderLayer` / `RenderComposition` split is a genuinely good decomposition and our
`RenderPlan` owes it a debt. Taking the *design* and leaving the *dependency* is the right trade
for two abandoned repos.

### Preview video decode

Two ways to put a *playing* video clip in a Metal preview: `AVAssetReader` re-created on every
seek (fast forward, painful when scrubbing — every scrub tick decodes from the last keyframe),
or a muted `AVPlayer` + `AVPlayerItemVideoOutput` per asset (Apple's own decode, seek and rate
machinery; `copyPixelBuffer(forItemTime:)` hands back an IOSurface-backed buffer that
`CVMetalTextureCache` wraps with no copy). The player approach was chosen for preview; the
reader for export, where access is strictly forward. Orientation is *not* baked in by a video
composition (which would decode at full render size) but applied in the vertex shader from the
track's `preferredTransform` — cheaper, and it lets the decoder downscale on the way out.

### Text rendering

`AVVideoCompositionCoreAnimationTool` is the framework-blessed path and it is a minefield:
documented HDR colour corruption on export, a regression where overlay layers do not appear for
the first ~1 s, and quality loss on composited overlays. It is also export-only, so it cannot
be the preview path — reintroducing the divergence problem we just designed out.

**Decision: rasterise text ourselves with Core Text into an `MTLTexture`, cached by
`(string, style, pixelSize)`.** Word-level rasterisation, so word-by-word reveal — the dominant
Reel typography motion — falls out for free.

---

## 4. Analysis — what actually runs on an iPhone

Verified as present in the OS, free, and Neural-Engine-backed:

| Capability | API | Since | Used for |
|---|---|---|---|
| OCR | `VNRecognizeTextRequest` | iOS 13 | Text slot extraction |
| Optical flow | `VNGenerateOpticalFlowRequest` | iOS 14 | Camera-move estimation |
| Translational registration | `VNTranslationalImageRegistrationRequest` → `VNImageTranslationAlignmentObservation.alignmentTransform` | iOS 11 | Cheap pan pre-pass |
| Homographic registration | `VNHomographicImageRegistrationRequest` | iOS 11 | Zoom/rotation cross-check |
| Image embeddings | `VNGenerateImageFeaturePrintRequest` → `computeDistance(_:to:)` | iOS 13 | Visual similarity, dedup |
| Saliency | `VNGenerateAttentionBasedSaliencyImageRequest` / `…ObjectnessBased…` | iOS 13 (A12+) | Shot-scale classification, safe crop |
| Aesthetics | `VNCalculateImageAestheticsScoresRequest` → `overallScore`, `isUtility` | iOS 18 | Hero-shot ranking; screenshot rejection |
| Speech | `SpeechAnalyzer` / `SpeechTranscriber` / `SpeechDetector` | iOS 26 | Voiceover presence + transcript |
| On-device LLM | `FoundationModels` (~3 B, `@Generable`) | iOS 26 | **Optional** copy suggestions |

Two things this table quietly settles:

- **`isUtility` is a gift.** It is a built-in "this is a screenshot or a receipt, not a
  photo you'd share" classifier. Auto Arrange gets screenshot rejection for free, with no model
  and no training data.
- **Feature prints make MobileCLIP unnecessary.** `VNGenerateImageFeaturePrintRequest` gives a
  robust embedding with zero app-size cost and zero licence questions.

### On MobileCLIP — VERIFY REQUIRED, and routed around

Apple's `ml-mobileclip` ships Core ML exports and is genuinely good. But the weights carry
`apple-ascl` (Apple Sample Code Licence) with a separate `LICENSE_weights_data` file, and
**I could not retrieve that file's text** — both the GitHub blob URL and the raw URL returned
404 during research. Apple's sample-code terms are not obviously a general-purpose
redistribution licence for shipped model weights.

Rather than guess (§6 of the brief is explicit: *if licence status is unclear, STOP*), the
design **does not use MobileCLIP**. Vision feature prints cover the requirement. MobileCLIP is
recorded as a possible future upgrade *conditional on someone reading that licence file*.

### On YOLO — a licence trap worth naming

Ultralytics YOLOv8/YOLO11/YOLO26 are **AGPL-3.0** or a paid Enterprise licence. AGPL is
stricter than GPL and reaches network deployments. Any tutorial that says "just export YOLO to
Core ML" is handing you an AGPL obligation. MIT/Apache alternatives exist (LibreYOLO, YOLOX,
RF-DETR).

**We need none of them.** Saliency plus aesthetics answers "where is the subject and how tight
is the shot", which is the only object-level question the product actually asks.

### Beat detection — deterministic, as the brief requested

The obvious libraries are licence-hostile (`aubio` is GPL, `essentia` is AGPL) or Python-only
(`librosa`). The algorithm, however, is textbook and short:

```
decode → mono 22 050 Hz → STFT (1024 win / 512 hop, Hann, vDSP)
       → log-magnitude → spectral flux (positive differences)
       → adaptive-mean normalisation → onset envelope
       → autocorrelation over 60–200 BPM, octave-corrected → tempo
       → comb-filter phase search → beat grid → snap to local onset peaks
```

Every step is `Accelerate`. No model, no licence, no download, fully reproducible run to run.
Implemented in `Analysis/AudioAnalyzer.swift`.

### Scene detection

PySceneDetect's `ContentDetector` is the well-proven design: convert to HSV, take a weighted
mean absolute delta across H, S and V between adjacent frames, cut when it exceeds a threshold.
`AdaptiveDetector` improves it by making the threshold a rolling average of neighbouring frame
deltas, which suppresses false positives during fast camera motion.

We reimplement `AdaptiveDetector`'s logic in Swift over `Accelerate` — the algorithm is public
and simple; the Python package is not a dependency we can or should take.

Gradual transitions get a separate pass, because cuts and dissolves need different detectors.
The literature is consistent that abrupt cuts are easy and gradual transitions are hard. We use
the classic **linear-blend residual test**: over a candidate run `[t₀, t₁]`, a true dissolve
satisfies `F(t) ≈ (1−α)·F(t₀) + α·F(t₁)` with `α = (t−t₀)/(t₁−t₀)`. Low residual plus elevated
frame delta ⇒ dissolve. Collapsing luma variance toward a flat frame ⇒ fade. Anything elevated
that fits neither is reported as `.unknown` with low confidence and falls back to a cut.

---

## 5. Client architecture

| Option | Verdict |
|---|---|
| **A. Native SwiftUI + Apple frameworks** | **Chosen** |
| B. React Native | Rejected |
| C. Flutter | Rejected |
| D. OpenCut-derived | Rejected (§1) |
| E. Rust core + native UI | Rejected |
| F. Something else | Nothing better found |

**Why A.** Every capability this product is *made of* — Vision, VideoToolbox, Metal,
AVAssetWriter, PhotosUI, Core Text — is a first-party Apple API. Any cross-platform runtime
becomes a bridge layer between our code and the frameworks doing all the work, which is pure
cost. There is no second platform to amortise that cost against: the brief says iPhone, and only
iPhone.

**Why not React Native.** Timeline scrubbing is the single most latency-sensitive interaction in
a video editor and RN's known weak spots are precisely heavy animation, large frequently-updating
lists, and work landing on the JS thread — benchmarks put Fabric around 51 FPS on complex UI
against Flutter's 58–60, with dropped-frame rates in the teens on iOS during complex interaction.
Every frame of video would cross the bridge. Wrong tool.

**Why not Flutter.** Genuinely fast — Impeller pre-compiles shaders and sustains 60–120 FPS —
and if this were a cross-platform product it would be a real contender. But it renders through
its own engine, so our Metal textures must be handed across a platform-channel boundary to a
foreign compositor, and every Vision/AVFoundation call becomes hand-written FFI. We would pay
the full cost of a cross-platform framework for exactly one platform.

**Why not Rust core + native UI.** Rust would earn its keep for a portable codec or compositor.
Ours is neither: the compositor *is* Metal and the analysis *is* Vision, both Apple-only. A Rust
core would be a C ABI wrapped around Swift calls back into Objective-C frameworks. Pure overhead,
plus a second toolchain, plus `swift test` no longer covering the engine.

**Why not "SwiftUI everywhere, no exceptions".** Two places take UIKit deliberately: the
timeline (a `UIScrollView` with a custom pinch-zoom time base — SwiftUI's gesture composition is
not precise enough here, and community consensus is that intricate scrubbing widgets remain
UIKit's territory) and the Metal preview (`MTKView` in a `UIViewRepresentable`). Everything else
is SwiftUI.

**Deployment target: iOS 26.0.** As of June 2026, 79% of compatible iPhones run iOS 26 (86% of
phones released in the last four years). For a personal app that is a non-issue, and it buys
`SpeechAnalyzer` and `FoundationModels` without a second code path. The target lives in one
constant should it ever need lowering; `FoundationModels` is already behind an availability
check because Apple Intelligence is per-device, not per-OS.

**Storage: SwiftData for the project index, JSON for the documents.** SwiftData is reported
production-solid as of iOS 26 with model inheritance and the iOS 18.x bugs fixed, and our scale
(tens of projects) is nowhere near its known weak spots — 50k+ record batches, 30+ entity
schemas, shared CloudKit. But `EditRecipe` and `Timeline` are *documents*: versioned,
diffable, exportable, and the subject of an undo stack. Those want to be Codable value types in
a file, not managed objects. So: SwiftData holds project metadata and thumbnails, a
`.reframeproj` package holds the JSON documents plus asset *references* — never asset copies.

---

## 6. Reference acquisition — what is legitimate

YouTube's Terms of Service explicitly forbid accessing content by any means other than the
playback pages, embedded player, or explicitly authorised means. Instagram's terms likewise
forbid downloading others' content without consent. Violating a ToS is a contract matter, not a
crime — but App Review Guideline 5.2.1/5.2.3 requires documented rights for apps that download
audio/video, and there is no plausible documentation for arbitrary third-party Reels.

**Decision: no URL import. No scraping. No `yt-dlp`. No hidden `WKWebView` extraction.**

The engine takes an `AVAsset`. It has no opinion about provenance, and it is architecturally
incapable of acquiring one — there is no networking code in `ReframeKit` at all. Supported
intake:

- Photos library (`PhotosPicker`)
- Files / iCloud Drive (`fileImporter`, security-scoped)
- AirDrop, and Share Sheet → Reframe for *file* payloads
- The user's own screen recording of a reference

A note on the Share Sheet: sharing a Reel from Instagram yields a **link**, not a video file.
The app handles a shared URL by explaining that plainly and offering the screen-recording route,
rather than pretending and failing. This is the honest UX, and it happens to be the compliant one.

---

## 7. Summary of decisions

| Question | Answer | Because |
|---|---|---|
| Client | Native SwiftUI, iOS 26+ | Every capability is a first-party API |
| Rendering | Own Metal graph + AVAssetWriter | Preview/export parity by construction; stills are first-class |
| Video I/O | AVFoundation / VideoToolbox | Hardware, patent-cleared, installed |
| FFmpeg | Excluded | Dead iOS binding, LGPL≈GPL on iOS, patent exposure |
| OpenCut | Inspiration only | Mid-rewrite, no iOS target, closed to contribution |
| Remotion | Rejected | Chromium in an iOS app |
| Scene detection | Own `AdaptiveDetector` + dissolve residual test | Proven algorithm, no dependency |
| Beat detection | Own spectral flux + autocorrelation via vDSP | Deterministic; libraries are GPL/AGPL |
| Embeddings | Vision feature print | Free, installed, no licence question |
| OCR | Vision | Free, installed, on-device |
| Speech | `SpeechAnalyzer` (iOS 26) | Installed; no model download UX |
| Object detection | None | Saliency + aesthetics answers the real question; YOLO is AGPL |
| MobileCLIP | Excluded | **VERIFY REQUIRED** — weights licence unreadable |
| LLM | `FoundationModels`, optional | Free, on-device, and the app is fully functional without it |
| Storage | SwiftData index + JSON documents | Documents want to be Codable values |
