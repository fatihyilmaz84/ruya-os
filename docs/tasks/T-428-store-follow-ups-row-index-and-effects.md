# T-428 - Store follow-ups: a row remembers its card, a scrolled shot, card effects only where needed

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Store page) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
The Store keeps T-377's fast open and loses its rough edges: a row built late still lands on the card the player left, and each card draws only the effects it needs.

## Read first
- `docs/tasks/T-377-*.md` (Outcome and review notes), `docs/specs/04-design-system.md` §3.6, §5 (cards, lift), principle 5
- The Store page QML (`rowIds`, `slotY`, the lazy rows), the card component with its lift shadow, halo and glare `MultiEffect`s; `scripts/page-open-bench.py`

## Scope
1. A Store row not built yet keeps its remembered card index: a `pendingIndex` applied when its model fills (test: leave row 3 at card 2, rebuild, return: card 2 focused).
2. `slotY` is not recomputed for every row on each `rowIds` change (only rows whose position changed), with a test that counts recomputes.
3. Make each card's halo and glare `MultiEffect` exist only on the focused card, keep the lift shadow's fade-in (test: one halo/glare instance on the page; focus move keeps it on the focused card).
4. A `shots` case of the Store scrolled to "Apps & media".

## Out of scope
- New Store content or layout.

## Acceptance criteria
- [ ] Items 1-3 tested (named in the Outcome); item 3's test is red without the change.
- [ ] The host offscreen open bench (`page-open-bench.py` or the existing timing test) is not worse than T-377's 31-49 ms max frame.
- [ ] hw (lead run): on the Dell, `page-open-bench.py` Store, 5 opens, max frame under 50 ms; mark `unverified` until the lead runs it.
- [ ] UI tasks - UX: focus lands on the remembered card after Back; Outcome has a `UX notes:` line.
- [ ] `dev.ps1 test` and `shots` ALL GREEN; the new Store shot reviewed.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §5 if the card's effects are described there.

## Hints
- From the STATUS Inbox (T-377, lead-8), triaged by lead-9 on 2026-11-10. Offscreen draws no `MultiEffect` pixels: assert instances and properties.

## Outcome
Verified: host (hw pending: Dell `page-open-bench.py` Store, 5 opens, max frame under 50 ms)

