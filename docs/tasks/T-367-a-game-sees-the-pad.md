# T-367 - A game sees the pad: a virtual pad per controller, for the signed-in profile only, routed by focus

Status: todo · Phase: 2 · Depends: T-366 · Area: services (input), image (udev, unit), shell (compositor focus) · Size: M · Owner: lead · Complexity: hard · Developer surface: public-API

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Security criteria to add before dispatch (from T-366's design): a test that a descriptor opened by profile A's app delivers nothing after lock, profile switch and run end; a test that no app of any profile receives events while the PIN pad or an overlay has focus; the Guide path test stays.

## Goal
SuperTuxKart's Controls list shows a gamepad, the race is driven with the DualSense, menus never move twice, and Guide still opens the shell's overlay. First slice of ADR-024.

## Read first
- ADR-024, ADR-023, `docs/specs/06-input.md` (T-366), the engine decision in ADR-003; `services/ruya-inputd/`, the input udev rule; `shell/compositor` (`KeyRouter`, app focus); `docs/developers/controller-input.md`

## Scope
1. One virtual Xbox-style pad per connected controller (stable name and ids, players in connection order until T-264 assigns slots), buttons, sticks, triggers, D-pad; rumble from the game reaches the physical pad (basic left/right motors).
2. Each virtual node gets one ACL entry for the signed-in profile's user; removed at lock, switched at profile switch; no other user can open it. Physical nodes stay shell-only.
3. Routing: while an app has the focus, pad input goes only to the virtual pads and the navigation keys stop (Guide excepted); when the shell or an overlay has the focus, the virtual pads are idle (neutral state sent once, no stuck buttons). The focus comes from the compositor over the `Input1` routing call drafted in T-366 (XML first).
4. The shell stays navigable if the service dies (T-366's chosen path).

## Out of scope
- Remapping and profiles (T-369+), keyboard/mouse output (T-372), slot assignment UI (T-264/T-265), gyro/touchpad (T-373).

## Acceptance criteria
- [ ] Rust tests (fake uinput, fake focus): a pad press reaches the virtual pad only while an app is focused; no navigation key while an app is focused (Guide excepted); neutral state on focus loss; the ACL target follows sign-in, switch and lock; a vanished pad removes its virtual pad; rumble is forwarded.
- [ ] VM (this task): `scripts/vm-input-check.sh`: a uinput "physical" pad yields a virtual pad whose ACL names only the signed-in profile's user; another user cannot open it; focus routing switches with a test app; killing the service leaves the shell navigable; `RUYA_BOOT_OK`.
- [ ] hw (lead, Dell): STK lists the gamepad and races with it; menus move once per press; Guide opens the overlay during a race.
- [ ] `docs/developers/controller-input.md` (what apps see), a minimal sample that reads the pad, a conformance check in the VM script (ADR-022).

## Outcome
_Filled in by the implementer._
