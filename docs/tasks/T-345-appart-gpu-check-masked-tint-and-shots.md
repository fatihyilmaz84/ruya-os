# T-345 - AppArt and the rounded corners: one GPU check, no tint under a masked picture, shots at 4K and DPR 1

Status: todo · Phase: 2 · Depends: — · Area: shell (AppArt, GlassSheet, SmoothMask, shots) · Size: S · Owner: builder

## Goal
Review findings of the corner fix (T-323, was T-314): the corners were fixed at the root (`SmoothMask`), but every screenshot is 1920x1080 at DPR 1.5, wallpaper tests use gradients instead of a photo, `AppArt` and the tile/`GlassSheet` decide "is there a GPU" differently, and a transparent logo PNG would show the page through the tint. Close these so the next corner regression is caught by a test, not by the owner's eyes.

## Read first
- The Inbox line tagged T-314 (now T-323) in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)" (verbatim); `docs/tasks/T-323-ugly-rounded-corners-on-wallpaper-tiles-and-cards.md` Outcome
- `shell/qml/AppArt.qml` (`gpu: GraphicsInfo.api !== GraphicsInfo.Software`, `masked`, the tint), `SmoothMask.qml`, `GlassSheet.qml`, the wallpaper tile (`WallpaperPicker`/tile component), `shell/tests/tst_wallpaper*.qml`, `tst_app_art*.qml`, how `shots` sets size and DPR (`scripts/dev.ps1`, `QT_SCALE_FACTOR`)
- `docs/specs/04-design-system.md` §8 (screenshot review); new components allowed: none

## Scope
1. **One GPU check:** a single helper (a `Theme`/`Shell` readonly property or a small singleton) that says "the scene graph can draw effects" (not Software, not Null, not Unknown); `AppArt`, the wallpaper tile and `GlassSheet` use it; tests keep overriding it.
2. **Tint under a masked picture:** `AppArt` shows its tint only while no picture is loaded and visible; a loaded masked picture hides it, but a picture with transparent pixels (a logo PNG) must not show the page through: back it with the tint when the image has alpha (`Image.hasAlpha` or the loaded format) and cover that in a test with a transparent fixture.
3. **Shots:** add to `shots` a physical 4K case (3840x2160 at DPR 1) and a 720p DPR 1 card row; the wallpaper screenshot test uses a real photo fixture (a small licence-clean jpg in `shell/tests/fixtures/`, made for this project) instead of gradients, so tile corners are judged on real texture.

## Out of scope
- New corner styles or radii, Store badge scrim and Backdrop tint from `ArtPalette` (parked), performance numbers (Dell look-at list).

## Acceptance criteria
- [ ] `tst_app_art.qml::test_one_gpu_check_for_art_tile_and_sheet` (all three follow the same property; revert: restore the old check in one, red), `::test_transparent_png_keeps_its_tint`, `::test_opaque_picture_hides_the_tint`.
- [ ] Screenshots reviewed (full-size for corners): wallpaper tiles and the card row at 4K DPR 1 and 720p DPR 1, with a real photo; no stair-stepped edge, no fringe.
- [ ] UX: readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.
- [ ] Dell (lead, hw): the corners on the real GPU with image 0.0.55 or newer (Dell look-at list).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §8 (the extra shot sizes), `shell/PATTERNS.md` (the GPU property).

## Hints
- MultiEffect draws nothing offscreen (software renderer): assert properties offscreen, pixels only in `shots`.
- Overlaps `AppArt.qml` work in T-281 follow-ups (parked) and T-284 (`GlassSheet`): sequence by the board.

## Outcome
_Filled in by the implementer._
