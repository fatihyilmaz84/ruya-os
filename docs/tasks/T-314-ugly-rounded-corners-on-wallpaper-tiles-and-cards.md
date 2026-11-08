# T-314 — Rounded corners of the wallpaper tiles and the cards look rough

Status: done · Phase: 2 · Depends: — · Area: shell (WallpaperPicker, AppArt, the card family, CardFocusLayers) · Size: M · Owner: builder

## Goal
The owner (2026-11-08) looked at the wallpaper chooser and said the tiles have **ugly corners**, and thinks the cards (Store, Library, Home) have the same problem. Find out exactly what is wrong on a GPU render and make every picture-carrying rounded shape (wallpaper tiles, `AppArt`, the cards, their hairline and focus ring) have clean, smooth, consistent corners at 720p, 1080p and 4K.

## Read first
- `docs/specs/04-design-system.md` §5.2 (the card family, T-281) and the wallpaper chooser rows; `shell/qml/WallpaperPicker.qml` (~lines 260-430: the tile art, `artMask`, `MultiEffect` mask, the hairline and focus ring radii), `shell/qml/AppArt.qml` (`imageMask`, `layer.smooth`, `layer.effect: MultiEffect`), `shell/qml/CardFocusLayers.qml`, `Theme.qml` (`radiusM`, `focusRingOffset`, `glowPad`)
- T-281 Outcome and its reviews (art-colour glow, rounded AppArt, the picture mask); T-204/T-205 for how layers and the glow are drawn
- Rendering rules: offscreen tests use the software renderer where `MultiEffect` draws nothing; only `.\scripts\dev.ps1 shots` renders on the GPU (root `CLAUDE.md`, Rendering)

## Scope
1. **Reproduce and diagnose.** Run `.\scripts\dev.ps1 shots`, open the full-size PNGs (not the half-size review copies) of the wallpaper chooser and of Store, Library and Home cards, and zoom the corners (crop and enlarge 4x). Write down in the Outcome what you see: jagged (aliased) mask edges, a dark or light fringe or halo, the picture's corner not matching the hairline or the focus ring radius, the glow clipped, a seam between the picture and the border, softness from a low-resolution layer texture. Check both focused and unfocused tiles and a light (Daylight) and a dark theme.
2. **Fix the cause, not one symptom.** One shared solution where possible (candidates: a mask with `layer.samples` / `antialiasing`, a larger `layer.textureSize` for the mask or the picture, an SDF rounded-rect `ShaderEffect` that computes the corner alpha with `smoothstep` over one pixel instead of a rasterized mask texture, premultiplied-alpha handling, aligning the picture, hairline and ring to the same radius and to whole pixels). It must keep the software-renderer path (no MultiEffect: rectangular clip) working, and must not add a fullscreen pass or a per-frame cost: the Dell's frame budget (T-205) is tight, so prefer one small shader or a cheap property change over extra layers; note the cost in the Outcome.
3. **Apply it to every picture-carrying rounded shape:** the wallpaper chooser tiles (internal and USB), `AppArt` (so the cards in Store, Library, Home, the detail page art), the Home hero if it rounds, and the avatar/profile pictures if they show the same fringe. If one of these is deliberately different, say why.
4. **Tests and screenshots.** Offscreen tests assert properties (the radius used by picture, hairline and ring is the same; the mask or shader item exists when `GraphicsInfo.api` is not Software; the path falls back cleanly). The GPU result is proven by reviewed screenshots: before and after crops of a tile corner and a card corner (focused and not) at 1080p, kept in `output\shell-shots\review`. A guard test must fail if the picture, hairline and ring radii drift apart.
5. **Spec:** update 04 §5.2 (and the wallpaper chooser row) with the corner rule that now holds.

## Out of scope
- New card sizes, the glow design, new components beyond a small shared corner helper if the fix needs one (add it to `shell/CMakeLists.txt` and to 04).

## Acceptance criteria
- [ ] The Outcome names the observed defect with before/after zoomed crops (tile and card, focused and unfocused, one dark and one light theme).
- [ ] Corners of the wallpaper tiles and of `AppArt` cards look clean and smooth in the full-size 1080p screenshots (read them; also check 4K or 720p for a seam or fringe).
- [ ] Picture, hairline and focus ring share one radius (property test) on tiles and cards.
- [ ] The software-renderer path still works; `.\scripts\dev.ps1 test` ALL GREEN and `.\scripts\dev.ps1 shots` ALL GREEN.
- [ ] The frame-time cost is stated (extra layers/passes before vs after); no new fullscreen pass.
- [ ] 04 §5.2 updated.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §5.2 and the wallpaper chooser description.

