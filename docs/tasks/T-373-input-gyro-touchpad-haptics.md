# T-373 - Gyro, touchpad and haptics: motion to mouse or stick, touchpad as mouse and button, vibration settings

Status: todo · Phase: 3 · Depends: T-369 · Area: services (input), shell (Controllers pane) · Size: M · Owner: builder · Complexity: complex · Developer surface: public-format

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Add a "VM (lead run)" criterion naming the check (the static hidraw rule it needs is decided in T-366).

## Goal
A DualSense (or Switch Pro) can aim with gyro and use its touchpad as a mouse, and the player controls vibration strength. Requirements §7.3, §8.

## Read first
- ADR-024, `docs/specs/06-input.md`, T-368/T-369 Outcomes; the DualSense's motion and touchpad nodes (on the Dell: `event14`, `event15`)

## Scope
1. Gyro to mouse or right stick: activation always, while a button is held or while aiming; sensitivity, inversion, dead zone, calibration, optional smoothing.
2. Touchpad as mouse, as a button, by regions; scroll.
3. Vibration: strength and off per controller; basic rumble only (advanced haptics and adaptive triggers through hidraw are a later task if the spike in T-366 says they are reachable).

## Acceptance criteria
- [ ] Rust tests: gyro maths with recorded samples (fixtures from the Dell), activation modes, touchpad regions.
- [ ] QML tests and screenshots for the rows; `UX notes:` line.
- [ ] hw (Dell): aim with gyro in a test app; touchpad moves the pointer.

## Outcome
_Filled in by the implementer._
