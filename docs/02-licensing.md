# 02 — Dependency & licence analysis

**The shipping app has zero third-party runtime dependencies.** Everything it links is an Apple
framework already present on the device. This was a design goal, not an accident: it eliminates
the GPL/AGPL surface, the codec-patent surface, the supply-chain surface, and the "this package
was archived last year" surface all at once.

---

## Runtime dependencies

| Dependency | Purpose | Licence | iOS compatible | Cost | Decision |
|---|---|---|---|---|---|
| AVFoundation | Decode, audio, asset writing | Apple SDK (Xcode EULA) | ✅ Built in | $0 | **Use** |
| VideoToolbox | HW H.264/HEVC encode & decode | Apple SDK | ✅ Built in | $0 | **Use** (via AVAssetWriter) |
| Metal / MetalKit | Compositing, transitions, effects | Apple SDK | ✅ Built in | $0 | **Use** |
| MetalPerformanceShaders | Gaussian blur for transitions | Apple SDK | ✅ Built in | $0 | **Use** |
| Vision | OCR, saliency, aesthetics, flow, embeddings | Apple SDK | ✅ Built in | $0 | **Use** |
| Accelerate (vDSP / vImage) | FFT, HSV conversion, resampling | Apple SDK | ✅ Built in | $0 | **Use** |
| Core Text | Text rasterisation to texture | Apple SDK | ✅ Built in | $0 | **Use** |
| ImageIO / Core Graphics | Thumbnails, colour sampling, PNG posters | Apple SDK | ✅ Built in | $0 | **Use** |
| PhotosUI / Photos | Import and save-to-Photos | Apple SDK | ✅ Built in | $0 | **Use** |
| SwiftData | Project index | Apple SDK | ✅ Built in | $0 | **Not used** — the index is rebuilt by scanning `Projects/` (see 01); a second store was overhead for tens of documents |
| Speech (`SpeechAnalyzer` / `SpeechTranscriber`) | Captions from voiceover or reference audio | Apple SDK | ✅ iOS 26+ | $0 | **Use, optional** — behind an availability check; language assets are downloaded *by the system from Apple* on request (the one network activity besides iCloud Photos, and it is opt-in). Speech *presence* during analysis is still answered deterministically |
| AVAudioRecorder / AVAudioSession | Voiceover recording | Apple SDK | ✅ Built in | $0 | **Use** |
| System fonts (SF, Helvetica Neue, Avenir Next, Futura, Georgia, Baskerville, Didot, American Typewriter, Snell Roundhand, Marker Felt, Noteworthy, Chalkduster, Menlo, Courier New, Copperplate) | Text layers | Bundled with iOS; rendering with system fonts inside an app is permitted by the OS licence | ✅ | $0 | **Use** — nothing is embedded or downloaded; `TextFont.all` lists only faces present on every supported iPhone |
| FoundationModels | Copy suggestions | Apple SDK | ✅ iOS 26+, Apple Intelligence devices | $0 | **Use**, optional, absent-tolerant |
| Swift stdlib / Foundation | — | Apache 2.0 w/ Runtime Library Exception | ✅ | $0 | **Use** |

Total third-party runtime code: **none**.

---

## Evaluated and rejected

| Candidate | Purpose considered for | Licence | iOS compatible | Cost | Decision & reason |
|---|---|---|---|---|---|
| FFmpeg (libav*) | Decode/encode/filters | LGPL-2.1+, GPL if certain codecs enabled | ⚠️ Buildable, but **LGPL is unsatisfiable on iOS** | $0 + **patent exposure** | **Reject** — cannot honour the relink clause; H.264 patents administered separately by Via Licensing |
| `ffmpeg-kit` | FFmpeg iOS binding | LGPL/GPL | ❌ **Archived 2025-06-23**, binaries pulled 2025-01-06 | $0 | **Reject** — dead; CocoaPods fetch fails |
| OpenCut | Editor architecture / Rust core | MIT | ❌ No iOS target | $0 | **Reject as dependency**, use as inspiration — mid-rewrite, closed to contributions |
| OpenCut Classic | Editor architecture | MIT | ❌ Web only | $0 | **Reject** — frozen predecessor |
| Remotion | Composition engine | Free ≤3 employees, paid beyond | ❌ Needs Chromium | $0 for us | **Reject** — browser engine in an iOS app is untenable |
| OpenAI Whisper | Transcription | MIT | ❌ Python/PyTorch | $0 | **Reject** — not the iOS artefact |
| WhisperKit / `argmax-oss-swift` | Transcription | MIT | ✅ Excellent | $0 | **Reject (keep as fallback)** — `SpeechAnalyzer` is already installed; avoids a model-download step |
| MobileCLIP | Image embeddings | Code `apple-ascl`; **weights licence unreadable** | ✅ Core ML exports exist | $0 | **Reject — VERIFY REQUIRED**, see below |
| Ultralytics YOLO (v8/11/26) | Object detection | **AGPL-3.0** or paid Enterprise | ✅ Core ML export | $0 only under AGPL | **Reject** — AGPL is viral and reaches network use |
| LibreYOLO / YOLOX / RF-DETR | Object detection | MIT / Apache-2.0 | ✅ | $0 | **Reject as unnecessary** — saliency + aesthetics already answers the product question |
| `aubio` | Beat detection | **GPL-3.0** | ✅ | $0 under GPL | **Reject** — viral |
| `essentia` | Beat/tempo analysis | **AGPL-3.0** | ⚠️ Heavy | $0 under AGPL | **Reject** — viral |
| `librosa` | Beat detection | ISC | ❌ Python | $0 | **Reject** — wrong runtime; algorithms reimplemented instead |
| PySceneDetect | Scene detection | BSD-3-Clause | ❌ Python | $0 | **Reject as dependency**, reimplement algorithm (BSD would have been fine; the runtime is not) |
| OpenCV | Classical CV | Apache-2.0 | ✅ ~40 MB+ binary | $0 | **Reject** — Vision + Accelerate cover every use; not worth the binary |
| MediaPipe | Vision pipelines | Apache-2.0 | ✅ | $0 | **Reject** — overlaps Vision, adds TFLite runtime |
| VideoLab | iOS render framework | MIT | ✅ iOS 11+ | $0 | **Reject as dependency**, credit as design influence — ~20 commits, unmaintained |
| Cabbage | iOS composition framework | MIT | ✅ | $0 | **Reject** — unmaintained; built on the `AVVideoCompositing` path we rejected |
| PixelSDK | Commercial editor SDK | Proprietary, paid | ✅ | 💲 | **Reject** — violates the zero-cost requirement |

