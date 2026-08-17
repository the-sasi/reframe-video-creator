# 03 — AI & model strategy

**Principle: the smallest thing that answers the actual question.** For most of this pipeline
the smallest thing is not a model at all — it is a deterministic algorithm over `Accelerate`.
That is a feature. Deterministic beats stochastic for an editor: the same reference must
produce the same recipe every time, or the undo stack and the user's mental model both break.

---

## The matrix

Rows marked **not wired up** are decided but not built — the decision is recorded so a future
change picks the right thing, not because the code exists today.

| Task | Model / library | On-device? | Size | Speed (target) | Quality | Licence | Cost |
|---|---|---|---|---|---|---|---|
| Scene-cut detection | **Own `AdaptiveContentDetector`** (HSV delta + rolling threshold) | ✅ CPU/Accelerate | 0 | ~2–4× realtime @ 256 px | High for cuts | MIT (ours) | $0 |
| Dissolve / fade detection | **Own linear-blend residual test** | ✅ CPU | 0 | Same pass | Good, confidence-scored | MIT (ours) | $0 |
| Camera motion (pan/zoom/rotate) | `VNGenerateOpticalFlowRequest` + own similarity fit | ✅ ANE/GPU | 0 | ~5–15 ms/pair @ 480 px | Good | Apple SDK | $0 |
| Motion pre-pass | `VNTranslationalImageRegistrationRequest` | ✅ | 0 | ~3 ms/pair | Translation only | Apple SDK | $0 |
| OCR | `VNRecognizeTextRequest` (`.accurate`) | ✅ ANE | 0 | ~30–80 ms/frame | High | Apple SDK | $0 |
| Text style estimation | **Own** (k-means on crop + stroke stats) | ✅ CPU | 0 | <5 ms | Category-level only | MIT (ours) | $0 |
| Shot scale / subject | `VNGenerateAttentionBasedSaliencyImageRequest` | ✅ ANE (A12+) | 0 | ~10 ms | Good | Apple SDK | $0 |
| Object regions | `VNGenerateObjectnessBasedSaliencyImageRequest` | ✅ ANE | 0 | ~10 ms | Good | Apple SDK | $0 |
| Photo quality ranking | `VNCalculateImageAestheticsScoresRequest` | ✅ | 0 | ~15 ms | Good | Apple SDK | $0 |
| Screenshot rejection | Same request's `isUtility` | ✅ | 0 | free | **Excellent** | Apple SDK | $0 |
| Visual similarity / dedup | `VNGenerateImageFeaturePrintRequest` | ✅ ANE | 0 | ~10 ms | Good | Apple SDK | $0 |
| Dominant colour / grade | **Own k-means over downsampled frames** | ✅ CPU | 0 | <20 ms/scene | Good | MIT (ours) | $0 |
| Beat / BPM | **Own spectral flux + autocorrelation (vDSP)** | ✅ CPU | 0 | ~20× realtime | Good on 4/4 music | MIT (ours) | $0 |
| Speech presence | **Own band-ratio + syllabic-modulation heuristic** | ✅ CPU | 0 | free (reuses the STFT) | Moderate — reported at ~0.7 | MIT (ours) | $0 |
| Transcription | `SpeechTranscriber` (iOS 26) | ✅ | 0 (system assets) | faster than realtime | High | Apple SDK | $0 — **not wired up** |
| Copy suggestions | `FoundationModels` ~3 B | ✅ ANE | 0 (system) | ~1–3 s | Good | Apple SDK | $0 |
| Object detection | ✗ **not used** | — | — | — | — | — | — |
| Generative video | ✗ **not used** | — | — | — | — | — | — |

Every row is $0, on-device, and offline. There is no row that needs a key.

---

## Why so little ML

The product's questions turned out to be mostly *geometric and temporal*, not semantic:

