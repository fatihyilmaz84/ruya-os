# T-283 — Contrast gate rows: glass sheet, chart bars, saver, bare backdrop, avatars; the chart's read-bar marker

Status: todo · Phase: 2 · Depends: T-282 · Area: shell (tests, Theme, BarChart) · Size: M · Owner: builder

## Goal
The contrast gate (`tst_theme_contrast.qml`, 04 §7) measures every text and chart surface review rounds found unmeasured, in all five themes, and the values T-282 decided are in `Theme`. The bar being read in a chart is visibly marked.

## Read first
- `docs/specs/04-design-system.md` §7 (the T-282 wording), §5 (BarChart)
- `shell/tests/tst_theme_contrast.qml`, `ThemeMath` (the shell's contrast arithmetic, used by `Theme.qml` and the test), `shell/qml/BarChart.qml`, `shell/qml/GlassSheet.qml`, `shell/qml/ScreenSaver.qml`, `shell/qml/ProfileCard.qml` (avatar)
- STATUS-parked.md, "Inbox triage 2026-11-07", bullets T-283

## Scope
1. **New gate rows** (each in all five themes, over white and black art where art is behind): `GlassSheet` text and `errorText` on the sheet; chart bars and the zero-bar (3:1 as a graphical object) against the panel in Dreamglass, Midnight, Aurora, Ember, Daylight (only Dreamglass was measured); `ScreenSaver` clock and text; text on the bare `Backdrop` (Setup, picker); avatar initials for every colour of the avatar palette per theme (T-282 item 3); the peek rows incl. over a wallpaper, with the group-opacity assumption fixed or measured (T-282 item 11).
2. **Apply the T-282 values** for items 1-3 in `Theme` / `themes/` (glass tint on sheets, hero-art lightness cap or dim rule, the avatar initial token). No other colour changes.
3. **BarChart marker:** the bar being read stands out without colour alone (today its `focusRing` outline equals the `text` bar fill at 70 %): a ring outside the bar or a DemiBold label, per T-282/04. Zero-bar opacity `0.6` becomes a `Theme` token.

## Out of scope
- New themes, the High-contrast theme, the theme-tinted hero scrim (T-282 decides; a task follows). Cards and art glow (T-281).

## Acceptance criteria
- [ ] Every row of Scope 1 is a named case in `tst_theme_contrast.qml` and passes for all five themes; the Outcome lists the measured worst ratio per row.
- [ ] Revert checks recorded: restoring the old `glassTint` (44 %) makes the sheet-text row red; removing the avatar token makes the avatar row red (use `scripts\revert-check.ps1` if it fits).
- [ ] `tst_activity.qml::test_read_bar_marker`: the read bar has a marker item that the other bars lack, and it is not only a colour change.
- [ ] Screenshot `output/shell-shots/review/` of the Activity chart under Daylight and Ember shows the marked bar (reviewed).
- [ ] UX: from every new state Back leaves; focus lands sensibly; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN, `dev.ps1 shots` reviewed.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 04 §7 (rows now gated), §5 BarChart.

## Hints
- Overlaps T-284 (GlassSheet.qml) and T-281 (Theme.qml): run after T-281 merges; do not run beside T-284.
- A row that fails after the T-282 values is a finding: fix with the decided value, do not lower the floor.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
