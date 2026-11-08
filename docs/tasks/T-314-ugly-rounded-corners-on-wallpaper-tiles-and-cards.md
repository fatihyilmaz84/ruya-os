# T-314 — Rounded corners of the wallpaper tiles and the cards look rough

Status: in-progress · Phase: 2 · Depends: — · Area: shell (WallpaperPicker, AppArt, the card family, CardFocusLayers) · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
