# Reframe

> Give it a Reel you like. Give it your photos. Get back *your* Reel, cut like the reference.

Reframe is a personal-use iOS app that watches a reference video, extracts its **editing
structure** — pacing, cuts, camera moves, transitions, text rhythm, beat alignment — into a
reusable, human-editable document called an **EditRecipe**, then rebuilds that structure using
your own photos, videos and copy.

It does not copy the reference. It copies the *edit*.

---

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Research, architecture, license & model analysis | ✅ Complete — see [`docs/`](docs/) |
| 1 | Engine: recipe schema, timeline, render graph, exporter | ✅ Implemented |
| 2 | Reference analysis: scenes, motion, text, colour, audio | ✅ Implemented |
| 3 | Recipe compilation + binding | ✅ Implemented |
| 4 | Automatic asset mapping (Hungarian + local search) | ✅ Implemented |
| 5 | App UI: import → analyse → map → generate → edit → export | ✅ Implemented |
| 6 | Optional generative AI (image animation, B-roll) | ⬜ Deliberately not built |

**Partially compiled.** Authored on Windows, so the Apple-framework half has never met a
compiler. What *has* been verified, with Swift 6.3.3 on Windows:

| Target | State |
|---|---|
| `RecipeCore` — schema, `Timeline`, 24 undoable `EditCommand`s, `RecipeBinder`, `Confident<T>` | ✅ Compiles clean (~2,400 lines) |
| `MediaIO`, `Analysis`, `Mapping`, `Rendering`, `Intelligence` | ⬜ Need macOS — AVFoundation, Vision, Accelerate, Metal, Core Text |
| App target — SwiftUI, `Shaders.metal` | ⬜ Needs Xcode 26 |

