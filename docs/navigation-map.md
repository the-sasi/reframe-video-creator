# Navigation map

## The problem this replaces

`AppModel.path: [Route]` was mutated from 12 sites across 8 files. Each screen decided where
the app went next, so no single place described the flow and no screen could be reasoned about
in isolation. The analysis dead-end was the visible symptom of that.

## States

```
HOME ─┬─ PROJECTS
      ├─ TEMPLATES
      ├─ SETTINGS ── DIAGNOSTICS
      │
      ├─ REFERENCE_IMPORT ── REFERENCE_ANALYSIS ── REFERENCE_RESULT ─┐
      ├─ MUSIC_IMPORT ───────────────────────────────────────────────┤
      ├─ TEMPLATE_PICK ──────────────────────────────────────────────┤
      │                                                              ▼
      └─ SCRATCH ─────────────────────────────► ASSET_SELECTION ── AUTO_ARRANGE
                                                       │                │
                                                       └────────────────┴─► EDITOR ── EXPORT
```

## Transition table

Every screen must answer all six questions. This is the contract:

| State | Entry from | Forward | Back | Cancel | On failure |
|---|---|---|---|---|---|
| `home` | launch, any `returnHome` | any creation path | — | — | — |
| `projects` | home | `editor` | home | home | toast, stay |
| `templates` | home | `assetSelection` | home | home | toast, stay |
| `referenceImport` | home | `referenceAnalysis` | home | home | stay, retry |
| `referenceAnalysis` | referenceImport, share sheet | `referenceResult` | **referenceImport** | referenceImport | retry / cancel / diagnostics |
| `referenceResult` | referenceAnalysis | `assetSelection` | **home** (not analysis) | home | — |
| `musicImport` | home | `assetSelection` | home | home | stay, retry |
| `assetSelection` | referenceResult, templates, music, scratch | `autoArrange` or `editor` | **origin of the flow** | home | stay, retry |
| `autoArrange` | assetSelection | `editor` | assetSelection | assetSelection | stay, retry |
| `editor` | autoArrange, projects, scratch | `export` | **home** (work is saved) | home | stay |
| `export` | editor | home on success | editor | editor | retry at lower quality |
| `settings` | home | `diagnostics` | home | home | — |
| `diagnostics` | settings, any error | — | settings | settings | — |

## Rules

1. **Back from `referenceResult` goes home, never to `referenceAnalysis`.** Analysis is a
   *transient* state — it is never a back destination once complete. This is the specific fix
   for the reported dead-end.
2. **A completed analysis is persisted as a recipe.** Leaving does not destroy it; re-entering
   the flow offers to resume.
3. **No screen may append to the path.** Screens call intents (`Router.advance`,
   `Router.back`, `Router.cancel`); the router owns transitions.
4. **Every state has a defined back destination.** There is no "whatever happens to be beneath
   me on the stack".
5. **Transient states are dropped when passed.** `referenceAnalysis` and `autoArrange` are
   removed from the path once they complete, so back-navigation cannot land on them.

## Regression tests

`NavigationTests` asserts, for every state: a back destination exists; no path containing a
transient state survives its completion; and the specific reported sequence
(import → analyse → result → back) lands on `home` with a non-empty set of available actions.
