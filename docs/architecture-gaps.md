# Architecture gaps

Ordered by how much else they block. Fixing #1 and #2 unblocks most of the brief; the rest are
comparatively ordinary feature work.

## 1. No track model — blocks compositing, PiP, multi-track audio, effect tracks

`Timeline` holds four flat arrays (`clips`, `textLayers`, `overlays`, `audio`). There is no
`Track` type, so there is nowhere to express ordering, lock, hide, mute, solo, or a second
video layer.

**Fix:** introduce `Track` with a kind, ordered `items`, and per-track flags. Keep the existing
arrays as computed accessors during migration so `RenderPlanner`, `VideoExporter` and every
`EditCommand` keep working, then migrate call sites incrementally. Schema version bump with a
forward migration.

**Blocks:** PiP · overlays as layers · blend modes · chroma key · masks · multi-track audio ·
effect tracks · track reordering · lock/hide/mute/solo.

## 2. Navigation is decentralised — blocks predictable UX everywhere

12 mutation sites across 8 files. See `docs/navigation-map.md`. **Fix:** a `Router` owning
`[AppState]` with an explicit transition table; screens express intent only.

**Blocks:** every "no dead ends" requirement, deep links, state restoration, back behaviour.

## 3. No keyframe/animation subsystem — blocks motion work

`VideoClip` has `cropStart`/`cropEnd` and an `easing` — a two-point tween, not keyframes. Text
animation is a fixed enum. There is no shared animation model.

**Fix:** one generic `AnimatedProperty<Value>` with `[Keyframe<Value>]` and per-segment easing,
plus an `Animatable` registry naming which properties accept keyframes. Implement **once**, use
for transform, opacity, effects, colour and audio.

**Blocks:** keyframes · speed curves · motion presets · effect parameter animation.

## 4. Effects are hardcoded scalars — blocks a scalable effect library

`vignette` and `grain` are `Double`s on `VideoClip`, applied by a `switch` in the shader. Adding
an effect means touching the model, the planner, the uniforms and the shader.

**Fix:** an `Effect` value type (id, parameters, enabled, order) plus an `EffectRegistry`
mapping ids to shader routines. Effects become data.

**Blocks:** the entire effects catalogue · stacking · reorder · presets · copy/paste.

## 5. `relayout()` force-packs clips — blocks PRO/absolute mode and gaps

Called after every structural edit; recomputes `start` as the running sum of durations. Gaps
cannot exist, so absolute positioning is unrepresentable.

**Fix:** make it a per-track policy — `.magnetic` (current behaviour) or `.absolute` — so both
editing philosophies are available, as the brief requires.

## 6. No feature registry — causes duplicate implementations

Nothing records what exists. Text styling is implemented in `TextSheet`, `TextOverlayEditor`
and `RecipeBinder` independently.

**Fix:** `FeatureRegistry` with id, category, status, UI entry point, engine capability,
persistence, export, tests. Drives `docs/feature-parity.md` rather than being drafted by hand.

## 7. Analysis results are not cached per asset

`AssetFeatures` is recomputed on project reload; Vision runs again over every photo.

**Fix:** persist a Codable subset keyed by asset fingerprint. `FeaturePrint` is not Codable, so
store the scalars and recompute prints lazily only where diversity scoring needs them.

## 8. Test coverage is structurally uneven

43 tests, strong on schema/commands/DSP, **zero** on navigation, persistence round-trips,
export correctness or render planning against golden output.