The remaining ~80% is covered by [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which
builds everything on a `macos-26` runner with no signing identity required. See
[`docs/07-roadmap.md`](docs/07-roadmap.md#first-build-checklist) for the expected punch list.

---

## The one-paragraph architecture

Native **SwiftUI + Swift 6**, iOS 26+, no cross-platform runtime, no FFmpeg, no cloud, no API
keys. All analysis runs on-device through **Vision**, **AVFoundation** and **Accelerate**.
Rendering is a **hand-written Metal render graph** driving **AVAssetWriter** — one render path
shared bit-for-bit between live preview and final export. The only AI that ever leaves the
deterministic path is Apple's on-device model, and it is strictly an optional garnish that the
app runs fine without.

```
Reference video ──▶ AnalysisPipeline ──▶ ReferenceAnalysis
                                              │
                                     RecipeCompiler
                                              ▼
                                        EditRecipe          ← versioned, Codable, editable
                                              │
        Your photos ──▶ AssetMapper ──▶ RecipeBinder
                                              ▼
                                          Timeline          ← the concrete, editable document
                                              │
                                        RenderPlanner
                                              ▼
                                    MetalRenderer ─┬─▶ PreviewEngine (CADisplayLink)
                                                   └─▶ VideoExporter (AVAssetWriter) ─▶ Photos
```

Three models, each with one job:

- **`EditRecipe`** — the *style*. Abstract, asset-free, reusable across projects. "Scene 3 is a
  0.8 s close-up with a 1.0→1.18 push-in, entered on a 0.2 s dissolve, landing on beat 7."
- **`Timeline`** — the *document*. Concrete, bound to real files, what the editor mutates via
  undoable commands.
- **`RenderPlan`** — the *frame*. A flat draw list for one instant in time. Pure function of
  `(Timeline, time)`, which is what makes preview and export identical.

Full rationale: [`docs/01-architecture.md`](docs/01-architecture.md).

---

## What it does not depend on

No OpenAI, Anthropic, Gemini, Runway, Veo, Vidu, Fal, Replicate, Creatomate or Shotstack.
No cloud GPU. No monthly anything. No FFmpeg (and therefore no LGPL-on-iOS or codec-patent
exposure — Apple's own H.264/HEVC licences cover VideoToolbox). No downloaded model weights in
the default configuration.

Grep the tree for `API_KEY` and you will find only the test that asserts there are none.

---

## Repository layout

```
reframe/
├── docs/                        Decision record — read 00 first
├── Reframe.xcodeproj/           Xcode 26 project (synchronized folders)
├── project.yml                  XcodeGen fallback if the .xcodeproj misbehaves
├── Reframe/                     App target — SwiftUI, no engine logic
│   ├── App/                     Entry point, routing, app-level state
│   ├── DesignSystem/            Tokens, components, haptics, motion
│   ├── Features/                One folder per screen in the primary flow
│   └── Resources/
└── Packages/ReframeKit/         The engine — pure Swift, no SwiftUI, unit-testable
    └── Sources/
        ├── RecipeCore/          Schema, timeline, commands, binding
        ├── MediaIO/             Frame streaming, thumbnails, audio decode, project store
        ├── Analysis/            Scene / motion / text / colour / audio → recipe
        ├── Mapping/             Asset feature extraction + optimal assignment
        ├── Rendering/           Metal graph, text rasteriser, exporter, preview
        └── Intelligence/        Optional provider abstraction (heuristic by default)
```

`ReframeKit` deliberately links no UI framework, so `swift test` runs the whole engine on a Mac
with no simulator and no device.

---

## Building

Requires **macOS 15.5+** and **Xcode 26** (iOS 26 SDK). A physical iPhone is strongly
recommended — Vision's saliency and aesthetics requests, and the whole Neural Engine path, are
slow or unavailable in the Simulator.

```bash
git clone <this> reframe && cd reframe
open Reframe.xcodeproj          # set your signing team on the Reframe target, then ⌘R
```

If Xcode rejects the checked-in project file, regenerate it:

```bash
brew install xcodegen && xcodegen generate && open Reframe.xcodeproj
```

Engine tests, no simulator needed:

```bash
cd Packages/ReframeKit && swift test
```

---

## Using it

1. **Create From Reference** → pick a reference from Photos or Files.
2. Watch the analysis land — scene count, pacing, detected moves, text slots, BPM. Anything the
   analyser was unsure about is labelled *Guessed*, not hidden.
3. **Use This Style** → add 5–20 of your own photos, your product name, and a CTA.
4. **Auto Arrange** assigns photos to slots by framing, subject and aesthetics; every assignment
   is visible and swappable in one tap.
5. **Generate**, then **Edit** if you want to — full timeline, trim, split, text, transitions,
   unlimited undo.
6. **Export** to Photos. No watermark, ever.

---

## Honest limitations

- **Transition naming is inference, not truth.** Cuts are detected reliably. Dissolves and fades
  are detected well. Whips, zoom-blurs and glitch transitions are *guessed* from motion energy
  and are surfaced with sub-0.6 confidence and a safe fallback.
- **Fonts are categorised, never identified.** The app tells you "bold condensed sans", because
  that is what is actually knowable from a 1080p frame. It will not claim to know the family.
- **No URL import.** Pasting an Instagram or YouTube link is not implemented, on purpose —
  see [`docs/02-licensing.md`](docs/02-licensing.md#reference-acquisition). Screen-record or
  save the reference yourself and import it; the engine never cared where the file came from.
- **Apple Intelligence is optional and mostly absent.** It writes nicer slot descriptions and
  suggests CTA phrasings on supported devices. Turn it off and nothing breaks.
- **Unverified performance.** No number in `docs/` marked *target* has been measured. The
  instrumentation to measure them is built in (`PerformanceLog`); the measuring has not happened.

---

## Licence

This project: MIT. Every third-party dependency and model has been licence-checked in
[`docs/02-licensing.md`](docs/02-licensing.md) — the short version is that the shipping app
depends on nothing but Apple's own frameworks.
