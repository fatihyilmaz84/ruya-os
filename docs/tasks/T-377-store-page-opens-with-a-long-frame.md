# T-377 - The Store page opens with one 275 ms frame: find it and remove it

Status: todo · Phase: 2 · Depends: — · Area: shell (StorePage, store cards, AppArt) · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
Opening the Store feels as quick as Settings and Games. The page-open probe (T-349, `ruya-shell: page-open` lines) on the Dell (0.0.59, Intel UHD 630, 1080p, owner report 2026-11-09 "same slowness as Settings had"):

| Page | create | firstSwap | afterAnim | maxFrame |
|---|---|---|---|---|
| store (3 opens) | 67-93 ms | 72-97 ms | 597-642 ms | **271-282 ms** |
| settings | 3-20 ms | 7-30 ms | 278-309 ms | 18-30 ms |
| games | 3-10 ms | 5-16 ms | 283-299 ms | 18-19 ms |

So the creation costs 70-90 ms, and one frame right after the first swap stalls for about 275 ms (the open animation then ends 300 ms late).

## Read first
- `docs/tasks/T-349-settings-opens-slowly-lazy-panes-and-modals.md` (Outcome: how Settings was fixed, the probe and its fields), `docs/specs/02-shell.md` §1 (page-open timings), §8 budgets, `docs/specs/04-design-system.md` §5.2 (cards), `shell/PATTERNS.md`
- `shell/qml/StorePage.qml` and the cards/shelves it builds, `AppArt.qml`, `SmoothMask`, `CardFocusLayers`, the store mock (`shell/src/store`), `scripts/page-open-bench.py`, `docs/dev-setup.md` "Page-open timings"

## Scope
1. **Find the long frame** with evidence, on the host first (the probe runs everywhere; a GPU window via `shots` or a `QSG_RENDER_TIMING=1` run) and name its cause: synchronous image decode or texture upload of card art (`asynchronous`, `sourceSize`), one shader per card (`SmoothMask`/`MultiEffect` instances compiled on first show), every shelf and delegate built at once (no `cacheBuffer`/lazy rows), glyph cache growth, or the store model's first fill.
2. **Remove it** with the matching T-349 style fix (build only what is on screen or about to be, decode art asynchronously at the shown size, share one mask/effect where possible, defer below-the-fold shelves), keeping the look of 04 §5.2.
3. Re-measure; report before/after for create, firstSwap, afterAnim, maxFrame.

## Out of scope
- The store service, new store features, the card-style question (T-282).

## Acceptance criteria
- [ ] QML tests that would go red if the fix is reverted (for example: off-screen shelves are not instantiated at open; art images are `asynchronous` with a `sourceSize`; a single shared effect instead of one per card), each named in the Outcome with its revert check.
- [ ] The cause is named with evidence (probe lines or render timing before/after) in the Outcome.
- [ ] Screenshots of the Store (en) unchanged in look, reviewed against 04 §8.
- [ ] hw (lead, Dell): `page-open store` maxFrame below 50 ms and afterAnim within 50 ms of Settings over 5 opens (`page-open-bench.py` or the journal); Outcome `Verified: host (hw pending: Dell page-open store)`.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
