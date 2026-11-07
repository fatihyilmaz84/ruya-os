# T-271 — Colour themes that look different from each other

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
Dreamglass, Midnight, Aurora and Ember are recognisably different at a glance on the Home screen, in Settings and under an open app's overlays; today only Daylight is. Owner feedback, 2026-11-07: "there doesn't seem to be much difference between themes, only Daylight makes a huge difference". The contrast gate (04 §7, `tst_theme_contrast.qml`) must still pass for every theme.

## Read first
- `docs/specs/04-design-system.md` §3.1 (Colour, Themes), §7 (contrast gate), §8; the lead's note in STATUS Inbox (T-209: dark themes over bright art, avatar palette vs themes)
- `shell/qml/themes/ThemeSet.qml`, `Themes.qml`, `ThemeMath.qml`, `Theme.qml` (which tokens are themeable), `Backdrop.qml` (the three blobs: where their colour comes from), `shell/tests/tst_themes.qml`, `tst_theme_contrast.qml`
- The T-209 screenshots (`output/shell-shots/review/` theme set) for the current look; `shell/CLAUDE.md`

## Scope
1. **Measure first:** put the five themes' Home and Settings screenshots side by side (a small script or the existing shots) and write down in the Outcome why they look alike (guess: the ground and the glass are all near-black with a slight hue, the Backdrop blobs take the focused tile's tint in every theme, the focus fill and accents are the same white/indigo).
2. **Give each dark theme its own character** within the existing themeable token set (no new token unless the spec change comes along, §8; a new token is allowed if it is the only way, named in the Outcome and added to 04):
   - **Dreamglass:** unchanged, the reference.
   - **Midnight:** true black ground, neutral grey glass with no hue, blobs very faint and neutral (the tile tint barely shows), crisp white focus: an OLED look.
   - **Aurora:** a visibly teal/green ground and glass, blobs in teal, green and violet whatever the focused tile's tint is (blend the tile tint at a low share), teal focus/selection accent.
   - **Ember:** a visibly warm ground, copper glass, blobs in red, amber and copper, warm accent.
   The blobs' own colours per theme are the biggest lever (a theme-level blob palette mixed with the tile tint at a share); the glass tint chroma and the `primaryFill`/selection accent are the next.
3. A **distinctness test**: `tst_themes.qml` asserts that the themes' ground, glass fill, blob palette and accent differ pairwise by at least a documented colour distance (ΔE or RGB distance on `ThemeMath`), so a future edit cannot flatten them again.
4. Update the spec table (04 §3.1) with the new looks and the screenshot list in the Outcome (before/after per theme, Home + Settings + one modal).

## Out of scope
- New themes, per-profile themes, wallpapers (T-208), High-contrast, changes to Daylight beyond keeping its contrast gate, changing the default theme.

## Acceptance criteria
- [ ] `tst_themes.qml::test_themes_are_pairwise_distinct` (or similar) fails when two themes' key colours are made equal (name the revert in the Outcome).
- [ ] `tst_theme_contrast.qml` still passes for all five themes with no threshold lowered.
- [ ] Screenshots: Home and Settings in each theme, read against 04 §7/§8; the five are distinguishable at half size.
- [ ] UX: switching theme keeps focus where it was; the 700 ms cross-fade still works; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `04-design-system.md` §3.1 (theme table, accents), canvas-board note if a token was added.

## Outcome
Verified: host

UX notes: states reached are the existing theme screens in every theme (picker, PIN pad modal, Home, Guide overlay, Settings -> Display & motion), nothing new was added. Switching theme in the Theme row keeps focus on the row after four switches and a wrap (`tst_themes.qml::test_theme_row_switches_the_screens_in_place_and_keeps_focus`, unchanged and green); Back (Escape) leaves the pane to the category list in Daylight as before. The 700 ms cross-fade still runs and now covers the new tokens (`test_blob_tokens_cross_fade`: mid-fade the share is between 1 and Aurora's 0.2 and the blob has left the tint; `test_switch_cross_fades_over_tintMs`, `test_reduced_motion_during_a_fade_finishes_it` unchanged). Doubts: (1) on Home the dominant colour is the focused item's hero art (here the placeholder field of Portal 2, purple in all themes), which no theme owns, so Home differs by the lower ground, the left scrim, the pills, the Play button, the focus ring and the hint badges rather than by the whole screen; Settings, the PIN pad and every page without art differ by the whole screen. (2) Dreamglass still takes the profile's tint completely (that is the reference), so with a red profile (Ada's avatar in the shots) Dreamglass and Ember both read red at a glance; Ember's blobs are orange, amber and copper over a brown ground, so they stay apart side by side. (3) The ring is now tinted in Aurora (mint) and Ember (peach); it is still a light ring that never carries focus alone.

