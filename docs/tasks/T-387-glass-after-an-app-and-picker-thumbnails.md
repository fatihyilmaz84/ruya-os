# T-387 - Glass sheets lose their blur after an app was in front; wallpaper picker tiles stay blank

Status: done · Phase: 2 · Depends: — · Area: shell (Shell.qml L0, GlassSheet, WallpaperPicker) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
After a game has been in front, Settings' glass sheets are blurred again (not flat grain), and every wallpaper tile shows its picture. Owner report 2026-11-09 (Dell 0.0.60); diagnosed by lead-8 on the Dell with KMS captures and an A/B against 0.0.59.

## Findings (lead-8)
- **Glass (regression, T-376):** `Shell.qml` `l0` got `visible: !root.appOpen`. After an app was in front and left, `GlassSheet`'s baked crop (`live: false`, `sourceItem` L0, `GlassSheet.qml` ~99-102) comes out empty: the sheet is flat grey with grain. 0.0.59 with the same steps stays blurred; the live nav pill is fine. Packages of both images are identical, so L0's `visible` is the only change.
- **Picker tiles (old, race):** `WallpaperPicker.qml` ~333 `visible: status === Image.Ready` on an async Image inside `artContent`, which is `visible: false` with `layer.enabled` (feeds `SmoothMask`). A tile ready only after the first frame never shows. Seen on 0.0.59 too.

