# 09 — Real-device validation

Nothing in this project is considered *working* until it has run on a physical iPhone with a
real reference and real photos. Compilation, CI and unit tests prove the code is coherent; only
a device proves the product. This document is the procedure.

The project is developed on Windows with no Mac. CI on `macos-26` produces an unsigned `.ipa`
on every push (Actions → the run → **Reframe-unsigned-ipa**). Sideload it, run the corpus
below, and send back the diagnostics log. Every finding here should turn into a fix, a test,
or a documented limitation — never into a shrug.

---

## 1. Install

1. Download the `.ipa` artifact from the latest green CI run.
2. Sideload with your usual tool (AltStore, Sideloadly, or Xcode's Devices window on a
   borrowed Mac). The app signs itself on the way in; there is no signing in CI.
3. Open **Settings → Build** in the app and note the line — it carries the commit SHA. Every
   report starts with that line.

---

## 2. Reference corpus

Twelve reference types, one video each. Record ground truth *before* running analysis, by
watching the video with a stopwatch or a desktop editor's timeline. Approximate is fine;
"9 cuts, one dissolve near the end, music at roughly 128" is enough to score against.

| Type | Reference | Duration | Res | Ground truth to record |
|---|---|---|---|---|
| A | Simple photo slideshow | 15–20 s | 1080p | scenes, dissolve lengths, any Ken Burns |
| B | Fast Instagram Reel | 10–15 s | 1080p | cut count, BPM, whether cuts land on beats |
| C | Product advertisement | 15–30 s | 1080p | scenes, hero shot, text layers, CTA |
| D | Talking-head video | 20–40 s | 1080p | 1 continuous shot expected; speech present |
| E | Text-heavy video | 15–20 s | 1080p | text layers, their timings, any word-by-word |
| F | Music + beat cuts | 15 s | 1080p | BPM, beat-aligned cuts |
| G | Transitions (dissolve/fade/slide) | 15–20 s | 1080p | which transitions, where |
| H | Zoom / pan footage | 15–20 s | 1080p | which scenes push in / pull out / pan and how much |
| I | Mixed photos + videos | 20–30 s | 1080p | which scenes were stills vs footage |
| J | Landscape video | 15–20 s | 1080p 16:9 | canvas defaults to 16:9; portrait output via Canvas sheet |
| K | 4K video | 15 s | 2160p | analysis time and memory |
| L | Long video | 30–60 s | 1080p | analysis time, memory, whether the recipe stays sane |

Sources: your own recordings, your own past posts, or a screen recording of a reel you have
permission to study. Reframe never uses the reference's pixels, so anything you can legitimately
watch is a legitimate reference.

Ground-truth template (copy per reference):

```
Reference:  __________   Type: __   Duration: ___ s   Res: ______   fps: __
Scenes (count):  __      Cuts at (s):  ___ ___ ___ ___ ___ ___
Transitions:     __ dissolves  __ fades  __ other (describe)
Camera moves:    scene→kind (e.g. 3→push in, 5→pan left)
Text layers:     __   (start–end, position, size: big/medium/small)
Audio:           music Y/N   speech Y/N   BPM ~___   cuts on beat Y/N
Subject:         where the main subject sits (centre / upper third / left …)
```

---

## 3. Full-pipeline run, per reference

For each reference, run the whole flow and tick:

```
[ ] Import (Photos / Files / Share → Reframe)          → no error, analysis starts
[ ] Analysis completes                                 → all six stages show a result
[ ] Summary numbers vs ground truth                    → score below
[ ] Mode chosen (Close Match)                          → next
[ ] Reference audio choice (keep / extract / mine)     → extraction works if tried
[ ] 8–15 own photos + 1–3 clips imported               → grid shows all, no silent drops
[ ] Auto Arrange                                       → every slot filled, reasons make sense
[ ] Pin one slot, Shuffle                              → pinned slot unchanged
[ ] Create Video → editor opens                        → preview plays; video clips move
[ ] Audio plays in preview                             → music / voice audible, silent switch on
[ ] Trim a clip by its handle, undo, redo              → one undo step
[ ] Long-press reorder a clip                          → order changes, undo restores
[ ] Add text, change preset, drag it on preview        → renders as styled
[ ] Record a voiceover                                 → appears as a lane; music ducks
[ ] Captions (if voice recorded)                       → timed words appear
[ ] Change canvas to 1:1                               → crops re-solve around subjects
[ ] Export 1080p HEVC                                  → completes; Save to Photos works
[ ] Re-open Photos: plays, audio present, no black frames, text where it was in preview
[ ] Background the app mid-edit, return                → project autosaved (Home shows it)
[ ] Force-quit mid-edit, relaunch                      → "Recover your last project?" appears
[ ] Settings → Diagnostics → Export Log (text and JSON)
```

Attach the diagnostics export to every report. It records stage timings, memory footprint,
analysis results and export summary without any personal content.

---

## 4. Performance matrix

Read the numbers off the diagnostics log (`perf` timing lines and the `[MB]` column) after each
run. Targets from `08-quality.md`; fill in measurements and revise the targets in that file
rather than quietly ignoring misses.

| Video | Resolution | Duration | Analysis (s) | Peak analysis MB | Auto Arrange (s) | Preview smooth? | Export 1080p (s) | Peak export MB | Export size | Thermal after |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 1080p | 15 s | | | | | | | | |
| B | 1080p | 30 s | | | | | | | | |
| C | 1080p | 60 s | | | | | | | | |
| D | 4K | 15 s | | | | | | | | |
| E | 4K | 30 s | | | | | | | | |
| F | mixed | 30 s | | | | | | | | |

Also try one **4K export** and one **60 fps export** and record the same columns.

---

## 5. Quality scoring

Score each reference 0–100 per row after comparing the summary and the generated video against
the ground truth. Be harsh; the point is a trend line, not a pass mark.

| Dimension | What 100 means | Score |
|---|---|---|
| Scene accuracy | Same scene count; every cut within 0.1 s of truth; no phantom cuts | |
| Timing accuracy | Generated clip lengths within 0.1 s of the reference's | |
| Asset matching | Every slot got a photo you'd have chosen; hero got the best; no near-duplicates back to back | |
| Crop accuracy | Subjects framed as in the reference; no beheaded portraits; landscape photos cropped around the subject | |
| Motion similarity | Push/pull/pan named correctly; magnitude feels right; no move where there was none | |
| Text similarity | Layer count, timing and position match; size fits your copy | |
| Audio sync | Cuts land where they should against the music; ducking is audible and clean | |
| Overall template quality | "This is recognisably that edit, with my content" | |

Record the eight scores per reference in a table; the mean over the corpus is the release
number. Any single row under 40 becomes a bug report with the diagnostics log attached.

---

## 6. Robustness checks

- Photos access **Limited** (choose a few) → import still works, no silent drops.
- iCloud-only photo (Optimise Storage on) → thumbnail and full-size both load; the grid says so if a download is pending.
- Airplane mode → everything except iCloud downloads and the caption language pack works.
- Low memory: open the camera, a big game, come back → project intact, preview restarts.
- Corrupt / truncated video as reference → clear error, no crash.
- Reference with no audio → analysis completes, no beat grid, editor works.
- 1 photo, 12-slot template → repeats with the shortfall banner, no crash.
- Delete a photo from Photos that a project uses → placeholder renders; export completes.

---

## 7. Reporting

One message per reference type is ideal, but a single message with the diagnostics log and the
score table is fine. The build line, the type letter, the scores, and "what surprised you" are
the four things that turn a run into a fix.
