# T-276 — Compositor: last-frame snapshots, visibility events, smooth switch

Status: todo · Phase: 3 · Depends: T-273, T-164, T-147 · Area: shell · Size: M · Owner: lead

## Goal
Switching apps looks instant and continuous: each open app has a snapshot of its last frame for the switcher, the incoming app appears without a black frame, and apps are told when they become hidden or visible. Part of epic T-273.

## Read first
- T-273, 02 §1.5, 03 §4.6 (`xdg_toplevel` suspended / visibility), `shell/compositor/*` (QtWaylandCompositor, `IdleInhibitManager`), `Shell.addApp/focusApp`, 04 §5.1 launch transition, `GlassSheet` (baked blur once)
- T-205 (frame-time budget), B-003 (compositor performance)

## Scope
1. **Snapshots:** when an app leaves the foreground (and every N seconds while in front, cheap), capture its surface into a small texture (about 1/4 size, `ShaderEffectSource`/`grabToImage` on the item, no readback to the CPU), kept for the switcher; dropped when the app closes. Memory budget stated (the card count × size).
2. **Visibility:** send the xdg suspended state / `wl_surface` leave to the hidden app before it is frozen and the opposite after a thaw (T-275 orders the calls); document in the developer guide.
3. **Smooth switch:** the outgoing app scales/fades to its card and the incoming one grows from its card over `switchMs` (new token, 0 under reduced motion), no more than one app's surface drawn at full rate, no frame without content (hold the snapshot until the thawed app's first new frame).
4. Frame-time measurement on the Dell (T-205 style): the switch animation stays within the frame budget; if not, a cut with a short fade.

## Out of scope
- The switcher UI and gesture (T-277), freezing (T-275), the memory policy (T-278).

## Acceptance criteria
- [ ] Tests: a snapshot exists for a hidden app item and is released on close; visibility signals fire in order; reduced motion makes the switch a cut; a thawed app that never maps a frame does not leave the screen black (timeout back to the snapshot or Home).
- [ ] Screenshots of the mid-switch animation states; frame-time numbers (hw: Dell, may be pending).
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- 02 §1.5, 04 §3.4 (motion token), developer guide, 03 §4.6.

## Outcome
_Filled in by the implementer. First line: `Verified: host (hw pending: …)`._