## Hints
- The Dell (`192.168.178.109`, UHD 630, Mesa 26.2.6, root with the dev key) can show the real GPU result, but a read-only look is all that is allowed there; the Windows GPU `shots` render is the test bench.
- `Rectangle { radius }` plus `clip: true` is rectangular on purpose (T-281): do not go back to it on the GPU path.
- Text with backslashes only through Write/Edit.

## Outcome
Verified: host
UX notes: no states, focus or navigation changed (rendering only). Reviewed: tiles focused and unfocused (Dreamglass picker, Daylight USB picker), cards focused, unfocused, light picture top and bottom corners (Games grid, Dreamglass and Daylight), the focused card's bottom edge over its shadow, the glass sheet's corner and the nav pill. Doubt: the shots render 1920x1080 physical pixels at a window DPR of 1.5 (shell 1280x720 logical, `u` 0.667); no physical 720p or 4K render exists in the harness (Inbox).

**Diagnosis (GPU `shots`, full-size PNGs, corners cropped and enlarged 6-8x).** Before/after pairs (before left, after right) are in `output\shell-shots\review\t314-*.png` (15 files).
- **Jagged picture edge (the owner's "ugly corners").** The picture of every wallpaper tile and every `AppArt` card was cut by a `MultiEffect` mask with the default `maskThresholdMin` 0 and `maskSpreadAtMin` 0. That turns the mask into a hard step: every pixel the rounded mask Rectangle's antialiased edge touches at all becomes fully opaque. The corner is drawn as stair-steps (`t314-tile-dark-unfocused-tl`, `t314-card-dark-white-tl`), in every theme, focused or not, and lies up to a pixel outside the true outline.
- **Pixels outside the outline.** Because the stepped picture is fatter than the antialiased shapes drawn on the same radius, it pokes out past them. You see pink and grey specks outside a focused card's ring (`t314-card-dark-focused-tl`), a bright white fringe around the bottom corners of a light picture where it shows past the dark caption fade (`t314-card-dark-white-br`), and the glass sheet's blurred crop as red stair-steps outside its lit rim (`t314-sheet-dark-tl`; same cause, `GlassSheet`).
- **Tint fringe and a line under the picture.** The art's own hue gradient is drawn under the picture with the same rounded, antialiased edge, so it shows in the half-covered edge pixels. That gives a lilac fringe at the corners once the edge is smooth, and a 1 px dark purple line (Dreamglass) or lilac line (Daylight) along the bottom of a card whose picture does not end on a whole pixel (`t314-card-*-white-br`, left half).
- **Not found:** the picture, hairline and ring radii already matched (the ring concentric on tiles, the same radius on cards); no glow clipping; no softness from a low-resolution layer texture.

**Fix (the cause, shared).**
- New `shell/qml/SmoothMask.qml`, a `MultiEffect` with `maskEnabled`, `maskThresholdMin: 0.5`, `maskSpreadAtMin: 1.0` and no auto padding. The mask's 0..1 coverage goes through a smoothstep whose 50 % point is the outline, so the edge keeps its one-pixel ramp. Every rounded mask in the shell now uses it: `AppArt` (the picture, as `layer.effect`), the wallpaper tiles (internal and USB), the card glare (`CardFocusLayers`), the glass blur of `GlassPill` and `GlassSheet`, and the inverted cut-out of `GlassShadow`, so the lift shadow reaches under the card's antialiased edge instead of stopping short of it. Every mask layer (and the tile's content layer) now has `layer.smooth: true`, since a focused card is scaled 1.08 and nearest sampling would bring steps back.
- `AppArt.fillClear`: no tint under a masked picture (it only ever showed as the fringe). The software path keeps the tint (the picture is square there and covers it); a card without a picture keeps it. `AppArt.gpu` (default `GraphicsInfo.api !== Software`) is overridable, so tests reach the GPU path offscreen, as `GlassSheet.gpu` already is.
- Wallpaper tile: the default look's gradient has radius 0 while masked (the mask rounds it; a second antialiased edge thinned the corner).
- One radius: the ring and the lift shadow of `ArtCard` and of the Store card bind to `art.radius` instead of their own `Theme.radiusM * card.u`. The mask, the caption fade and `CardFocusLayers` already did, so nothing on the card's outline can drift from the picture.
- The software-renderer path is unchanged: the picture keeps square corners in a rectangular clip and `SmoothMask` items stay invisible.
- Unaffected, and why: the Home hero and the screen saver art have radius 0 (no mask). The profile avatars are colour circles with an initial and carry no picture. The detail page's art is `AppArt`, so it is fixed too.

**After.** All 15 pairs show a smooth, antialiased corner that sits on the ring and hairline outline. There are no specks outside the ring, no white fringe at the caption fade, no line under the picture, and the shadow joins the card's edge without a seam. The glass sheet's edge is clean too.

**Frame cost.** Before and after are the same: per masked picture one picture layer, one mask layer and one MultiEffect pass; per glass pill/sheet and per shadow the same passes as before. Linear instead of nearest filtering of the mask textures is free. The art's fill Rectangle stays a node with transparent stops. No new layer, no new pass, no fullscreen pass.

**Tests.** In `tst_artglow`:
- `test_the_picture_mask_keeps_the_antialiased_edge`: the picture's layer effect, the glare and the shadow and halo cut-outs are smooth masks (0.5 / 1, inverted for the shadow), and the mask layers are filtered.
- `test_no_fill_under_a_masked_picture`: the GPU path through `gpu`, plus the software path.
- `test_one_radius_for_picture_shadow_and_ring`, the drift guard: at `u` 1, 0.667 and 2, changing `art.radius` moves the mask, caption fade, sheen, glare layers, shadow and ring.
- `test_store_cards_use_the_compact_size` gains the same guard for the Store card.

In `tst_wallpaper`, `test_the_panel_is_glass_and_the_thumbnails_are_rounded` adds, for every tile and a USB tile: the hairline radius equals the picture's, the cut is a smooth mask with a filtered mask layer, `masked` and the mask item's visibility follow the renderer, and the sheet's blur is a smooth mask.

`tst_glide` `test_liquid_pill_falls_back_to_the_plain_pill` checks the pill's blur is a smooth mask.

**Revert checks** (`scripts\revert-check.ps1`, each CAUGHT):
- `SmoothMask` threshold 0.5 → 0: the artglow, wallpaper and glide tests above fail.
- `fillClear: bare || (masked && image.visible)` → `bare`: `test_no_fill_under_a_masked_picture` fails.
- `ArtCard` ring `radius: art.radius` → `Theme.radiusM * card.u`: `test_one_radius_for_picture_shadow_and_ring` fails.
- `StorePage` ring the same: `test_store_cards_use_the_compact_size` fails.
- `AppArt` mask `layer.smooth: true` → `false`: `test_the_picture_mask_keeps_the_antialiased_edge` fails.

**Files.**
- New: `shell/qml/SmoothMask.qml` (and in `shell/CMakeLists.txt`).
- Changed: `shell/qml/AppArt.qml`, `ArtCard.qml`, `StorePage.qml`, `CardFocusLayers.qml`, `WallpaperPicker.qml`, `GlassPill.qml`, `GlassSheet.qml`, `GlassShadow.qml`. The `QtQuick.Effects` import was dropped where no MultiEffect is left.
- Tests: `shell/tests/tst_artglow.qml`, `tst_wallpaper.qml`, `tst_glide.qml`.
- Spec: `docs/specs/04-design-system.md` (§5 new Smooth mask row and the App art row, §5.2 corner rule, the wallpaper picker text in §3.5).

**Deviations.** The fix also covers the glass pill, the glass sheet and the shadow cut-out, which are not picture-carrying. The cause is the same, and the sheet is the wallpaper chooser's own panel, where the defect showed.

**Unverified.**
- A physical 720p or 4K render: the harness only renders 1920x1080 physical. Since the layers follow device pixels, the ramp is one device pixel at any size.
- The Dell (UHD 630, Mesa) look: not inspected.
- A real photo on a wallpaper tile: the shots' tiles are gradients, because the fixture pictures don't decode. The cut is the same for any content, and the cards show real pictures.
