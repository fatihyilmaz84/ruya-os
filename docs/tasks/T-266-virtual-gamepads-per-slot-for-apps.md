# T-266 — Ordered virtual gamepads per slot for apps (physical pads hidden)

Status: todo · Phase: 2 · Depends: T-264, T-217 · Area: services, image · Size: M · Owner: lead · Developer surface: public-API

## Goal
A game sees player 1, 2, ... in exactly the order the owner assigned: `ruya-inputd` creates one virtual gamepad (uinput) per slot and hides the physical pads from apps (Steam-Input style), so slot order, remapping and per-profile mapping work. Part of epic ADR-017 (T-263).

## Read first
- ADR-003, ADR-017, T-217 (input mapping; shares the virtual-device layer, B-006), `services/ruya-inputd`
- Flatpak `--device=input` and udev inside the sandbox; `docs/specs/05-play-packages.md` (permissions); `image/CLAUDE.md`

## Scope
1. Decide with T-217 whether this task builds the virtual-device layer or reuses it (record in the Outcome). Grab physical pads (`EVIOCGRAB`), re-emit per slot on a virtual pad whose name/ids are stable.
2. Check what a Flatpak app sees in the sandbox (device nodes, udev) and document the result in the developer guide and the HIG (T-249) with a tiny sample in `docs/developers`.
3. Failure behaviour: if `ruya-inputd` dies the pads must come back to the apps (no stuck grab); the shell keeps working.

## Out of scope
- Button remapping UI (T-217), LEDs.

## Acceptance criteria
- [ ] Rust tests for the slot → virtual device table and the release on crash/exit (fake uinput).
- [ ] VM (this task): hardening unchanged, `scripts/vm-inputd-check.sh` creates two virtual pads (a uinput source stands in for the physical pads); controllers on real hardware are unverifiable in the VM and are marked **hw**.
- [ ] Dell checklist: two pads, a SDL test app sees them in slot order (Inbox line).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `03-services-and-apps.md`, developer guide, `image/CLAUDE.md` if a quirk is found.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): apps see ordered virtual gamepads (an evdev surface, no D-Bus half). Missing: update `docs/developers/controller-input.md`, a sample that reads pad order, a conformance check in the VM script. Player slot, rumble and battery for apps are unplanned until ADR-022 is accepted.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …) | vm | hw`._
