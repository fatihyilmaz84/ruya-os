# T-204 — Dreamglass materials and motion v2: glass layers, grain, shadows, card focus, easing

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
The shell gets the richer glass and motion decided in `docs/specs/04-design-system.md` §3.8 (owner, 2026-11-06: "I like the animations and the glass effect" of a reference TV app): glass panels with a sheen, a lit rim and fine grain over their blur; real shadows under focused cards and panels; a one-time glare on card focus; the new easing and a global motion scale; shimmering art placeholders. Everything stays on our tokens and components, degrades per quality tier and is off or calmer under reduced motion.

## Read first
- `docs/specs/04-design-system.md` **§3.8 (the numbers)**, §1 principle 5, §3.4 motion, §3.5 depth, §3.6 glass and blur, §4 focus, §8 (a new token or component comes with the spec update in the same commit)
- `shell/qml/Theme.qml`, `GlassPill.qml`, the panel/glass components, `ArtCard.qml`/`Tile.qml` (card focus), the art placeholder, `shell/PATTERNS.md`, `shell/CLAUDE.md` (offscreen tests render software: assert properties, never pixels)
- Tests that touch motion tokens: `tst_theme`, `tst_reduced_motion`/accessibility, screenshot tests (`dev.ps1 shots`)

## Scope
1. **Tokens (Theme):** `easeGlide`, `easeSnap` (cubic-bezier curves as `Easing.BezierCurve` arrays), `popOvershoot` 0.94, `motionScale` (applied to every duration token; reduced motion = 0), `shadowLift`, `shadowPanel`, `shadowPill` (offset, blur, alpha), `glassSheen`, `glassRim` (+ top-left bias), `glassTint`, `glassGrainOpacity`. Values from §3.8. Existing tokens and animations keep working unchanged; switch the card focus lift and the page/overlay transitions to the new easings only where §3.8 says so.
2. **Glass layers component:** one reusable layer stack (`GlassLayers.qml` or a property set on the existing glass components) used by `GlassPill`, the Guide overlay `panel`, the quick menu, toasts and Settings panes: sheen, rim, tint (sheets/modals), and the grain tile (a bundled 128x128 PNG made by a script or generated into a texture once: say which, and keep the asset licence-clean). Opaque glass (`glassOpaque`, Performance tier) keeps sheen and rim, drops the grain and the shadow.
3. **Shadows:** implement `shadowLift/Panel/Pill` with `MultiEffect` shadow (or a pre-blurred shadow texture if cheaper: measure), High and Balanced only; never a second full-screen effect.
4. **Card focus:** `ArtCard`/`Tile`: lift shadow + top sheen on focus; the glare sweep once per focus entry, skipped when focus moved within the last 300 ms, off under reduced motion and on Performance; focus ring/scale unchanged (§4).
5. **Shimmer placeholder** for art that has not loaded: gleam 8.5 % white at 760 units/s from a cached strip; none under reduced motion or Performance.
6. **Spec/docs:** mark §3.8 items as built, update §3.4/3.5/3.6 numbers, `shell/CLAUDE.md` if a rule changes, `docs/dev-setup.md` if a switch is added (for example `RUYA_GLASS_DEBUG` to turn layers off one by one).

## Out of scope
- The gliding highlight and the liquid-pill refraction (T-205), glass over a running app (B-003), HDR, new colours beyond the listed tokens, rewriting existing screens' layouts, the artwork colour extraction (Inbox).

## Acceptance criteria
- [ ] `tst_theme.qml`: each new token exists with the §3.8 value; `motionScale` multiplies the duration tokens and reduced motion zeroes it; the easing tokens are the specified curves.
- [ ] Component tests: glass components expose sheen/rim/tint/grain per tier (High: all; Balanced: all; Performance: sheen and rim only, opaque fill, no shadow, no grain); a focused card shows lift shadow and sheen, runs the glare once on entering focus, does not run it again when focus moves on within 300 ms, and not at all under reduced motion or on Performance (assert the glare animation `running`/a counter, not pixels); the ring and 1.08 scale are unchanged.
- [ ] Screenshots (`dev.ps1 shots`, GPU): Home, Store, Settings, Guide overlay, a toast, a focused card mid-glare and a placeholder; High, Balanced and Performance variants of one screen; read against §3.8 and `04` §8. Text on glass stays legible (contrast numbers for white text on the lightest hero art with `glassTint`).
- [ ] Performance on real hardware (lead, the Dell, Intel UHD 630): a focus-move sequence on Home with the new effects keeps frame time under 33 ms (no dropped frames visible in `QSG_RENDER_TIMING` / the shell's frame log); the numbers go into the Outcome and the tier defaults are adjusted if not (B-002).
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `04-design-system.md` §3.4-3.8, `shell/CLAUDE.md`, `docs/dev-setup.md`.

## Hints
- The study's lessons that matter on weak hardware: bake blurs once and draw one quad; blur a heavily downscaled copy; avoid per-frame framebuffer creation; fall back to the opaque panel until the blur texture is ready.
- Do not copy anything from the reference app's source: implement from the numbers in §3.8 on our own components.
- Grain at 2 % is nearly invisible on a monitor and visible on a TV: check on the Dell's panel.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