### The MobileCLIP finding, stated precisely

The code in `apple/ml-mobileclip` is under an Apple licence identified as `apple-ascl`. The
weights and data carry a **separate** `LICENSE_weights_data` file. During research on
2026-08-17, both `github.com/apple/ml-mobileclip/blob/main/LICENSE_weights_data` and the
corresponding `raw.githubusercontent.com` URL returned **HTTP 404**.

I therefore do not know whether those weights may be redistributed inside a shipped app.
Apple's sample-code terms are generally *not* a redistribution licence for model artefacts, but
I am not going to assert that about a file I could not read.

Per the brief's instruction — *"If license status is unclear: STOP and research it. Do not
guess."* — MobileCLIP is **excluded from the design**, not deferred to a runtime flag. Vision's
`VNGenerateImageFeaturePrintRequest` provides the same capability with no licence question and
no app-size cost. Should someone later read that licence file and find it permissive, MobileCLIP
would be a drop-in behind `AssetFeatureExtractor` — but nothing depends on that happening.

---

## Development-time tools (not shipped, not linked)

| Tool | Purpose | Licence | Decision |
|---|---|---|---|
| Xcode 26 / Swift 6 | Build | Apple EULA | Required |
| XcodeGen | Regenerate `.xcodeproj` if needed | MIT | Optional convenience |
| swift-format | Style | Apache-2.0 | Optional |

---

## Content licensing — the part that is about the user, not the code

The engineering decisions above are worthless if the product encourages infringement, so the
design enforces §39 of the brief structurally rather than by warning text:

1. **No frame of the reference reaches the output.** The renderer's frame providers are bound to
   the user's `AssetPool`. The reference `AVAsset` is released the moment analysis completes and
   is not retained in the project package. There is no code path by which reference pixels can
   be composited.
2. **OCR'd text is a hint, never content.** `TextSlotTemplate.sampleText` is displayed to the
   user as *"reference said: …"* in grey, and `RecipeBinder` will not bind it into a
   `TextLayer`. Output text comes from `UserTextInput` only. Empty slots stay empty.
3. **Watermarks and handles are actively discarded.** `TextAnalyzer.watermarkHeuristic` drops
   OCR results matching `@handle` patterns, follow/subscribe calls-to-action, and text that
   persists across essentially the whole reference in a corner — the signature of a creator
   watermark. These never become slots.
4. **Reference audio is analysed, and extracted only on an explicit tap.** `AudioAnalyzer`
   consumes samples to produce a BPM and a beat grid — a few hundred floats; the decoded buffer
   is not written to disk. Separately, the summary screen offers *Keep the reference's audio* /
   *Save audio to Files*, which run `AudioExtractor` and write an M4A into the sandbox. That is
   the user's decision, made per project, next to a sentence saying they need the rights to the
   soundtrack. Nothing is extracted by default and analysis never depends on it. The
   product-owner brief asked for this capability; keeping it opt-in and visible is the honest
   way to provide it.
5. **No watermark on export**, per §26.

The net effect: the artefact that survives analysis is a *structure* — timings, transforms,
confidences. It is much closer to "this edit is cut at 140 BPM with 12 scenes averaging 1.2 s"
than to a copy of anything.

---

## This project's own licence

MIT. It has no inherited obligations to conflict with, because it has no third-party runtime
dependencies.
