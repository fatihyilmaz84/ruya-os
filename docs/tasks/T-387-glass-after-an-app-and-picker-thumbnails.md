# T-387 - Glass sheets lose their blur after an app was in front; wallpaper picker tiles stay blank

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Shell.qml L0, GlassSheet, WallpaperPicker) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

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
_Filled in by the implementer._
