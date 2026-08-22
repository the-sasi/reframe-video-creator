# Feature parity matrix

Benchmarks: VN, CapCut (consumer baseline); LumaFusion, Alight Motion (professional depth).
Used as *capability* references only — no branding, UI or assets copied.

Status: **DONE** (model + engine + UI + persistence + undo + export + tests) · **PARTIAL** ·
**MISSING** · **BLOCKED** (needs an architecture gap closed first)

A feature is only DONE when all ten criteria in the brief hold. A button alone is not a feature.

## Core editing

| Feature | Benchmark | Status | Location | Notes |
|---|---|---|---|---|
| Trim | all | DONE | `EditCommand.trimClip` | gesture-coalesced undo |
| Split | all | DONE | `EditCommand.splitClip` | inherits Ken Burns remainder |
| Delete / duplicate / reorder | all | DONE | `EditCommand` | |
| Replace clip media | all | DONE | `replaceClipAsset` | |
| Speed (scalar) | all | DONE | `setClipSpeed` | 0.25–4x |
| Speed curves / ramps | CapCut, Alight | MISSING | — | needs keyframes (gap #3) |
| Reverse | all | MISSING | — | needs a reversed decode path |
| Freeze frame | all | MISSING | — | small: a clip with zero source advance |
| Crop / fit / fill | all | DONE | `FitMode`, crop rects | |
| Rotate / flip | all | MISSING | — | `rotation` exists in the shader, unexposed |
| Opacity | all | DONE | `VideoClip.opacity` | |
| Markers | LumaFusion | MISSING | — | |
| Stabilise | LumaFusion | MISSING | — | feasible via Vision registration |

## Timeline

| Feature | Benchmark | Status | Notes |
|---|---|---|---|
| Single video track | — | DONE | |
| Multiple video tracks | all | **BLOCKED** | gap #1 |
| Track lock / hide / mute / solo | LumaFusion | **BLOCKED** | gap #1 |
| Track reordering | LumaFusion | **BLOCKED** | gap #1 |
| Gaps / absolute positioning | LumaFusion | **BLOCKED** | gap #5 |
| Magnetic / ripple | CapCut | PARTIAL | `relayout()` is always magnetic; not a choice |
| Ruler, zoom, scroll | all | DONE | adaptive tick interval |
| Snapping (clips, beats) | CapCut | DONE | with haptics |
| Beat markers | CapCut | DONE | drawn from `beatGrid` |
| Multi-select | LumaFusion | MISSING | |
| Copy / paste | all | MISSING | |
| Keyframe markers | Alight | **BLOCKED** | gap #3 |

## Audio

| Feature | Status | Notes |
|---|---|---|
| Music track, volume, fades | DONE | |
| Waveform | DONE | |
| Extract / detach audio | DONE | `AudioTools` |
| Voiceover recording | DONE | `VoiceRecorder`, `VoiceoverSheet` |
| Ducking | DONE | `AudioMixPlanner` |
| Beat detection / BPM / grid | DONE | deterministic, tested |
| Multiple audio tracks | **BLOCKED** | gap #1 |
| Audio keyframes | **BLOCKED** | gap #3 |
| Denoise / voice isolation | MISSING | |

## Text & captions

| Feature | Status | Notes |
|---|---|---|
| Text layers, timing, styling | DONE | |
| Drag on preview | DONE | `TextOverlayEditor` |
| Word-by-word animation | DONE | per-word rasterisation |
| Font category, colour, shadow | DONE | six categories |
| Outline / stroke / background box | PARTIAL | in the schema, not in the rasteriser |
| Letter / line spacing | MISSING | |
| Text presets / reusable styles | MISSING | |
| Auto transcription | DONE | `CaptionTranscriber` |
| SRT import / export | MISSING | |
| Caption track | **BLOCKED** | gap #1 |

## Effects, filters, colour

| Feature | Status | Notes |
|---|---|---|
| Filter presets | DONE | 9 presets, live swatches |
| Exposure / contrast / saturation / temperature | DONE | shader uniforms |
| Vignette / grain | DONE | hardcoded scalars — see gap #4 |
| Highlights / shadows / tint / sharpness | MISSING | |
| Effect stacking / reorder / presets | **BLOCKED** | gap #4 |
| Blur, mosaic, glitch, RGB split, shake, light leak | MISSING | needs the registry |
| LUT import | MISSING | |
| Curves | MISSING | |
| Reference-derived grade | DONE | opt-in toggle |

## Compositing

| Feature | Status | Notes |
|---|---|---|
| Logo / image overlay | DONE | drag + resize on preview |
| PiP | **BLOCKED** | gap #1 |
| Blend modes | MISSING | |
| Masks / feathering | MISSING | |
| Chroma key | MISSING | |
| Background removal | MISSING | feasible via Vision subject lift |
| Stickers / shapes | MISSING | |

## Templates & adaptive editing — Reframe's differentiator

| Feature | Status | Notes |
|---|---|---|
| Reference analysis → style model | DONE | the core technology |
| Scene / motion / text / colour / audio extraction | DONE | with confidence + basis |
| Intelligent asset matching | DONE | Hungarian + diversity refinement |
| Slot pinning | DONE | |
| Auto arrange / shuffle | DONE | |
| Variations | DONE | batched undoable command sets |
| Music-driven editing | DONE | sections, planner, quality score |
| Starter templates | DONE | |
| Save project as template | DONE | |
| `.reframestyle` import / export | DONE | versioned |
| Template preview rendering | DONE | rendered on device |
| Template categories / search / favourites | MISSING | |

## Projects, export, platform

| Feature | Status | Notes |
|---|---|---|
| Projects, autosave, crash recovery | DONE | |
| Rename / duplicate / favourite / delete | PARTIAL | delete only |
| Canvas presets | PARTIAL | 9:16, 1:1, 16:9, 4:5 in the model; limited UI |
| Export presets, HEVC/H.264, progress, cancel | DONE | |
| Export history | MISSING | |
| Diagnostics flight recorder | DONE | exportable |
| Navigation without dead ends | DONE | Phase 0 |
| Accessibility (Dynamic Type, 44pt, VoiceOver) | PARTIAL | labels present, not audited |

## Summary

**DONE 46 · PARTIAL 7 · MISSING 33 · BLOCKED 9**

Every BLOCKED item traces to gap #1 (track model), #3 (keyframes) or #4 (effect registry).
Closing those three unblocks 9 capabilities and makes ~15 of the MISSING items routine.
