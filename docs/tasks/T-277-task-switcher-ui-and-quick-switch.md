# T-277 — Task switcher UI and the quick-switch gesture

Status: todo · Phase: 3 · Depends: T-273, T-147, T-275, T-276 · Area: shell · Size: M · Owner: builder

## Goal
Pressing Guide shows the quick menu with a row of open apps (cards with the last frame, name, running time and a "frozen"/"playing audio" mark); Left/Right and A switch; one extra press jumps straight back to the previous app. Part of epic T-273.

## Read first
- T-273 (the gesture proposal, ADR-019), 02 §1.5 and the Guide overlay, T-147 (`QuickMenu.qml`: build on it, do not fork it), T-275 contract, T-276 snapshots, 04 §5 (cards, rows, focus), §8; `shell/PATTERNS.md`
- `shell/src/input` (KeyRouter: how Guide/Home arrives), T-202 (`IdleClock`: input wakes)

## Scope
1. **Switcher row** at the top of the quick menu: one card per open app in most-recent order (foreground first), snapshot as art, title, time, state mark. Left/Right move, **A** switches (`Session.Switch`), **X** (or Menu) closes the focused app after a short confirm if it reports unsaved state, **Back** closes the menu to the app. Relaunch card for an app the system closed (T-278).
2. **Quick switch:** a double press of Guide within a constant (350 ms, in settings later) switches to the previous app without opening the menu; hold Guide stays the power menu (02 §1.5). From Home, the Running row of Recent shows the same cards.
3. Hint bar for the menu and the switcher; Turkish; at most N cards (policy value from the service) with a "+N" mark.
4. The switcher never shows another profile's apps (ADR-004).

## Out of scope
- Snapshot capture (T-276), freezing (T-275), the killer (T-278), new input hardware mapping (ruya-inputd already delivers Guide).

## Acceptance criteria
- [ ] `tst_switcher.qml`: cards follow `Session.running` order; A switches and focus lands in the app; double-press Guide toggles the previous app; single press opens the menu after the double-press window (state the delay, keep it short); Back closes; X closes an app and the card disappears; no cards of another profile; focus after every step.
- [ ] Screenshots (1, 3 and 5 cards; 1080p/720p), read against 04 §8; UX: Back leaves every state; the menu stays usable with a controller only; `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- 02 §1.5, 04 §5 (switcher card/row), developer guide (what players see).

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
