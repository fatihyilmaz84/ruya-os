# T-206 — The Settings gear looks wrong when it is the active section

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
The gear pill in the top bar (`SectionNav.qml`, the `Icon { name: "settings"; filled: pill.isSection }`) is crisp, centred, the same visual size as in its inactive state and clearly legible on the white active pill. Owner report, 2026-11-06 (first real-hardware run): "the settings gear icon is rendered bad when it's active".

## Evidence
- The review screenshot `output/shell-shots/review/10-settings-profiles.png`, enlarged: the active gear is small (about a third of the pill), soft and low-contrast, a muddy filled gear whose inner hole and teeth have almost no clear counter-shapes. (That screenshot also has the profile picker dimming the shell, so judge the real colours on the GPU shots and on the Dell.)
- Both icon cuts are made at `opsz 40` (`scripts/subset-icons.sh`: `FILL 0` outlined and `FILL 1` filled, `wght 400`, `GRAD 0`, `opsz 40`). A large optical size draws thin strokes and tight details meant for big sizes; the filled gear at the nav's small pixel size has little left to render. Hypotheses to check, in order: the optical size for small use, the pill's glyph size (`Icon.size` x `u`), grey-on-light contrast (`onPrimary` on `primaryFill`), and font hinting/antialiasing under `eglfs`.

## Scope
1. Reproduce at real size: `dev.ps1 shots` on the GPU, crop the pill at 1:1 (not the half-size review copy), for 1080p and a 720p window, inactive/active/focused, English and Turkish.
2. Find the cause and fix it the least invasive way. Candidates: cut the **filled** font at `opsz 24` (or both cuts) and re-run `scripts/subset-icons.sh`; make the active state use the *outlined* glyph at a heavier `wght` instead of the filled one (the white pill is already the "selected" cue); enlarge the glyph for the nav (a token for the nav icon size in `04` §3.7); or change the colour pair. Whatever is chosen applies to every filled use of `Icon` (check the `filled` users) and is recorded in `04` §3.7.
3. A test that fails when the active gear is unreadable: assert the active and inactive glyph sizes are equal (same pixel size token) and the colour pair has contrast >= 4.5:1 (computed from `Theme.onPrimary` / `Theme.primaryFill`).

## Out of scope
- New icons, a different icon set (ADR-013), restyling the nav pills (T-205 changes how they highlight).

## Acceptance criteria
- [ ] 1:1 screenshots of the gear (inactive, active, focused) read against `04` §8: crisp, centred, same visual size, clear counter-shapes; before/after crops are described in the Outcome.
- [ ] `tst_icon.qml` / the nav tests: equal glyph size in both states; contrast >= 4.5:1 for the pair used.
- [ ] `lint-icons` passes; if the fonts were re-cut, the TTFs and the licence file are committed with the script change.
- [ ] Hardware (lead, the Dell): the owner confirms the gear looks right on the real screen.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `04-design-system.md` §3.7 (optical size / nav icon size), `docs/dev-setup.md` "Adding an icon" if the cut changes.

## Outcome
Verified: host (hardware check pending: the owner looks at the real screen on the Dell)

**Cause.** None of the hypotheses in Evidence (optical size, glyph size, contrast, hinting). Size and colours were already right: the active gear is `iconM` like the inactive one and `onPrimary` on `primaryFill` is about 18:1. The 1:1 crops (`dev.ps1 shots`, GPU window, 1080p and 720p) showed a **broken glyph**: the filled cut was speckled with white holes and notches inside the body and teeth. In the variable font the filled gear (and three more of the six icons) is drawn as two coincident contours of opposite direction that cancel in the nonzero fill rule; `fontTools.varLib.instancer` kept both, and the Windows rasteriser leaves holes where their edges meet. (On the Dell under eglfs the renderer is FreeType; I could not run that here, so whether it shows the same speckle there is the thing to look at.)

**Fix.** `scripts/subset-icons.sh` now cuts both fonts with `--remove-overlaps` (skia-pathops 0.9.2, installed into a throwaway venv in the script's temp directory) and the two TTFs are re-cut. The outlined gear loses one degenerate zero-area contour and looks the same; the filled gear is now two contours (outer shape and the hole). No change to `Icon.qml`, `SectionNav.qml`, the optical size, the pill sizes or the colours, so no new token. The licence file is unchanged (the script rewrites the same bytes).

**Before and after (1:1 crops, `output/before-1080.png`, `after-1080.png`, `after-720.png` in this worktree, not committed).** Before: the active and focused gear is a muddy black cog with white speckles and notches through the body, the teeth have ragged edges, the hole is the only clean counter-shape. After: a solid black cog on the white pill with six clean rounded teeth and a round hole, centred, the same height as the outlined gear in the inactive pill, at 1080p and at 720p, with and without the focus ring (the ring sits outside the white pill); the Turkish crops are the same (the gear does not depend on the language). The real shell, `22-settings-audio.png` at 1:1, shows the same clean gear.

**Tests.**
- `tst_icon.qml::test_active_gear_has_the_inactive_size_and_enough_contrast`: the nav gear's glyph pixel size and item height are equal in the inactive and active state at u = 1 and u = 2/3, the gear is `iconM x u`, its active colour is `Theme.onPrimary`, and `onPrimary` on `primaryFill` and `text` on `background` are at least 4.5:1 (WCAG ratio computed in the test). Revert test: I temporarily gave the active gear `size: 30` in `SectionNav.qml`; it failed with "the active gear keeps the glyph size at u 1".
- `scripts/check-font-coverage.py` (already run by `dev.ps1 shell`/`test` and CI) now also fails when an icon cut has a glyph with two contours of the same points. Revert test: with the old filled cut it fails on four glyphs (four of the six icons, the gear among them), with the new cuts it passes. This is the test that catches the real defect: the offscreen renderer (Qt's own rasteriser) does not reproduce the speckle, so a pixel test passed with the old font too and I dropped it rather than ship a test that cannot fail.
- `tst_icon.qml::test_zz_screenshots_gear` (runs only under `shots`): saves the gear pill at 1:1 for 1080p and 720p, English and Turkish, inactive / active / focused / focused-inactive, to `output/shell-shots/gear-*.png`.

**Checks.** `dev.ps1 test` ALL GREEN (421 QML passed, 39 skips that are the screenshot tests, Rust all ok); `dev.ps1 shots` ALL GREEN (84 passed).

**For the Dell (lead run).** Open Settings: the gear in the top bar should be a solid dark cog on the white pill with a clean round hole, the same size as the outlined gear when Home is current; check it focused (white ring outside the pill) and at 720p if the Dell can run it. If it still looks bad on the real screen the next hypothesis is FreeType hinting or antialiasing under eglfs, not the font.

Files: `scripts/subset-icons.sh`, `shell/fonts/MaterialSymbolsRounded.ttf`, `shell/fonts/MaterialSymbolsRoundedFilled.ttf`, `scripts/check-font-coverage.py`, `shell/tests/tst_icon.qml`, `docs/specs/04-design-system.md` (3.7), `docs/dev-setup.md` (Adding an icon).

Deviations: none from the Scope except that the cause was the font cut's overlapping contours, not one of the listed candidates; the "nav icon size token" candidate was not needed.