**Why they looked alike (measured on the T-209 shots of Home and Settings, Ada signed in).** The dark themes' ground and gradient bottom were `#05070d`, `#000`, `#04121a`, `#0d0605` (delta E 2 to 6 from each other), their glass fills white or near-white at 12 %, their focus ring, fills and Play button all white-ish, and, the biggest cause, the three Backdrop blobs and the gradient top were built from the profile's avatar colour in every theme (`Backdrop.tint`), so the same red wash at 55/35 % filled Settings in all four. Only Daylight changed the lightness. Fixed by the levers in the task, in this order of size: a theme-level blob palette mixed with the profile tint at a share; hue in the ground, `glassOpaque`/`panel`/`glassTint` and the glass fills; ring, fills and `primaryFill`; hero/caption scrims.

**What was built.** Two colour tokens `blobA`, `blobB` (the theme's own colours of the first two blobs; `blobHighlight` was already the third) and one number `blobTintShare` (share of the profile's tint in the first two blobs and the gradient top), added to `ThemeSet.qml`, `Themes.tokenNames`, `Theme.qml` (`blobA`, `blobB`, `blobTintShare`, `blobTintA()`, `blobTintB()`) and 04 §3.1. They were the only way (a theme could not otherwise stop the profile tint from filling the blobs). `ThemeMath` got `blobTint`, `backdropSamples` (moved from the contrast test so the gate and the shell share one formula), `lab`, `deltaE` and `lookColors`. `Backdrop.qml` builds the blobs and the gradient top from `tintA`/`tintB`. Share 1 (Dreamglass, Daylight) returns the tint itself, so those two are unchanged pixel for pixel (`test_dreamglass_is_todays_palette` and the Daylight backdrop test pass unchanged). Midnight: black ground, grey `#191919` glass, blobs `#7a7a7a`/`#666666` at strength 0.4 and share 0.08, pure white primary. Aurora: ground `#04211e`, teal glass tint, blobs teal `#1aa890`, green `#2fa85c`, violet `#9b80f0`, strength 0.55, share 0.2, mint ring/fills, teal primary `#5eead4`, teal hero scrim. Ember: ground `#1c0c07`, copper glass, blobs `#d65a24`, `#c9892a`, `#ffb070`, strength 0.66, share 0.2, peach ring/fills, copper primary `#ffa866`, brown hero scrim. Colours were tuned with a Python port of the gate (`output/gate.py`, not committed) and confirmed by the real gate; `text`, `textDim`, `errorText`, `warningText` are unchanged, a few `toastInfo`/`toastSuccess` and `textDim` values in Aurora were lightened and its `panel`/`glassOpaque` darkened to keep the gate. No threshold was lowered and no row was removed.

**Distinctness test.** `tst_themes.qml::test_themes_are_pairwise_distinct`: `ThemeMath.lookColors` takes the ground (middle of the backdrop gradient at the `defaultTint`), the glass (`glassOpaque` over the ground), the blobs (overlap of the three) and the accent (`primaryFill`); each pair of the five themes must differ by CIE76 delta E >= 10 in at least 3 of the 4 and >= 80 in total. Today's smallest pair, Dreamglass/Midnight, is 88.7 total (ground 16.9, glass 13.6, blobs 53.8, accent 4.4); the others are 117 to 265. Revert test: I made Ember's `background`, `glassOpaque`, `blobA`, `blobB`, `blobHighlight`, `defaultTint` and `primaryFill` equal to Aurora's: the test failed with "aurora / ember: ground 0.0, glass 0.0, blobs 4.5, accent 0.0". I also undid `Backdrop.qml` (blob A back on `tint`): `test_blob_colours_belong_to_the_theme_not_the_profile_tint` and `test_blob_tokens_cross_fade` failed. `test_distinctness_measure_catches_a_flattened_theme` proves in-file that two equalised themes are caught by the measure.

**Screenshots** (`output\shell-shots\review\`, half size, file `t209-<theme>-<n>-<name>.png`, n: 1 picker, 2 PIN pad (modal), 3 home, 4 Guide overlay (modal), 5 settings). After: all 25 from this task's `shots` run, read: aurora 2, 3, 5; ember 3, 4, 5; midnight 3, 5; dreamglass 5. Before: `output\before\t209-*.png`, copied from the main checkout's `output\shell-shots\review` (a `shots` run of 2026-11-07 12:21, main at that time; nothing after it touched colours or the backdrop), same names per theme: dreamglass, midnight, aurora, ember, daylight. Daylight is unchanged (its shots are the same look; I did not re-read them). The five are distinguishable at half size in Settings (grey/black, teal-green, copper-brown, profile colour, pale) and on the PIN pad; on Home they differ at the lower half, the pills, the buttons and the ring (see Doubts 1). `shots` ALL GREEN (127 passed).

Canvas board to update when the owner next syncs the design canvas: Foundations / Colour themes (Midnight, Aurora, Ember rows and the two new blob tokens).

Files: `shell/qml/themes/{ThemeSet,Themes,ThemeMath}.qml`, `shell/qml/{Theme,Backdrop}.qml`, `shell/tests/{tst_themes,tst_theme_contrast}.qml`, `docs/specs/04-design-system.md` (§1 principle 2, §3.1 table and the themeable list, §4 ring colour, §7 gate text).
