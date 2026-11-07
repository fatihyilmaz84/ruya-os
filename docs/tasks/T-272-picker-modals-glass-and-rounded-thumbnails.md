# T-272 — Picker modals in glass, and rounded wallpaper thumbnails

Status: in-progress · Phase: 2 · Depends: T-198 · Area: shell · Size: S · Owner: builder

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
Verified: host

**Built.**
- `GlassSheet.qml` (new, 04 §5 row): the glass card of a picker modal. `glassStrong` over a blurred quarter-size crop of L0 through a `radiusL` mask, `GlassLayers` with `tint`, `GlassShadow` kind `panel`. Baked: the crop is a non-live `ShaderEffectSource` captured when `shown` turns true (and if the sheet resizes); `bakeCount` counts captures. `glassOpaque` on the Performance tier, with no L0 and on the software renderer (`blurred`, `fillColor`; `gpu` is overridable so a test reaches the blurred branch offscreen).
- `ModalLayer.qml` (new): the Shell's `modalLayer` is now one, with `glassSource: l0`; `GlassSheet` finds L0 by walking up its parents to a `ModalLayer`, so no pane or picker needed a new property (the pickers are already parented to it).
- `WallpaperPicker`, `ZonePicker`, `ModePicker` (resolution and refresh rate) use `GlassSheet` (same `objectName`s as before). Text on the glass is `text`: the zone "Loading" line and the wallpaper USB hint were `textDim`.
- Wallpaper tiles: `art` is an `Item` with `radius` = `radiusM * u`; its content (gradient, blobs, picture) is a hidden layer cut by a rounded mask through `MultiEffect` (as `CardFocusLayers`); on the software renderer the content is drawn unmasked (gradient still rounded). The hairline, the focus ring and the mask share the radius; the USB grid uses the same tile. The default tile now draws `Theme.blobTintA(Theme.defaultTint)` and `Theme.blobOpacityA` like the real Backdrop (lead's note; T-271 merged into this branch).
- Docs: 04 §3.6 (tint now used), §3.7 L3 row, §5 (new Glass sheet row; wallpaper, zone and mode picker rows).

**Not changed, on purpose.** `ProfilePicker` ("Who's playing?") has no panel: it is a full-screen chooser of profile cards on the backdrop, so there is nothing to put on glass. `PowerConfirm` and `ModeConfirm` are confirm dialogs, not pickers, and still draw `panel` (Inbox).

**Tests** (revert test: each failed when I undid its change). `Glass::test_sheet_is_opaque_glass_without_blur`, `test_sheet_blurs_the_modal_layers_source_on_the_gpu`, `test_sheet_is_baked_when_it_opens_not_every_frame` (revert: `tint: false`, and the open-time bake removed); `Wallpaper::test_the_panel_is_glass_and_the_thumbnails_are_rounded` (revert 1: flat `Rectangle` panel; revert 2: mask radius 0; also all five themes: fill is `glassStrong`/`glassOpaque`, never `panel`, tint shown, ring radius = tile radius + offset, Current badge inside the corner, USB grid masked); `TimeZone::test_the_picker_panel_is_glass` (revert: flat panel, plus focus on the regions, Back closes and focus returns to the row); a glass assertion in `Display` for the resolution picker. In `shots` (GPU) the wallpaper screenshot test asserts `blurred` is true and `bakeCount` is 1 (L0 found, one capture).

**Screenshots read** (`output\shell-shots\review\`): `70-wallpaper-picker.png`, `70-wallpaper-picker-daylight.png`, `70-wallpaper-picker-usb.png`, `70-wallpaper-picker-usb-daylight.png`, `17-settings-timezone-picker.png`, new `17-settings-timezone-picker-daylight.png`, `display-2-picker.png`, and for the profile picker `t209-daylight-1-picker.png`. Glass with blur, sheen and rim reads in Dreamglass and Daylight; the thumbnails, the hairline and the ring share one rounded shape (including the white "Bright" USB picture); the Current badge sits clear of the corner; text is `text`.

UX notes: states reached: library grid (focus on a tile, on the Add button), USB grid, zone regions/cities, resolution list. Focus, Back and key handling are untouched (the existing tests for them are green): Back closes (or leaves the USB grid), focus returns to the row. Nothing new takes focus; the sheet is decoration. Doubts: the dark themes' tint is 2.5:1 for `text` over pure white art (04 §3.6 "Plainly"), but the sheet samples L0, which on a page is the blurred and dimmed wallpaper, and the contrast gate does not cover this surface; on Daylight the glass is light with dark text and reads fine. The error colour of the USB copy message on the glass is not in the contrast gate either.

**Unverified:** the frame cost of the sheet on real GPU hardware (one baked quad plus the picture masks, 7 to 12 tile masks in the wallpaper grid); the Performance and Balanced tier looks were checked by property tests only, not screenshots.

