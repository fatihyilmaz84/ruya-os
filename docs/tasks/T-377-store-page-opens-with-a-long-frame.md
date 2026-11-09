# T-377 - The Store page opens with one 275 ms frame: find it and remove it

Status: done · Phase: 2 · Depends: — · Area: shell (StorePage, store cards, AppArt) · Size: M · Owner: builder · Complexity: complex · Developer surface: none

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
Verified: host (hw pending: Dell page-open store)

UX notes: the rows on screen look as before; one real change: before the service answered the "gamepad" filter, the first frames of the Store showed the rows of "any" (apps without controller support in Apps & media) and then rebuilt them; now the first frame already shows the filtered rows. States reached in `tst_store_open`: Store opened (with 12 and with 1012 apps), Down through Games, Apps & media and Installed (a row below the fold builds its cards when it takes focus; focus asserted at each step; its first card shows the focus), Up back to Featured; a search (the results take focus) and Back (focus back on Featured). Back leaves a search to the rows and the Store to the nav as before (`tst_store_ui`, `tst_pages`). Doubt: a row below the fold builds its five or six cards in the key frame that focuses it (once); a row that scrolls into view under it builds its cards during the scroll animation.

**Cause, with evidence.** The Store's cost grew with the size of the catalogue, and the Dell holds a real remote's (Flathub, thousands of apps); the mock has 12, so the host never showed it. Three things in `StorePage.qml`, all on the GUI thread:
1. every card ran `Store.catalogue.find(a => a.id === modelData)`: each read of `Store.catalogue` hands the whole list to QML and the scan turns record after record into a JS object, once per card (about 40 cards) and again whenever the catalogue changed;
2. the page opened with the results of "any" (it sets "gamepad" in `Component.onCompleted`, the service answers later), built all four rows and the hidden search grid from them (`refreshResults` and four `idsFor` filters over the whole list), and when the answer arrived rebuilt every row whose ids changed (the ListView models were replaced, so their cards were destroyed and built again);
3. every row and the hidden results GridView built cards, including the two rows below the fold.

Measured with the page-open probe on the host, offscreen (software renderer: GUI-thread costs only, which is where all three are), a scratch test that opens the Store 6 times, Settings and Games 3 times each, signed in as Ada, with `Store.mockAddApps(3000)` (a catalogue of Flathub's size; new mock call) and with the mock's 12 apps:

| Store, offscreen host | create | firstSwap | afterAnim | maxFrame |
|---|---|---|---|---|
| before, 3012 apps | 34-47 ms | 243-287 ms | 296-350 ms | **243-287 ms** |
| after, 3012 apps | 7-11 ms | 31-49 ms | 303-308 ms | **31-49 ms** |
| before, 12 apps | 8-10 ms | 49-61 ms | 296-309 ms | 49-61 ms |
| after, 12 apps | 5-8 ms | 17-35 ms | 296-324 ms | 29-37 ms |
| Settings (all runs) | 2-5 ms | 7-29 ms | 289-316 ms | 17-30 ms |
| Games (all runs) | 1-3 ms | 10-30 ms | 293-310 ms | 19-33 ms |

The "before, 3012 apps" line has the Dell's shape (maxFrame 271-282 there, 243-287 here; afterAnim up to 50 ms late); after the fix the Store with 3012 apps is within about 10-20 ms of Settings and its afterAnim matches Settings'. Steps (3012 apps): the card lookup and the single pass alone gave maxFrame 48-59 ms; lazy rows 34-40; the pass in C++ (`Store.rowIds`) 31-49 (median 36). **Not measured: the GPU path** (card art masks and `MultiEffect`s on a real window). My real-window scratch runs swapped no frame after the first one (even with 12 apps; `shots`, which grabs its images, did render), so there is no `QSG_RENDER_TIMING` evidence for the render thread; the one real-window run that worked (12 apps, main's code) gave Store maxFrame 52-68 ms against Settings 25-31, the same shape as offscreen, and its render timing showed a 37 ms polish (the ListViews building their cards) in the first frame and a 75 ms gap before the next (the rows built again when the filter's answer came). Whether the Dell's GPU side adds a long frame of its own (art pictures arriving and switching on their mask layers) is for the lead's Dell run.

**What was built.**
- `Store.app(id)` answers from a hash index of the catalogue (`m_catalogueIndex`, rebuilt when the catalogue is replaced; the first record wins for a doubled id, as the scan did). A card reads `Store.app(modelData)`, again when `catalogueChanged` bumps the page's `catalogueRevision`.
- `Store.rowIds(gamepadOnly)` (new `Q_INVOKABLE` on the shell's Store facade; no D-Bus change): one pass in C++ over the results giving `all`, `featured`, `games`, `apps` and the installed ids, so no record is handed to QML. With `gamepadOnly` it first cuts the results to controller `full`/`partial` (03 section 4.2, the rule of Search's "gamepad" filter), so the rows the page builds before the answer are the ones the answer brings. The answer is still what counts: the rows follow it.
- `StorePage`: `rebuildRows()` replaces `idsFor`/`refreshResults` and the rows' own `Connections` (one call on `resultsChanged` and `installedChanged`, then each row's `refresh()`, which keeps its list when its ids did not change). The row delegate is an inline `StoreRow` component; a row has cards only once it is on screen (`slotY`, from the rows above it, known before the Column lays out) or takes focus, then keeps them (`cardsBuilt`). The search grid's model is empty unless searching.
- Mock and test hooks: `Store.mockAddApps(n)` (n community apps, one in five `full`, one in five `partial`; gone after `mockReset` plus `mockCatalogChanged`), `Store.mockSearchReplyDelay(ms)` (until `mockReset`), `Store.mockCatalogueReads()` (a counter in the `catalogue` getter).
- Specs: 02 section 1 (Store row), 03 section 4 (Store facade: `app`, `rowIds`, the new mock hooks).

