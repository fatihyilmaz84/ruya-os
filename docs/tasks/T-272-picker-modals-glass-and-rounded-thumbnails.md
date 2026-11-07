# T-272 — Picker modals in glass, and rounded wallpaper thumbnails

Status: todo · Phase: 2 · Depends: T-198 · Area: shell · Size: S · Owner: builder

## Goal
The wallpaper picker looks like the rest of the shell: its panel is glass, and its thumbnails are rounded to the same shape as the selection hairline and the focus ring around them. Owner feedback, 2026-11-07: "the wallpaper select popup isn't styled (no glass). the selected item has a border while the image is square". The other picker modals follow the same rule so none of them stays flat.

## Read first
- `docs/specs/04-design-system.md` §3.6 glass (blur + sheen + rim + tint; "glass always comes with blur, or it turns opaque"), §3.7 layers (L3 modals: scrim + `panel`) and the "Bake, don't redraw" rule for sheets and modals, §4 focus ring, §8
- `shell/qml/WallpaperPicker.qml` (the panel is a plain `Theme.panel` rectangle; the thumbnail `Image` sits in a `clip: true` rectangle, which in Qt does **not** round the corners, so the picture is square inside a rounded ring/hairline), `GlassPill.qml`, `GlassShadow.qml`, `CardFocusLayers.qml` (existing `maskSource` / rounded-corner technique), and the modal sheets that already are glass (find them: Guide overlay, `PowerConfirm`, `ModeConfirm`, `Dialog`, keyboard) to reuse their sheet component
- `shell/PATTERNS.md` (modals), `shell/CLAUDE.md` (offscreen has no `MultiEffect`: assert properties, never pixels)

## Scope
1. **Glass panel:** `WallpaperPicker`, `ZonePicker`, `ProfilePicker`, `ModePicker` (T-198) and any other picker modal that still draws a flat `panel` use the shell's existing glass sheet (blur baked once on open, sheen, rim, tint; opaque `glassOpaque` fallback on the Performance tier and in software rendering). Reuse; add a component only if none fits and then add its row to 04 §5 in the same commit. One shared `PickerSheet` (or the existing sheet) is better than five copies.
2. **Rounded thumbnails:** the `Image` in each wallpaper tile is clipped to the tile's `radiusM` (a rounded mask, as `CardFocusLayers` does; software fallback: draw the image without the mask), so the hairline "selected" border, the focus ring and the picture share one shape. Same check for the USB pictures grid and the "Current" badge position.
3. Theme check: glass reads in all five themes (Daylight included); text over the glass keeps `text`, never `textDim` on glass (04 §3).

## Out of scope
- New wallpapers, the picker layout, the copy flow, other modals that are already glass.

## Acceptance criteria
- [ ] A test asserts (properties, not pixels): the picker panels use the glass sheet component / `Theme.glass*` tokens and not a flat `Theme.panel` fill, and the thumbnail mask radius equals `Theme.radiusM * u` (named revert: use the flat panel again, drop the mask radius).
- [ ] Screenshots (`shots`, GPU) of the wallpaper picker (library and USB), the zone picker and the profile picker in Dreamglass and Daylight, read against 04 §7/§8: glass visible, thumbnails rounded with the ring hugging them.
- [ ] UX: focus, Back and the 15-second-style behaviours of the pickers unchanged (existing tests stay green); Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `04-design-system.md` §5 (picker rows) and §3.7 if the layer wording changes.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
