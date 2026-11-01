# T-155 — Accept pulse on art cards; remove the unused `Tile`

Status: todo · Phase: 2 · Depends: T-146 · Area: shell · Size: S · Owner: builder

## Goal
Pressing A on a game card gives the same short press feedback the old Home tiles had. T-146 replaced the tiles with art cards, so the pulse no longer runs anywhere and its reduced-motion test now exercises a component nothing uses.

## Read first
- `docs/specs/04-design-system.md` §3.4 (pulse 0.94 over 70 + 180 ms, `OutQuad`/`OutBack`, off under reduced motion), §5 (Art card)
- `docs/specs/02-shell.md` §3.2 (reduced motion)
- `shell/qml/Tile.qml` (the pulse to move), `shell/qml/ArtCard.qml`, `shell/tests/tst_motion.qml` (`test_feedback_animations_respect_reduced_motion`)
- Tokens used: `pulseScale`, `pulseDownMs`, `pulseUpMs`; new tokens or components: none

## Scope
1. Move the pulse from `Tile.qml` into `ArtCard.qml` (a function the caller runs on Accept, as `Tile` did); run it on Accept in the Home Recent row and the Games grid. It must not fight the focus scale (pulse the art, or multiply with `focusScale`).
2. Delete `Tile.qml` and its `CMakeLists.txt` line.
3. Retarget the `tst_motion` test to `ArtCard`: the pulse animation runs normally and does not run under reduced motion. The test keeps both assertions it has today.
4. Specs: "tile pulse" becomes "card pulse" in 02 §3.2 and the `Theme.qml` comment; 04 §5 Art card row mentions it.

## Out of scope
- A pulse on buttons (`PrimaryButton`, `SecondaryButton`): not in the spec.

## Acceptance criteria
- [ ] Accept on a Recent card and on a Games card starts the pulse (test: `tst_motion` or `tst_home`/`tst_games`, assert the animation's `running` or the scale leaving 1).
- [ ] Under reduced motion no pulse runs and the launch still happens (test).
- [ ] `Tile.qml` is gone and nothing references it (`git grep Tile.qml` empty, build green).

## Verification
```powershell
.\scripts\dev.ps1 test
```
(No screenshot changes: the pulse lasts 250 ms.)

## Docs to update
- `docs/specs/02-shell.md` §3.2, `docs/specs/04-design-system.md` §3.4/§5.

## Outcome
_Filled in by the implementer._
