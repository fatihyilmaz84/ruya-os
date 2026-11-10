# T-398 - The family's own confirm button: Nintendo A on the right, PlayStation Cross (or Circle), a Confirm-button setting

Status: todo · Phase: 2 · Depends: T-396, T-366, T-368 · Area: services (ruya-inputd), shell (Settings > Controllers row), api if the setting crosses the bus · Size: S · Owner: builder · Developer surface: none

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Family per event is decided here, once, in the input service from the shared family table (T-261); T-399 reads it. The Confirm-button row goes into T-368's pane.

## Goal
A Switch Pro controller confirms with A (the right button) and goes back with B, as the player expects; PlayStation pads confirm with Cross (or Circle with the JP option); the player can override it in Settings. Today `ruya-inputd` maps by position (south = Accept), so a Nintendo pad confirms with B.

## Read first
- ADR-027, T-396's Outcome (family table, setting), `services/ruya-inputd/src/linux.rs` (BTN_SOUTH/BTN_EAST to `Button`), the family detection used for icons (T-199: Devices1 `family`, `DeviceIcons.qml`), T-261 (families and drivers: hid-nintendo, hid-playstation, xpad)

## Scope
1. The family of each input device in inputd (vendor/product ids, the driver; same table as T-199/T-261: one source, not a second copy), and Accept/Back per family; the mapping is pure and table-tested.
2. The per-profile "Confirm button" setting (as on the controller / bottom / right), stored where profile settings live, applied by inputd on profile switch.
3. Settings > Controllers row with a live hint ("Press the confirm button to try it").

## Acceptance criteria
- [ ] Rust: family x setting -> Accept/Back table, unknown family = position default (red without each).
- [ ] QML: the Settings row and its effect on the mock; screenshot reviewed.
- [ ] VM (lead run): `vm-devices-check.sh inputd` with a virtual pad announcing a Nintendo id: BTN_EAST is Accept; hw (lead): a Switch Pro or 8BitDo in Switch mode on the Dell if available.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
