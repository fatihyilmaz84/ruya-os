# T-101 — Page navigation framework

Status: done · Phase: 1 · Depends: — · Area: shell · Size: M

## Goal
Selecting a home tile (Games, Media, Store, Settings, Power) opens that section as a full page. Back returns to home with focus on the same tile. This gives every later feature a place to live.

## Read first
- `docs/specs/02-shell.md` §1 (information architecture), §3.2 (durations), §4.3 (focus rules)
- `shell/CLAUDE.md`
- `shell/qml/Shell.qml`, `shell/qml/Tile.qml`, `shell/tests/tst_shell.qml`

## Scope
1. Add a page host to `Shell.qml` with an API like `openPage(key)` and `closePage()`. Use a `Loader` or `StackView`-free approach; QtQuick.Controls is not used in this project.
   - Only one page is open at a time in this task. Keep the API stack-shaped (push/pop) so detail pages can nest later.
2. Give each home tile a stable `key` (`games`, `media`, `store`, `settings`, `power`). Accept (`Key_Return`/`Key_Enter`) on a tile opens its page. Keep the existing pulse animation and `Sfx.select()`.
3. Add a reusable `Page.qml` base: a title (top-left, below the header, inside the safe area), a content area, and `Back` handling. Back calls `Sfx.back()` and closes the page.
4. Add placeholder pages `GamesPage.qml`, `MediaPage.qml`, `StorePage.qml`, `SettingsPage.qml` and `PowerPage.qml`. Each shows its title and a "Coming soon" text, plus one focusable placeholder element, so focus can be asserted.
5. Transition: the home shelf fades and slides out while the page fades in, using `Theme.pageMs` (300 ms). The reverse happens on close. The backdrop stays.
6. Focus:
   - Opening a page focuses the page's first focusable element.
   - Closing restores focus to the tile that opened it (same `currentIndex`).
   - The Guide overlay (`Key_HomePage`/`Key_Menu`) still opens from any page. Closing the overlay returns focus to the page, not to the tiles.
7. "Switch profile" from the overlay while a page is open closes the page as well; after the next sign-in, home is shown.

## Out of scope
- Real content in any page (later tasks).
- Settings categories (T-103).
- Remembering the open page across profile switches.

## Acceptance criteria
- [ ] Accept on each of the 5 tiles opens the matching page (test: `tst_pages.qml::test_each_tile_opens_its_page`, data-driven).
- [ ] Back on a page returns home with `tiles.currentIndex` unchanged and `tiles.activeFocus` true (test `test_back_restores_tile_focus`).
- [ ] The overlay opens over a page, Back closes it, and focus returns to the page's focused element (test `test_overlay_over_page`).
- [ ] Switch profile from the overlay on a page ends at the picker, and the next sign-in shows home (test `test_switch_profile_from_page`).
- [ ] While a page is open, arrow keys never move the home tiles (test `test_page_is_isolated`).
- [ ] Screenshot `5-page-settings.png` shows the Settings placeholder page with title, the header intact, and nothing overlapping. Extend `test_zz_screenshots`, or add the shot in `tst_pages.qml`.
- [ ] Existing tests still pass unchanged.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1: describe the page model (keys, the Back behaviour, overlay over pages).
- `shell/CLAUDE.md`: add "how to add a page" (3–5 lines) once the pattern exists.

## Hints
- `ListView.currentItem` gives the focused `Tile`. Add `required property string key` to `Tile.qml` and a `key` role to the `ListModel`.
- Disable (`enabled: false`) whatever is not on screen. Disabled items can't take focus, which prevents most focus bugs.
- Keep `routeFocus()` in `Shell.qml` as the single place that decides where focus goes after state changes. Extend it rather than adding a second mechanism.

## Outcome
**Built** (2026-10-22, Sonnet 5.5):
- `Shell.qml`: `pageStack` / `currentPage` / `pageOpen`, `openPage(key)`, `closePage()`, `focusCurrent()`; `routeFocus()` extended to use it. Pages are created by a `Loader` from `pageComponents`, in a `pageHost` that fades and slides in while `home` fades and slides out (`Theme.pageMs`, new token `Theme.pageSlide`). `home` is disabled while a page is open.
- Tiles have a `key` role (`Tile.qml`, `ListModel`). Accept pulses, plays `Sfx.select()`, then opens the page.
- New `Page.qml` (title, content area in the safe area, Back), `ComingSoon.qml` (placeholder body with one focusable element) and `GamesPage/MediaPage/StorePage/SettingsPage/PowerPage.qml`. All listed in `CMakeLists.txt`.
- New `tests/tst_pages.qml`: the 5 acceptance tests plus the `5-page-settings.png` screenshot.
- Docs: `02-shell.md` §1.1 (page model), `shell/CLAUDE.md` "How to add a page".

**Verification:** `dev.ps1 test` → ALL GREEN (23 passed, 2 skipped without `RUYA_SHOTS_DIR`); `dev.ps1 shots` → ALL GREEN (25 passed). Reviewed `5-page-settings.png` (title, header intact, focus ring on the placeholder, nothing overlapping) and `4-overlay.png` (unchanged). Existing tests are untouched and pass.

**Deviations / choices:**
- The Guide key handler moved from the tiles' `Keys.onPressed` to the `Shell` root, so it also fires from pages (pages leave Guide unhandled; the overlay and PIN pad are modal and accept everything). It is guarded by `signedIn`.
- `home` and `pageHost` use `visible: shown || opacity > 0` so they are visible in the same step they are enabled, which lets `focusCurrent()` work synchronously.
- A `Loader` plus per-page `Component`s were used rather than `Loader { source: "…" }`, so qmllint can check the types.
- Not verified: the transition motion itself (only end states are asserted; screenshots are static).

**Follow-ups:** none. The "Switch profile" test found that the picker keeps its `currentIndex` across a lock; that is existing behaviour and unchanged.