- "Where is the cut?" → a pixel-difference threshold, not a model.
- "Did the camera push in?" → fit a similarity transform to an optical-flow field.
- "Is this a close-up or a wide?" → the fraction of frame area the salient region occupies.
- "Which photo is the hero?" → aesthetics score, ranked.
- "Where are the beats?" → autocorrelation of an onset envelope.
- "Is someone talking?" → energy in the speech band plus a syllabic-rate modulation check.

A vision-language model could answer all of these in prose, more slowly, less precisely, and
non-deterministically. Reaching for a VLM here would be reaching for the wrong instrument.

The one place semantics genuinely help is **naming and copy** — "detail shot of petals" reads
better than "scene 4, tight framing, low motion", and suggesting three CTA phrasings is a real
convenience. That is exactly where `FoundationModels` sits, and exactly why it is optional.

---

## The provider abstraction (§36)

```swift
public protocol IntelligenceProvider: Sendable {
    var identifier: String { get }
    var isAvailable: Bool { get async }
    func describeSlot(_ context: SlotContext) async -> Confident<String>
    func suggestCopy(_ context: CopyContext) async -> [String]
    func refineSceneRoles(_ context: RoleContext) async -> [SceneRole]?
}
```

Three implementations ship:

| Provider | Availability | Behaviour |
|---|---|---|
| `HeuristicProvider` | **Always** | Deterministic templated descriptions, rule-based roles. The baseline. |
| `AppleOnDeviceProvider` | iOS 26 + Apple Intelligence enabled | `FoundationModels` with `@Generable` guided generation. |
| *(no cloud provider)* | — | The protocol permits one. None is implemented, and none is required. |

Resolution order is `AppleOnDeviceProvider` → `HeuristicProvider`, and **every method has a
total heuristic fallback**. `refineSceneRoles` returns `[SceneRole]?`; `nil` means "keep what
the heuristics decided". A missing, disabled, throttled or context-exhausted model is not an
error path — it is the normal path on most devices.

Practical constraint worth designing around: the on-device model's context window is **4,096
tokens per session**, fixed, covering prompt *and* response. iOS 26.4 added `contextSize` and
`tokenCount(for:)` to measure it. `AppleOnDeviceProvider` therefore uses one short-lived session
per slot rather than one long session for a whole recipe, and truncates aggressively. Exceeding
the window throws `exceededContextWindowSize` and poisons the session — so we never accumulate
one.

---

## Confidence, and refusing to overclaim (§38)

Every inferred property is wrapped:

```swift
public struct Confident<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value
    public var confidence: Double   // 0…1
    public var basis: String        // "optical-flow similarity fit, residual 0.04, n=7"
}
```

`basis` is not decoration. It is what makes a wrong result debuggable six months later, and it
is what the "Why?" affordance in the analysis UI shows.

Confidence bands drive behaviour, not just display:

| Band | UI | Binder behaviour |
|---|---|---|
| ≥ 0.80 | Stated plainly | Applied |
| 0.55–0.79 | Badged **Guessed** | Applied |
| 0.30–0.54 | Badged **Guessed**, offered for review | **Fallback substituted**; original kept in `alternatives` |
| < 0.30 | Hidden from summary | Discarded; safe default used |

Fallback ladders (§37) are declared in `TransitionTemplate.safeFallback` and
`CameraMove.safeFallback`. A whip-pan we are 40% sure about becomes a cut, not a broken whip-pan.
The generation never fails because of low confidence — that is the whole point of having it.

---

## What we deliberately did not build

- **Generative video / image animation.** The brief says optional; the honest position is that
  no free, on-device, offline image-to-video model exists that would run acceptably on an iPhone
  today. Shipping it would mean a paid API, which is the one thing forbidden. The `EffectTemplate`
  enum has room for it. It stays empty.
- **Font identification.** Not solvable from a 1080p frame. We classify into six categories and
  say so.
- **Music generation / stem separation.** Out of scope, and the licence-clean options are poor.
- **Any telemetry-fed model.** No telemetry exists to feed one.