## Scope
0. **Reproduce first on real windows** (`shots`, GPU): a case that opens Settings > Display > Wallpaper, puts the stand-in app in front (`shell.addApp`) for a moment, removes it, opens the picker again, and checks the sheet's baked crop is not empty (for example `grabToImage` of the sheet: its pixels must not be one flat colour; pixel checks are allowed in `shots`, never offscreen). Red on main first. Lead's hypothesis: an item hidden with `visible` and shown again loses its scene-graph nodes for a `live: false` bake (and the same class hides the tiles); `opacity: 0` is culled by the renderer but keeps the nodes. Prove or reject it.
1. L0 behind an app: keep T-376's goal (nothing drawn or sampled behind an app) without toggling `visible` on L0 (for example `opacity` 0, or hide L0's children), and make the baked crop re-bake on the next opening.
2. Tiles: no `visible` binding on the async Image (an Image that is not ready draws nothing).
3. Tests: offscreen property tests (L0 not drawn while an app is in front, the sheet re-bakes after the app leaves, a tile's Image is visible while it loads); a `shots` case: stand-in app in front, then gone, then the picker (the sheet must match a fresh opening by eye).

## Acceptance criteria
- [ ] QML tests above, each red without its fix; T-376's tests still say nothing is drawn behind an app.
- [ ] `dev.ps1 test` and `shots` ALL GREEN; screenshots of the picker and the sheet after an app reviewed.
- [ ] hw (lead, Dell 0.0.61): the steps of the finding (picker, an app in front, picker again) show the blurred sheet; every tile has its picture.

## Outcome
Verified: host (hw pending: Dell 0.0.61, the finding's steps)
UX notes: states reached in `shots`: picker fresh, closed, an app in front for 1.5 s, gone, picker again (and the same without the app). Focus returns to the Wallpaper row when the app leaves (asserted) and the grid takes it when the picker opens (asserted by `openPicker`). Back closes the picker as before. Doubt: the Dell's 0.0.59/0.0.60 A/B does not match this host (below).

Builder: Opus 5.5, effort medium, round 1.

**Reproduced on this host's GPU first (scope 0).** New `shots` case `Wallpaper::test_zz_sheet_after_an_app` (data rows `reopened`, `app`): opens the picker over Daybreak, samples the sheet's glass in its left margin (11 pixels from `grabImage`), closes it, optionally puts a stand-in app in front for 1.5 s and removes it, opens the picker again and requires the same pixels within 12 per channel. Red on main (fresh ~[65,67,74] vs again ~[28,27,31], max difference 43): the sheet is flat dark grey with grain, and **every tile was blank, also on the first opening** (`70-wallpaper-picker-fresh-*.png`).

**The lead's hypothesis (L0's `visible` toggle) is rejected on this host.** With L0 on opacity alone the `app` row stayed red; the `reopened` row (no app at all) was red too. Bisection: keeping the sheet's mask layer on (`layer.enabled: sheet.blurred`) made both rows green; with the real fix below and L0 put back to `visible: !root.appOpen` both rows are green as well, so here the cause is only the mask. **Cause:** since T-349 the sheet's mask `Rectangle` turns `layer.enabled` off when the sheet is released and on at the next opening, while `SmoothMask.maskSource` stays the same item; MultiEffect keeps the first layer's texture provider, so after the first opening the mask is empty and the blur is masked away. T-349 is older than 0.0.59, so on this host 0.0.59 would show it too; why the Dell's 0.0.59 stayed blurred is not explained here (possibly a scene-graph reset when the app takes the screen there). Unverified until the Dell run.

**Built:**
- `GlassSheet.qml`: `maskSource: mask.layer.enabled ? mask : null` (each opening hands MultiEffect the new layer; T-349's "no texture while closed" kept). New `sourceDrawn` (L0 visible and opacity > 0): no capture while L0 is not drawn, and an open sheet captures again when L0 comes back (`onSourceDrawnChanged`).
- `Shell.qml`: L0 is hidden behind an app by `opacity: 0` instead of `visible: false` (scope 1, as the Dell A/B suggests; the renderer draws nothing of an opacity-0 subtree and L0 keeps its scene-graph nodes; L0's own layer textures may stay allocated while an app is in front). Not needed for the fix on this host (see above); kept for the Dell evidence.
- `WallpaperPicker.qml`: no `visible: status === Image.Ready` on the tile's async Image (an Image not ready draws nothing); `objectName` `wallpaperTileImage_<id>`. Tiles show their pictures in `shots` now.
- Specs: `04` §3 glass paragraph (L0 at opacity 0, `sourceDrawn`), `04` component table row Glass sheet (mask hand-off, re-capture), `02` behind-an-app line and the picker thumbnails.

**T-376's tests (tst_sound_ui):** `test_l0_is_hidden_behind_a_focused_app` and `test_no_effect_samples_a_hidden_layer` asserted `visible` of L0's children; with L0 at opacity 0 their effective `visible` stays true, so they now assert `drawn(item)`: the item and every ancestor up to the shell are visible **and** above opacity 0. That is the same guarantee: the scene graph treats a subtree under an opacity node at 0 as blocked (`QSGOpacityNode::isSubtreeBlocked`) and draws nothing of it, as for an invisible one (that its layers' preprocess is skipped too is from reading Qt, not measured here); the pill/nav checks are unchanged, and the first test also pins `l0.opacity === 0` at once.

**Tests and revert checks (`revert-check.ps1`):**
- `tst_glass test_sheet_hands_the_new_mask_layer_to_the_blur_on_every_opening` (two openings: maskSource is the mask while its layer is on, null after release): red with `maskSource: mask` restored.
- `tst_wallpaper test_the_sheet_captures_again_after_an_app` (gpu forced: L0 opacity 0 but `visible`, `sourceDrawn` false, no capture then, one capture after the app leaves): red with L0 back on `visible: !root.appOpen`, and red with `onSourceDrawnChanged` removed.
- `tst_wallpaper test_a_tile_picture_is_not_hidden_while_it_loads` (every tile's Image visible whatever its status; the default tile is `Null`): red with the `visible: status === Image.Ready` binding restored.
- `shots` `test_zz_sheet_after_an_app`: red on main (above), green with the fix.
- `test_the_panel_is_glass_and_the_thumbnails_are_rounded` reads the sheet blur's `maskSource.layer`; offscreen the sheet is not blurred, so the mask is now null there: the test sets `panel.gpu = true` for that check (the blurred branch, where the hand-off exists) and puts it back. Not weakened: it checks the same smooth-layer property on the branch that has it.

**Checks:** `dev.ps1 test` ALL GREEN (1021 QML passed, 81 skipped; 851 Rust). `dev.ps1 shots` ALL GREEN (160); reviewed `70-wallpaper-picker-again-app.png` (blurred sheet like the fresh one, every tile with its picture), `70-wallpaper-picker-fresh-reopened.png`, `70-wallpaper-picker-usb.png`. Scratch note: experiments were made by overwriting my own `shell/qml/GlassSheet.qml` and `Shell.qml` and restoring them with `cp output/*.bak` (this worktree only).

**T-359 keyboard (lead hint):** not the same cause. `TextEntry.qml` has no glass sheet and samples nothing; its field and keys are translucent `Theme.glass` over the `scrim`, so a busy page shows through (and that shot is taken 500 ms into a 300 ms fade, so it is settled). Inbox line below.

Files: `shell/qml/GlassSheet.qml`, `shell/qml/Shell.qml`, `shell/qml/WallpaperPicker.qml`, `shell/tests/tst_glass.qml`, `shell/tests/tst_sound_ui.qml`, `shell/tests/tst_wallpaper.qml`, `docs/specs/02-shell.md`, `docs/specs/04-design-system.md`.
