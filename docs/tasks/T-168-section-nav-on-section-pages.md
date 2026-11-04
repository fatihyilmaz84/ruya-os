# T-168 — Section nav on every section page

Status: in-progress · Phase: 2 · Depends: T-157 · Area: shell · Size: M · Owner: builder

## Goal
Games, Media, Store and Settings show the same top bar as Home: the section nav on the left (the current section filled, Settings as the filled gear) and the status cluster on the right, so the user always sees where they are and can jump sections. Today the nav is only on Home, so the Settings pill's filled state never shows (T-157 Inbox).

## Read first
- `docs/specs/02-shell.md` §1 (table: Home row), §1.1 (page model, section keys); `04-design-system.md` §2 (Home layout), §5 (Section nav, Glass pill), §8 (review list)
- UI: components used: `SectionNav`, `GlassPill`, `Icon`; new tokens or components: none
- `shell/qml/Shell.qml` (the Home top bar, `openSection`, `stepSection`, `statusGlass`), `shell/qml/Page.qml`, `shell/qml/SectionNav.qml`, `shell/PATTERNS.md` (pages)
- `shell/CLAUDE.md`

## Scope
1. **Lead decision (2026-11-03), record in 02 §1 and 04 §2:** the top bar (section nav + status cluster) is shown on Home and on the four section pages; detail pages pushed on top of a section (`openPage(key, params)`, e.g. Store detail), modals, the Guide overlay, the picker and the wizard do not show the nav. One nav instance (the Home one, moved to the shell's top layer) is simplest; two instances are fine if focus stays correct; say which.
2. **Focus:** focus starts in the page content, as today. Up from the top row of a page's content goes to the nav (the current section's pill); Down from the nav goes back into the page content (the item that had focus). LB/RB switch sections from anywhere on a section page (check what they do on pages today; make them do this, tested). Back on a section page still returns to Home.
3. The page heading (`Page.qml`, `heading`) must not overlap the nav: check the layout at the 1080p design size and at the tiers' sizes used by `shots`.
4. The `isSection` state of each pill follows the page on screen (Settings filled while Settings is open).

## Out of scope
- A redesign of the pages' headings, the hint bar (T-158), the controller battery in the status cluster (T-161).

## Acceptance criteria
- [ ] On each section page the nav is visible and its current pill is that page (test in `tst_pages.qml` or a new file: for `games`, `media`, `store`, `settings`).
- [ ] Up from a page's first content row focuses the nav's current pill; Down returns focus to the same content item; focus asserted after each step (test).
- [ ] On a detail page (Store detail) and with the Guide overlay open, the nav is not visible or not focusable (test).
- [ ] Settings page: the gear `Icon` is `filled` (test on `navIcon_settings`).
- [ ] Screenshots of Games and Settings with the top bar (new or updated `shots`), reviewed against `04` §8: no overlap with the heading, ring outside the current pill.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02-shell.md` §1 (Home row and page model), `04-design-system.md` §2 and the Section nav row in §5.

## Hints
- Every page's "first content row" differs; a page can expose a small hook (for example `signal upFromTop()` or a function `focusFirst()`) in `Page.qml` instead of each page knowing about the nav. Keep it in `Page.qml` so new pages get it for free.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN: 278 QML + 23 skips; `dev.ps1 shots` reviewed `21-games-grid.png`, `5b-settings-nav.png`).

One `SectionNav` instance, moved from `home` to the shell's top layer (`Shell.qml`), so it stays put when Home fades to a page. `navShown` = signed in, no app, and Home or a section page on top; it fades with `pageMs`, is disabled while the Guide overlay is open and hidden on detail pages. `navSection` follows the page on screen (the Settings gear is filled on Settings). `Page.qml` has `upFromTop()` (an Up no content item accepted) and `stepRequested(direction)` (LB/RB); the shell focuses the nav on the page's pill (remembering the focused item) and Down restores that item. LB/RB from a page or the nav switch section (open pages are closed first, so Back lands on Home; the Home pill returns to Play). Back from the nav closes the page. Games and Store have a filter/search row above the content, so Up from the grid needs one more press to reach the nav (the row is their top row). The status cluster was already on pages. The heading sits below the nav at 1080p and 720p with no overlap (screenshots).

Tests (`tst_pages.qml`): `test_nav_on_each_section_page` (games, media, store, settings: nav visible, pill = page, gear filled only on settings, Up reaches the nav, Down returns to the same item), `test_nav_down_returns_to_the_same_item`, `test_bumpers_switch_sections_on_a_page`, `test_nav_hidden_on_detail_and_disabled_under_guide`; screenshot `test_zz_screenshots_settings`. Revert test: not run per test; the same-item assertion fails without `rememberFocus()` in `focusNav` (found that way while building), the pill assertion failed with the first `navSection` handler.

Files: shell/qml/Shell.qml, Page.qml, SectionNav.qml, shell/tests/tst_pages.qml, shell/i18n/ruyashell_en.ts and _tr.ts (line refs), docs/specs/02-shell.md, 04-design-system.md.
