# T-206 — The Settings gear looks wrong when it is the active section

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
