# T-434 - Glass follow-ups: Performance-tier rows opaque, the picker's idle blur texture, the page blur's GPU cost

Status: done · Phase: 2 · Depends: — · Area: shell (SettingControl, Backdrop, liquid pills), scripts (dell-glass-check) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
T-421's glass fix keeps its look at a lower GPU cost on the Dell, and the Performance tier follows 04 §3.6 ("glass without blur turns opaque") for the Settings rows too.

## Read first
- `docs/tasks/T-421-glass-has-no-blur-on-the-dell.md` (Outcome: the GPU table, `dell-glass-check.sh`), `docs/specs/04-design-system.md` §3.6, §3.8, principle 5
- `shell/qml/controls/SettingControl.qml`, `shell/qml/Backdrop.qml`, the liquid pill (`LiquidGlass`, `LiquidGate`), `scripts/dell-glass-check.sh`

## Scope
1. **Decided (lead, 2026-11-10):** on the Performance tier the Settings rows (`SettingControl.qml:52`, `Theme.glass` on every tier) use `glassOpaque`, like GlassPill and GlassSheet. Check every other translucent card for the same leak. Then reword the §3.6 sentence "never sits over a sharp blob edge" to match.
2. Backdrop: the blurred copy's live `ShaderEffectSource` is idle off pages (gate on `blurred || pageBlur.opacity > 0`), so the profile picker does not re-render it every frame.
3. The page blur's cost (Settings in active use is about 40 % GPU on the Dell, was 30 %): a smaller texture, or a baked copy while the blobs rest; keep the look (shots before and after).
4. Measure the liquid pills on the Dell (about 25 % GPU for 30 s after each input at Home) and write the number into 04 §3.8's "decide on the Dell" line; do not change the default.
5. `dell-glass-check.sh`: the step 3 comment is stale (the blobs rest after 30 s); add the picker and a Settings-in-use step.

## Out of scope
- New tokens; the Midnight contrast question (T-282).

## Acceptance criteria
- [ ] Item 1: a test that the rows use `glassOpaque` on Performance (red without the change).
- [ ] Item 2: a test that the live texture is off on the picker.
- [ ] hw (the builder may use the Dell): `dell-glass-check.sh` PASS with this branch's shell; GPU at Home still, Settings in use and the picker, before and after, in the Outcome.
- [ ] `dev.ps1 test` and `shots` ALL GREEN; changed shots reviewed (a Performance-tier Settings shot).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §3.6 and §3.8.

## Hints
- From the STATUS Inbox (T-421 and its reviews), planned by lead-9 on 2026-11-10. The Dell is a pure test machine (root `CLAUDE.md`); run a branch shell as T-421 did (its Outcome).

## Outcome
Verified: host (vm pending: dell-glass-check)
UX notes: states reached: Settings (Display & motion) on High and on Performance, the profile picker, Home, the Store's app page; nothing about focus or Back changed (asserted: Back from the category list lands on the section nav; the picker keeps `profileList` focus; on Performance the first row keeps focus and the focused row or button shows `focusFill`). Doubt: on Performance the rows are now near-opaque dark bars (`glassOpaque` 90 %), a visibly heavier look than the High tier's glass; that is what §3.6 asks. Seen in the Performance shot: the category list's selected and focused highlight (`selectedFill`/`focusFill`, the gliding highlight) stays translucent over the sharp blobs, as focus fills are on every tier (Inbox).

