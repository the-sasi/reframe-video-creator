# 04 — The `EditRecipe` schema

The canonical definition is [`RecipeCore/EditRecipe.swift`](../Packages/ReframeKit/Sources/RecipeCore/EditRecipe.swift).
This document explains the shape and the reasoning; the code is the truth.

## Design requirements

| Requirement | How it is met |
|---|---|
| Editable | Every field is a `var` on a value type; the editor mutates through commands |
| Serialisable | `Codable`, stable `CodingKeys`, JSON on disk |
| Versioned | `schemaVersion` on the root, `RecipeMigrator` chain |
| Deterministic | No `Date()`, no `UUID()` during compilation — ids derive from a seeded generator |
| Reusable | Contains no asset references and no file paths, by construction |
| Debuggable | Every inference carries `confidence` **and** a `basis` string |

The determinism requirement deserves emphasis: `RecipeCompiler` takes a `seed` derived from the
source asset's fingerprint, so analysing the same file twice produces byte-identical JSON. That
turns "did my change to the motion analyser alter anything?" into a `diff`.

---

## Shape

```jsonc
{
  "schemaVersion": 1,
  "id": "8B1F…",
  "title": "Bouquet Reel · 15s",
  "createdAt": "2026-08-17T09:14:22Z",

  "source": {
    "duration": 15.36, "fps": 30.0,
    "width": 1080, "height": 1920,
    "aspect": "portrait9x16",
    "hasAudio": true,
    "fingerprint": "sha256:1f0c…"        // identifies the reference; no pixels retained
  },

  "canvas": { "width": 1080, "height": 1920, "fps": 30 },
  "duration": 15.36,

  "beatGrid": {
    "bpm": { "value": 128.0, "confidence": 0.86,
             "basis": "autocorrelation peak 0.469s, octave-checked, 41 onsets" },
    "beats": [0.21, 0.68, 1.15, 1.62],
    "downbeats": [0.21, 2.09, 3.96],
    "cutsAlignedToBeats": { "value": true, "confidence": 0.79,
                            "basis": "9/12 cuts within 80ms of a beat" }
  },

  "scenes": [
    {
      "id": "scene_01", "index": 0,
      "start": 0.0, "end": 1.18,
      "sourceKind": "image",

      "role": { "value": "opening", "confidence": 0.72,
                "basis": "index 0, duration 1.18s > median, text present" },

      "slot": {
        "id": "asset_01",
        "framing": { "value": "wide", "confidence": 0.68,
                     "basis": "salient area 0.21 of frame" },
        "motionEnergy": 0.12,
        "preferSubject": "product",
        "subjectRect": { "value": { "x": 0.31, "y": 0.22, "w": 0.38, "h": 0.41 },
                         "confidence": 0.66,
                         "basis": "salient region centred (0.50, 0.42), 16% of frame" }
      },

      "move": {
        "kind": { "value": "zoomIn", "confidence": 0.91,
                  "basis": "similarity fit scale 1.00→1.17, residual 0.031, n=6" },
        "startRect": { "x": 0.0,  "y": 0.0,  "w": 1.0,  "h": 1.0  },
        "endRect":   { "x": 0.07, "y": 0.06, "w": 0.85, "h": 0.85 },
        "easing": "easeInOut",
        "safeFallback": "none"
      },

      "transitionIn": {
        "kind": { "value": "dissolve", "confidence": 0.83,
                  "basis": "blend residual 0.019 over 7 frames" },
        "duration": 0.23,
        "direction": null,
        "safeFallback": "cut"
      },

      "effects": [],
      "grade": { "exposure": 0.03, "contrast": 1.06, "saturation": 1.12, "temperature": 0.02 }
    }
  ],

  "textSlots": [
    {
      "id": "text_title", "role": "title",
      "start": 0.30, "end": 3.10,
      "frame": { "x": 0.10, "y": 0.16, "w": 0.80, "h": 0.14 },
      "alignment": "center",
      "style": {
        "category": { "value": "displayBold", "confidence": 0.44,
                      "basis": "stroke-width variance 0.08, no serif peaks — LOW" },
        "sizeRatio": 0.062,
        "color":  "#FFFFFF",
        "shadow": { "value": true, "confidence": 0.61, "basis": "edge contrast 0.34" },
        "outline": null,
        "backgroundBox": null
      },
      "animation": {
        "entry": { "value": "wordByWord", "confidence": 0.58,
                   "basis": "3 OCR extents over 0.4s, monotonic width growth" },
        "exit":  { "value": "fadeOut", "confidence": 0.66, "basis": "alpha ramp 0.18s" }
      },
      "sampleText": "SPRING COLLECTION",   // HINT ONLY — never bound into output
      "charCountHint": 17
    }
  ],

  "audio": {
    "hasMusic": true,
    "hasSpeech": { "value": false, "confidence": 0.88, "basis": "SpeechDetector, 0 segments" },
    "energyCurve": [0.31, 0.44, 0.79],
    "suggestedCutStyle": "onBeat"
  },

  "palette": {
    "dominant": ["#E8C4CE", "#7A4E58", "#FFFFFF"],
    "meanBrightness": 0.61, "meanSaturation": 0.38, "contrast": 1.04
  },

  "stats": { "sceneCount": 12, "medianSceneDuration": 1.02,
             "cutsPerSecond": 0.78, "transitionCount": 6, "textSlotCount": 4 },

  "confidence": { "overall": 0.74, "scenes": 0.91, "motion": 0.78,
                  "text": 0.52, "audio": 0.86,
                  "weakest": "text.style.category" },

  "tags": ["Fast Reel", "Beat Sync"],   // optional; library categories
  "isBuiltIn": false                    // true only for the shipped starters
}
```

