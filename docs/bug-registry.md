# Bug registry

Every fixed bug gets a regression test. If three bugs share a subsystem, the architecture is
fixed rather than the symptoms — see `docs/architecture-gaps.md`.

Status: `OPEN` · `FIXED` · `WONTFIX`

---

## RF-001 — Analysis screen is a dead end · **FIXED**

**Reproduction:** Home → Create From Reference → pick a video → wait for analysis → summary
appears → tap back.

**Symptom:** Returns to the analysis screen with no back button, no cancel button, no forward
navigation, and no re-run. Force-quitting is the only escape.

**Root cause:** Not a missing button — a state-machine failure. `AnalysisView` sets
`.navigationBarBackButtonHidden(true)`; its Cancel renders only `if !isFinished`;
`runAnalysis()` guards on `task == nil`. `@State` survives the back navigation, so on re-entry
`isFinished == true` and `task != nil`: every exit is hidden and the work will not restart.
Compounded by navigation being mutated from 12 sites, so no single place described the flow.

**Fix:** Centralised `Router` with an explicit transition table. `referenceAnalysis` is marked
*transient* and dropped from the path on completion, so it can never be a back destination.
Every state has a defined back destination.

**Regression test:** `NavigationTests.analysisIsNeverABackDestination`,
`NavigationTests.everyStateHasAnExit`.

---

## RF-002 — Navigation mutated from 12 sites across 8 files · **FIXED**

**Root cause:** No ownership. Child screens appended to and popped from `AppModel.path`
directly, each inventing its own assumptions about what came before.

**Fix:** `Router` owns all transitions; screens express intent (`advance`, `back`, `cancel`,
`complete`). Direct `path` mutation removed from feature code.

**Regression test:** `NavigationTests.routerIsTheOnlyMutator` — a source scan asserting no file
under `Features/` mutates the path directly.

---

## RF-003 — Timeline cannot express gaps or multiple tracks · **OPEN**

**Symptom:** No PiP, no second video track, no track lock/mute/solo, no absolute positioning.

**Root cause:** `Timeline` holds flat arrays; `relayout()` force-packs clips gaplessly.

**Planned fix:** `Track` model (architecture-gaps #1) plus a per-track layout policy (#5).

---

## RF-004 — Keyframes, LUTs, masks documented but absent · **OPEN**

**Symptom:** The word appears in comments and docs; no model exists.

**Root cause:** Aspirational prose was never separated from implemented capability, so the
feature list overstated the product.

**Planned fix:** `docs/feature-parity.md` records status per capability, generated from the
feature registry rather than written by hand.

---

## Previously fixed (carried forward)

| ID | Title | Regression test |
|---|---|---|
| RF-H01 | Every beat 23 ms late — STFT frame time used window start, not centre | `AudioTests.placesBeats` |
| RF-H02 | Beat grid drifted — advanced from fixed origin, never re-anchored | `AudioTests.placesBeats` |
| RF-H03 | Tempo could not hit ±2 BPM — integer autocorrelation lags | `AudioTests.estimatesTempo` |
| RF-H04 | Ineffective deletes undid into insertions | `CommandTests.applyRevertRoundTrip` |
| RF-H05 | Photos silently dropped — missing `photoLibrary: .shared()` | manual |
| RF-H06 | iCloud photos resolved nil — `isNetworkAccessAllowed = false` | manual |
| RF-H07 | Export allocated a texture per video frame | manual |
| RF-H08 | Preview's first play was always silent | manual |