**Tests.** New `tst_store_open.qml`: `test_only_the_rows_on_screen_have_cards` (1012 apps: Featured and Games have cards; Apps & media and Installed start below the fold and have none; the hidden grid has none; Down builds a row's cards, focus at each step; a row keeps them), `test_a_search_builds_the_result_cards`, `test_rows_are_not_built_again_when_the_filter_answer_arrives` (reply delayed 400 ms: the rows' ids before the answer hold no app without controller support and equal the ids after it; Featured's and Games' first cards are the same objects after the answer), `test_cards_look_their_record_up_and_follow_the_catalogue` (opening reads no whole catalogue; a changed name reaches the card). Updated, not weakened: `tst_store_ui` `openApp` and `test_rows_follow_the_catalogue` read a row's `ids` (a row below the fold has no cards, so its ListView model stays empty until it shows); `test_controller_filter` checks Browser in Apps & media's ids (that row is below the fold) and still checks that no Browser card exists once the filter is back.

Revert checks (`revert-check.ps1 -Test tst_store_open`, each caught): `model: row.cardsBuilt || row.wantsCards ? row.ids : []` -> `model: row.ids` (rows on screen only); the grid's `page.searching ? page.resultIds : []` -> `page.resultIds` (both grid assertions); `page.catalogueRevision += 1` removed (the card keeps the old name); the card's `Store.app(modelData)` -> `Store.catalogue.find(...)` ("opening the Store reads no whole catalogue"); in `Store::rowIds` the gamepad rule disabled (`if (false && gamepadOnly)`: the rows before the answer list Browser); `indexCatalogue()` not called (three tests).

**Checks.** `dev.ps1 test` ALL GREEN (1018 Qt Quick tests, 79 skips; 842 Rust). The run before it had one red, `tst_battery_cluster` `test_the_chip_shrinks_to_plus_n_in_a_narrow_room` (the status cluster's layout against the clock text, nothing of the Store), green alone and in the next full run: a flake (Inbox). `dev.ps1 shots`: 154 passed, 4 red, all pre-existing: `StoreUi::test_zz_screenshots` at `tst_store_ui.qml:82` (main's line 81; one comment line added above it), `SystemInfo` at 502, `Wallpaper` at 898 (the three the lead named), and `Display::test_zz_screenshots` at `tst_display.qml:101` ("category list has focus"), which fails the same way with main's own build (`D:\dev\RuyaOS`, built 19:24 today), so it is not this branch. Reviewed `17-store-home` and `art-glow-store-dreamglass`: the same rows, cards, badges, captions and focus ring as before (04 section 8: tokens and components unchanged; the cards are smaller than in main's review copy of 2026-11-07 because `cardWidthCompact` became 288 on 2026-11-08, commit 5a3bfb8, not here). Real-window probe runs (threaded and basic render loop) after the first one swapped no frame in my scratch window, so the GPU numbers stay with the Dell run.

**Files.** `shell/qml/StorePage.qml`, `shell/src/store/Store.{h,cpp}`, `shell/src/store/MockStoreBackend.{h,cpp}`, `shell/tests/tst_store_open.qml` (new), `shell/tests/tst_store_ui.qml`, `docs/specs/02-shell.md`, `docs/specs/03-services-and-apps.md`.

Builder: Claude Opus, medium effort (Complexity complex), round 1, about 250k tokens (estimate).