`subjectRect` is the composition record: where the reference's subject sat. The binder puts
the user's subject (from `AssetFeatures.salientRect`) at the same anchor when it solves the crop
window, so a landscape photo in a portrait slot is cropped around its subject rather than its
centre. `tags` / `isBuiltIn` are optional so recipes written before the template library existed
still decode.

---

## Notes on specific choices

**`Confident<T>` everywhere an inference happens.** Compare `"kind": "zoomIn"` with
`{"value":"zoomIn","confidence":0.91,"basis":"similarity fit scale 1.00→1.17, residual 0.031"}`.
The second one can be argued with. §8 of the brief demands exactly this and the schema takes it
seriously enough to make the honest version the *only* representable version — there is no way
to write a bare inferred value.

**`safeFallback` is part of the data, not the code.** A transition we are 40% sure is a whip-pan
carries `"safeFallback": "cut"`. The binder does not need a lookup table of what degrades to
what; the recipe says. This is what makes §37's graceful degradation a property of the document
rather than a pile of `if confidence < 0.5` scattered through the binder.

**`sampleText` is quarantined.** It exists so the UI can show *"reference said: SPRING
COLLECTION (17 chars) — yours should be about this long"*, which is genuinely useful for fitting
copy to a layout. `RecipeBinder` has no code path that reads it. See
[02](02-licensing.md#content-licensing--the-part-that-is-about-the-user-not-the-code).

**Rects are normalised `0…1`, origin top-left.** Recipes stay valid across canvas sizes, so a
9:16 recipe can be re-targeted to 1:1 by the binder without touching the recipe.

**Time is `Double` seconds, not `CMTime`.** `CMTime` is the right type at the AVFoundation
boundary and the wrong type in a JSON document — its rational representation makes diffs
unreadable and equality surprising. Conversion happens once, at the edge.

**`sourceKind` records what the *reference* used** (image vs video), so the binder can prefer a
user video for a slot the reference filled with motion footage. It is a preference, not a
constraint; the user can put a still there.

**Fidelity is a binder option, not a recipe field.** The same recipe binds three ways —
Close Match, Use Style (no text slots), Use Structure (durations only) — because those are
choices about *this project*, not facts about the reference.

**Camera-move directions are named for the camera.** `translationX > 0` in the fit means the
frame's centre moved right, i.e. content slid right, i.e. the camera panned *left*; the compiled
crop window travels the opposite way to the measured content motion so the reproduction matches.

---

## Versioning

```swift
enum RecipeSchema {
    static let current = 1
    static func migrate(_ json: Data) throws -> EditRecipe   // 1 → 2 → … → current
}
```

Loading a newer `schemaVersion` than we understand fails loudly with a "made with a newer
version of Reframe" message rather than decoding partially. Loading an older one migrates
forward and rewrites on next save.
