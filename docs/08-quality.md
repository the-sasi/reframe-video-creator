# 08 — Testing, performance, privacy, offline

## Testing strategy

The engine is a Swift package with no UI dependency, so most of the interesting logic is testable
with `swift test` on a Mac — no simulator, no device, no fixtures larger than a few hundred KB.

| Layer | Approach | Runs where |
|---|---|---|
| Schema | Round-trip encode/decode, migration from every prior version, golden JSON files | `swift test` |
| Determinism | Analyse a fixture twice → assert byte-identical recipe JSON | `swift test` |
| Scene detection | Synthetic clips with **known** cut frames (generated in-test, not checked in) → assert exact frame indices | `swift test` |
| Dissolve detection | Synthetic linear cross-fades of known length → assert kind and duration ±1 frame | `swift test` |
| Beat detection | Synthetic click track at known BPM + a pink-noise bed → assert BPM ±1 and phase ±20 ms | `swift test` |
| Motion analysis | Synthetically panned/zoomed frames from one still → assert recovered transform ±2% | `swift test` |
| Hungarian solver | Brute-force optimum on random 6×6 matrices → assert equality | `swift test` |
| Render planning | Pure `plan()` assertions: z-order, transition overlap, text timing | `swift test` |
| Metal rendering | Render a known plan → read back → compare to a golden PNG within tolerance | Device/simulator |
| Export | Encode 3 s, re-open with `AVAssetReader`, assert duration/fps/dimensions | Device |
| Commands | Every command: apply → revert → assert timeline equals original | `swift test` |
| Zero-cost invariant | Source grep for API-key patterns and forbidden hosts | `swift test` |

The synthetic-fixture approach matters: generating a clip with a cut at exactly frame 47 gives an
*exact* assertion, where a real video only supports "roughly there". Real videos are for manual
QA, not for the suite.

### Manual QA matrix (§46)

Run before any change to analysis or rendering is believed:

| Reference | User assets | What it proves |
|---|---|---|
| 15 s image-only Reel, 9:16, music | 10 photos | The primary use case (§40) |
| 15 s product ad, mixed cuts | 8 product photos | Hero/detail role inference (§41) |
| 30 s, 20 slots | 20 photos | Slot > asset reuse, diversity penalty (§42) |
| 60 s, mixed image/video | 10 photos + 4 clips | Video-in-slot path, A/V sync |
| 4K 60 fps reference | 10 photos | Downscale path, memory ceiling |
| Reference with no audio | 10 photos | Beat-grid absence, duration-based pacing |
| Reference with speech only | 10 photos | `SpeechDetector` true, music false |
| Reference with heavy watermark | 10 photos | Watermark rejection |
| Corrupt / truncated file | — | Error UX |
| 1 photo, 12 slots | 1 photo | Degenerate reuse without visual collapse |

---

## Performance

**Every number in this table is a target, not a measurement.** Nothing here has been run. The
instrumentation (`PerformanceLog`, signposts on every stage) is in place to check them.

| Metric | Target | Device basis |
|---|---|---|
| Cold start → Home interactive | < 400 ms | iPhone 14 |
| Import 15 s 1080p reference | < 1 s to first frame | — |
| Analysis, 15 s 1080p30 | < 8 s end-to-end | A16 |
| — scene detection | < 3 s | 256 px, ~2–4× realtime |
| — motion analysis | < 2 s | 6 sampled pairs/scene |
| — OCR | < 2 s | ~4 fps sampling |
| — audio | < 0.5 s | ~20× realtime |
| Asset feature extraction | < 150 ms/photo | Vision, ANE |
| Auto Arrange, 20 assets × 12 slots | < 100 ms | Hungarian is O(n³) at n=20 |
| Preview | sustained 30 fps, no dropped frames on scrub | — |
| Export 15 s 1080p30 | < 12 s | HEVC, VideoToolbox |
| Export 60 s 1080p30 | < 45 s | — |
| Peak memory, analysis | < 250 MB | — |
| Peak memory, export | < 400 MB | — |
| Thermal state after 60 s export | ≤ `.fair` | — |

Measurement plan: `PerformanceLog` writes `os_signpost` intervals for every stage; the benchmark
scheme runs the QA matrix and dumps a CSV. Targets get replaced with measured values, and any
that prove unreachable get revised in this file rather than quietly ignored.

### Memory tactics

Restated from [01](01-architecture.md#memory-29) because this is where the app would die:
analysis at 256 px, preview at proxy resolution, full resolution only in the encoder's hands,
one frame in flight, pooled textures, bounded pressure-aware caches. A 4K source never exists as
a decoded full-resolution buffer outside the export loop.

---

## Privacy (§45)

The strong version, which this architecture happens to make easy:

- **`ReframeKit` contains no networking code.** Not disabled — absent. There is no `URLSession`,
  no socket, no third-party SDK. A test asserts this by scanning imports.
- **The app makes zero network requests in normal operation.** No model downloads (everything is
  a system framework), no telemetry, no crash reporting, no remote config, no ads.
- **No accounts, no identifiers, no analytics.** Nothing to opt out of, because nothing collects.
- **Photos access is `.readWrite` but used narrowly**: read the assets you pick, write the file
  you export. Limited Library selection is fully supported.
- **Originals are never copied.** Assets are referenced by identifier or security-scoped bookmark.
- **The reference is released after analysis** and never enters the project package.

Settings shows a **Privacy** panel that states what is on the device and what leaves it. The
answer to the second is "nothing", and the panel says so in those words rather than in a policy.

If a cloud provider is ever added behind `IntelligenceProvider`, the requirements are already
written down: explicit per-use consent, a named model, a statement of exactly what bytes are
sent, and a global off switch that is the default.

---

## Offline (§27)

| Capability | Offline? |
|---|---|
| Import video / photos | ✅ |
| Full reference analysis | ✅ |
| Recipe compilation, asset mapping, binding | ✅ |
| Editing, trim, split, text, transitions, undo | ✅ |
| Preview | ✅ |
| Render and export | ✅ |
| Save to Photos / Files / Share | ✅ |
| Project persistence | ✅ |
| Optional `FoundationModels` copy suggestions | ✅ (on-device) |
| **Anything requiring a network** | **Does not exist** |

The app is not "offline-first". It is offline, full stop. There is no degraded mode because
there is no connected mode. Airplane mode changes nothing about how it behaves, which is the
cleanest possible answer to §27 and falls directly out of the zero-cost constraint rather than
being a separate feature.