Builder: Opus 5.5, effort medium, round 1. No Dell access in this round (the lead's 0.0.62 build was running and the Dell is not on it): the GPU numbers are for the lead's `dell-glass-check.sh` run.

**Built:**
1. Performance-tier glass on L0 turns opaque: `SettingControl`'s fill (`rowFill`) is `glassOpaque` when `Theme.blurMax` is 0, like `GlassPill`; the other translucent surfaces that lie straight on L0 on a page got the same rule: the placeholder button (`ComingSoon`), the app page's buttons and progress track (`AppDetailPage`). Checked and left alone: tracks and switches inside rows (they sit on the row), surfaces on modals (on `panel`, `glassOpaque` sheets or the scrim). 04 §3.6's "never sits over a sharp blob edge" sentence now says: blurred L0 on High and Balanced, `glassOpaque` on Performance, on every tier no sharp edge through translucent glass on a page.
2. `Backdrop`: the quarter-size `ShaderEffectSource` is `live` only while `blurActive` or the copy still fades (`pageBlur.opacity > 0`), so on Home and the profile picker the drifting blobs no longer re-render it every frame.
3. Page blur cost: the `MultiEffect` is itself quarter-size (the texture's size) and drawn scaled up by a `Scale` transform, so its blur passes run at a sixteenth of the pixels instead of full size. `blurMax` is `round(Theme.blurMax / 3)` (21 High, 11 Balanced): measured against the old look in the `70-wallpaper-page-default-blurred` shot (before: main's Backdrop; after: this branch, same test, `output/t434/`, not in git): a quarter (16) was visibly tighter, a half (32) far softer, a third gives a mean luma difference of 0.83 over the whole screen and at most 4 levels in the L0-only left margin (the clock's minute is the only big difference). The look stays; the GPU saving is not measured (Dell).
4. 04 §3.8's liquid-pill line now carries the Dell number T-421 measured (about 25 %, 2564 ms render in 10 s, for the 30 s after each input at Home) and says `dell-glass-check.sh` step 2 measures it again; the default is unchanged. Not re-measured here (no Dell).
5. `scripts/dell-glass-check.sh`: header rewritten; steps now 1 Home still (PASS < 3 %), 2 Home a key 3 s before (informational: the pills), 3 Settings captures (PASS step < 6, as before), 4 Settings a key 2 s before (informational: drift, page blur, pills), 5 Settings still (now PASS < 3 %: the stale "the blobs drift there" is gone), 6 the profile picker via Guide and "Switch profile" (a key 2 s before, informational; then still, PASS < 3 %), then Accept signs the focused profile in again (`RUYA_PIN` typed if set). The uinput keyboard knows arrows, Enter, Guide (KEY_HOMEPAGE) and digits. Only `bash -n` was run here.

**Tests and revert checks (`revert-check.ps1`):**
- `tst_glass test_row_is_opaque_glass_without_blur` (High and Balanced `glass`, Performance `glassOpaque`, focused `focusFill`): red with the row's old `Theme.glass`.
- `tst_glass test_page_placeholder_is_opaque_glass_without_blur`: red with `ComingSoon`'s old `Theme.glass`.
- `tst_store_ui test_detail_buttons_are_opaque_glass_without_blur` (Uninstall and the progress track `glassOpaque` on Performance, the focused primary keeps `focusFill`): red with the ActionButton's old fill.
- `tst_shell test_page_blur_texture_is_idle_off_pages` (picker: not live; Settings: live; back on Home after the fade: not live) and the new `live` assertions in `tst_wallpaper test_the_default_look_is_blurred_on_pages`: both red with `live: true`.
- `tst_wallpaper test_the_default_look_is_blurred_on_pages` now checks the quarter size, that the scaled copy still covers the screen, and the blurMax: red with the effect at full width.
- `shots` `tst_wallpaper test_zz_performance_page_rows_are_opaque` (new, GPU): Performance Settings shot `70-wallpaper-page-default-performance.png`, an unfocused row `glassOpaque`.
- Changed premise: `test_the_default_look_is_blurred_on_pages` asserted `blurMax` 64 / 32 on the backdrop's effect; it now asserts 21 / 11 at a quarter size, which is the same look (measured above), not a weaker check.

**Checks:** `dev.ps1 test` ALL GREEN (1067 Qt Quick passed, 90 skipped; Rust green); `dev.ps1 shots` ALL GREEN (172 passed); reviewed `70-wallpaper-page-default-performance.png` (new: opaque rows, no blob edge through them) and `70-wallpaper-page-default-blurred.png` (the High page, the same look as before).

**Files:** `shell/qml/controls/SettingControl.qml`, `shell/qml/ComingSoon.qml`, `shell/qml/AppDetailPage.qml`, `shell/qml/Backdrop.qml`, `shell/tests/tst_glass.qml`, `shell/tests/tst_store_ui.qml`, `shell/tests/tst_shell.qml`, `shell/tests/tst_wallpaper.qml`, `scripts/dell-glass-check.sh`, `docs/specs/04-design-system.md` (§3.6, §3.8, Backdrop row), `docs/specs/02-shell.md` (tiers paragraph).

**Unverified:** the hw criterion (`dell-glass-check.sh` PASS with this branch, GPU at Home still, Settings in use and the picker, before and after): pending the lead's run on the Dell; the script's new steps (Guide, the picker, re-sign-in) never ran against a real shell. The page blur's GPU saving and the liquid-pill number are not measured by this task.

**Deviations:** WallpaperLayer's page blur has the same full-size `MultiEffect`; left as it is (the task names the default look's blur; Inbox).
