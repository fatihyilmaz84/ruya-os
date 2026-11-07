# T-271 — Colour themes that look different from each other

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host`._
