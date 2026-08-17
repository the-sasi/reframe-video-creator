# 05 — Rendering architecture

## Decision matrix

Weighted against the brief's stated priorities (speed, reliability, battery, memory, quality,
offline, licensing, iOS compatibility). Scores 1–5, higher is better.

| | AVFoundation `AVVideoCompositing` | **Own Metal graph + AVAssetWriter** | FFmpeg filtergraph | Remotion (Chromium) | Rust core + Metal FFI |
|---|---|---|---|---|---|
| Speed (export) | 4 | **5** | 3 | 1 | 5 |
| Speed (preview) | 3 | **5** | 1 | 1 | 5 |
| Reliability | 3 — documented HDR & overlay defects | **5** | 3 | 2 | 4 |
| Preview/export parity | 2 — two pipelines | **5** — one function | 1 | 2 | 5 |
| Still-image timelines | 2 — needs dummy track | **5** | 4 | 5 | 5 |
| Battery / thermals | 4 | **5** | 2 | 1 | 5 |
| Memory control | 3 | **5** | 2 | 1 | 5 |
| Output quality | 5 | **5** | 5 | 3 | 5 |
| Offline | 5 | **5** | 5 | 5 | 5 |
| Licensing | 5 | **5** | 1 — LGPL≈GPL on iOS + patents | 4 | 5 |
| iOS compatibility | 5 | **5** | 2 — binding archived | 1 | 4 |
| Implementation cost | **5** | 2 | 3 | 4 | 1 |
| Maintenance burden | **4** | 3 | 2 | 2 | 1 |
| **Weighted total** | 3.6 | **4.6** | 2.3 | 2.0 | 4.1 |

Own Metal graph wins on everything except implementation cost, and the Rust variant scores well
only because Metal is doing the work in both — Rust adds a toolchain and an FFI boundary for no
capability we lack. Full argument in [00 §3](00-research.md#3--rendering--the-load-bearing-decision).

---

## The graph

```
RenderPlan ─────────────────────────────────────────────────────────────┐
  layers: [PlanLayer]                                                   │
  transition: (from: RenderPlan, to: RenderPlan, progress, kind)?       │
                                                                        ▼
                                              ┌──────────────────────────────────┐
  Layer pass    per layer, back to front  ──▶ │ MTLRenderCommandEncoder          │
    quad + texture + transform + opacity      │ vertex: transform → clip space   │
    + grade uniforms                          │ fragment: sample, grade, blend   │
                                              └──────────────┬───────────────────┘
                                                             ▼
  Transition pass    only when two scenes overlap            │
    render A → texA, B → texB, then one full-screen  ────────┤
    draw with the transition shader                          ▼
                                                     output MTLTexture
                                                             │
                                         ┌───────────────────┴───────────────┐
                                         ▼                                   ▼
                                   MTKView (preview)          CVPixelBuffer → AVAssetWriter
```

Everything is a textured quad with a 3×3 transform. Images, video frames, text and the logo all
take the same path — there is one vertex shader and one fragment shader for content, plus one
fragment shader per transition. That uniformity is why adding an effect is a shader and a case,
not a subsystem.

### Transitions

Rendered as a mix of two fully-composited sub-scenes, never as a special case inside a layer.
`cut` is the degenerate zero-duration case, which keeps the code path uniform.

| Kind | Implementation |
|---|---|
| `cut` | Hard switch at the boundary |
| `dissolve` | `mix(a, b, t)` |
| `fadeToBlack` / `fadeToWhite` | Two-phase mix through a constant |
| `slide` (4 directions) | UV offset on both, opposing |
| `push` (4 directions) | UV offset on incoming only |
| `zoomIn` / `zoomOut` | UV scale about centre + mix |
| `whip` | Directional blur proportional to `sin(πt)` + mix |
| `blur` | MPS Gaussian on both, radius `sin(πt)` + mix |

`whip` and `blur` are the only ones needing a compute pass (MPS), and both degrade to `dissolve`
if the MPS kernel is unavailable.

### Text

Core Text → `CGContext` → `CGImage` → `MTLTexture`, cached by `(string, style, pixelSize)` in an
`NSCache`. **Rasterised per word**, not per line, so `wordByWord` entry — the dominant Reel
typography motion — is a per-quad delay rather than a special renderer.

Deliberately *not* `AVVideoCompositionCoreAnimationTool`: it corrupts colour on HDR export, has a
regression where overlays are absent for ~1 s, degrades overlay sharpness, and is export-only —
which would reintroduce preview/export divergence.

### Colour grading

Per-layer uniforms (`exposure`, `contrast`, `saturation`, `temperature`) applied in the fragment
shader. No LUT textures in v1 — four scalars cover what `ColorAnalyzer` can honestly infer.
Working space is linear; conversion in and out sits at the sampler and the write.

---

## Frame providers

```swift
protocol FrameProvider: Sendable {
    func texture(for asset: ResolvedAsset, at localTime: Double) async -> MTLTexture?
}
```

| | `PreviewFrameProvider` | `ExportFrameProvider` |
|---|---|---|
| Resolution | Proxy, ≤ drawable size | Full canvas |
| Video decode | `AVAssetImageGenerator`, async, cached | `AVAssetReader`, sequential, exact |
| Cache miss | Reuse last good frame — never stall the display link | Block; correctness wins |
| Memory | Bounded LRU | One frame in flight |

The renderer cannot tell them apart, which is the point.

---

## Export

`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`, VideoToolbox-backed. Frames are pulled
on `requestMediaDataWhenReady`, so back-pressure is the encoder's, not ours — the loop cannot
run ahead and balloon memory.

| Setting | Default | Notes |
|---|---|---|
| Resolution | 1080×1920 | 720×1280 and 2160×3840 offered; 4K gated on `AVAssetExportSession`-reported capability |
| FPS | 30 | 24 / 60 available; 60 warns on long timelines |
| Codec | HEVC when supported, else H.264 | HEVC is ~40% smaller at equal quality; H.264 for maximum shareability |
| Bitrate | ~12 Mbps @ 1080p30 | Quality-first, tuned by a target-bitrate table |
| Colour | BT.709 SDR | HDR passthrough is explicitly out of scope in v1 |
| Audio | AAC 44.1 kHz stereo 128 kbps | Only when the user supplies audio |
| Watermark | **None** | §26 |

Export is resumable-safe rather than resumable: on failure the partial file is deleted and the
error offers *Retry at 720p*, which is the recovery that actually works when the cause was
thermal or memory pressure.

---

## What is deliberately absent

- **No HDR pipeline.** Doing it correctly means colour management through every shader and a
  tone-mapped preview. SDR BT.709 is correct and complete; HDR half-done is worse than absent.
- **No real-time filters on import.** Grading is a render-time uniform, so it costs nothing and
  stays non-destructive.
- **No custom codec work.** VideoToolbox through AVAssetWriter, and nothing below it.
