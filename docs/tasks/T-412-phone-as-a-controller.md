# T-412 - The phone as a controller: D-pad, confirm, back, home, menu, pointer and the phone's keyboard, as a profile's controller

Status: blocked (owner 2026-11-10: Companion is for later, not built now) · Phase: 6 · Depends: T-411, T-397, T-367 · Area: services (ruya-link, the input service), shell (text input) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
A paired phone works as a remote: its D-pad and buttons move the shell's focus like a pad of the profile it belongs to, its keyboard types into the focused text field, and its touchpad moves a pointer where a pointer exists.

## Read first
- ADR-030, ADR-027 (owner pads), ADR-024 (virtual devices by the input service), T-411's protocol, T-397, `shell/qml/TextEntry.qml` (text input), `docs/specs/02-shell.md` §4

## Scope
1. A virtual input device per connected, paired phone with the "remote input" permission, made by the input service; it counts as that profile's controller (ADR-027), never as a stranger's pad.
2. Text: the phone's keyboard fills the focused `TextEntry` (the shell tells the gateway when a text field has the focus); password fields are marked so nothing is logged.
3. Latency budget measured on the Dell (target under 50 ms on the LAN).

## Acceptance criteria
- [ ] Rust: permission checks, device lifecycle on connect/revoke, the profile assignment (red without each).
- [ ] QML: text from the gateway fills the field; a password field is never echoed to logs (test).
- [ ] VM (lead run): `vm-link-check.sh remote` with a scripted client; hw (lead): a phone on the Dell's LAN; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
