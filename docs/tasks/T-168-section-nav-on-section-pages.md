# T-168 — Section nav on every section page

Status: todo · Phase: 2 · Depends: T-157 · Area: shell · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