UX notes: nothing looks different at rest; the rows, cards, ring and glow are as in T-377 (`17-store-home` and the new `17-store-apps-and-media` reviewed). States reached: Store open (Featured's first card focused), Down twice to Apps & media (the page scrolls, the row builds its cards, its first card takes focus), Right moves within the row, Up/Down between rows, a row that vanishes and returns. Back leaves each state as before (search to the rows, Store to the nav). Focus lands on the remembered card of a row that was emptied and refilled (`test_a_row_that_was_emptied_returns_on_the_card_it_left`) and on a pending card when a row builds late (`test_a_row_built_late_lands_on_its_remembered_card`). Doubt: a row only has a "remembered" card the player left while it had cards; the page never loses its cards while it lives, so the visible cases are a row emptied for a moment by a filter or catalogue change, and the code path for a row built late (a hook the page does not drive today).

**What was built.**
1. `StorePage.qml` `StoreRow.pendingIndex` (-1 = none): `refresh()` takes the current card, or the pending one while the row has no cards, and a ListView `onCountChanged` (through `Qt.callLater`) applies it when the model fills. The apply calls `forceLayout()` first: a ListView that fills puts its current card on the first one when it lays out, after the count changed (seen in a probe: the index went 1, then 0).
2. `slotY` is a plain property now, set by `page.updateSlots()` (called by `rebuildRows`) only on the rows whose place moved; `page.slotUpdates` counts the sets.
3. `GlassShadow.qml`: the halo `SmoothMask` is made by a `Loader` (`haloLoader`) only while `haloShown && (shown || opacity > 0)`, so the focused card has it and an unfocused one lets it go after the fade-out; the lift shadow (`shadowEffect`) is unchanged and fades in as before. `CardFocusLayers.qml`: the glare's two layers and `SmoothMask` (`glareEffect`) are made by a `Loader` (`glareLoader`) only while the card is `focused`; the animation (`glareAnimation`, now moving `glareX`) and `glareCount` stay always there. Both files got `pragma ComponentBehavior: Bound` (qmllint, ids used inside the Loader components). The shared components change for every card (Home, Games, Library), not the Store only.
4. `tst_store_ui.qml` `test_zz_screenshots_scrolled` -> `17-store-apps-and-media.png`: Apps & media focused, the page scrolled. In a real `shots` window the rows' Column stays unlaid until its next polish (the case `tst_long_names` documents), so the test lays it out first (`forceLayout`) and waits for `contentY > 0`; without that the picture shows an unscrolled Store.

**Tests** (named; revert checks with `revert-check.ps1 -Test tst_store_open`, each caught): `test_halo_and_glare_exist_only_on_the_focused_card` (one `haloEffect` and one `glareEffect` below the rows; the focus move takes both to the new card and the old one lets go after its fade; the lift shadow still shows on the focused one) - undone: halo Loader `active` -> `true` (red), glare Loader `active` -> `true` (red). `test_a_row_place_is_set_only_when_it_moves` (same rows: no place set again; Games emptied: exactly the two rows below move; back: they move back) - undone: `if (row.slotY !== y)` -> `if (true)` (red). `test_a_row_that_was_emptied_returns_on_the_card_it_left` - undone: `keep` ignoring `pendingIndex` (red). `test_a_row_built_late_lands_on_its_remembered_card` - undone: the ListView `onCountChanged` line (red). Updated, not weakened: `tst_artglow` `test_halo_per_tier` (the halo effect is gone on Balanced and Performance: `tryVerify(... === null)` instead of `halo.visible === false`, a Loader deletes it later) and `test_the_picture_mask_keeps_the_antialiased_edge` (the card is focused first, since the glare and halo effects exist only then).

**Bench.** Offscreen host Store opens in the new tests: `page-open store create=4-5 firstSwap=15-23 afterAnim=297-312 maxFrame=25-29` (T-377: 31-49 ms max with 3012 apps, 29-37 with 12): not worse. hw (Dell) unverified.

**Checks.** `dev.ps1 test` ALL GREEN (1122 QML passed + 94 skips, Rust as before). `dev.ps1 shots`: only the four known reds (`Display`, `StoreUi::test_zz_screenshots` at `tst_store_ui.qml:82`, `SystemInfo`, `Wallpaper`; same as T-377's outcome), the new shot passes. No test lost (`scripts/lost-tests.sh`: none).

**Files.** `shell/qml/StorePage.qml`, `shell/qml/GlassShadow.qml`, `shell/qml/CardFocusLayers.qml`, `shell/tests/tst_store_open.qml`, `shell/tests/tst_store_ui.qml`, `shell/tests/tst_artglow.qml`, `docs/specs/02-shell.md` (Store row), `docs/specs/04-design-system.md` (Glass shadow, Card focus layers).

**Round 2 (review).** `slotY` no longer followed the UI size `u` (it was a binding on `rowHeight`; the first `updateSlots` also ran before the shell bound `page.u`). Fixed with `onRowHeightChanged: page.updateSlots()` in `StorePage.qml` (the first slots use the bound `u` once it arrives). New `test_row_places_follow_the_ui_size` (u halved: the places follow and Apps & media, now in view, builds its cards; u grown again: the places follow); revert check: the `onRowHeightChanged` line removed -> red ("smaller: the places follow"). `04` section 3.8 Card focus row now says the glare band, mask and effect exist only while the card has focus. Merged main (T-457, T-448) first; no conflicts. Not done (Inbox, pre-existing): the scrolled view clips row tops and the hint bar covers labels.

Builder: Claude Sonnet 5.5, high effort, rounds 1-2.
