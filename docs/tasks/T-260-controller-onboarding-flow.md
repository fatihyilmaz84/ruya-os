# T-260 — Controller onboarding: USB detection, first-run guidance, one-click pairing, the paired list

Status: in-progress · Phase: 2 · Depends: T-203, T-199 · Area: shell, services · Size: M · Owner: builder

## Goal
The first minutes with a controller just work and explain themselves (owner request, 2026-11-07, "Controller onboarding experience"): plug a pad in and the console says what it is; a console with no pad tells you how to pair yours, per family; the paired pads are listed and reconnect by themselves. This task covers only the **gaps**; the table says what exists.

## What exists or is planned (do not duplicate)
| Owner bullet | State |
|---|---|
| Connect a controller via USB | `ruya-inputd` turns any HID gamepad into navigation keys (hot-plug works, vm/hw-verified with a DualSense over Bluetooth); no "connected" message for USB yet: **this task (a)** |
| Detect DualSense, Xbox, 8BitDo | `family` key and pad art in **T-199** (best effort from Modalias/name); driver situation per family: **T-261** |
| Offer Bluetooth pairing in one click | Settings -> Bluetooth pairs (bonded fix done); the pairing window and the agent for pads in pairing mode, wizard step, picker hint: **T-203**; the per-family guidance and one-click pair from the discovered list: **this task (b)** |
| Remember paired controllers | BlueZ bonds and trusts them (`Bonded: yes`, verified); the list with state, rename: **this task (d)** |
| Reconnect automatically | Verified for a bonded DualSense on the Dell; levers for speed: **T-207**; reconnect at the login screen: **T-203** item 3 |
| Wake from suspend by controller | Not built: **T-262** (needs T-166, T-202) |

## Read first
- T-203 (the pairing window and agent), T-199 (family and icons), T-223 (batteries), T-217 (button test, player numbers: link, do not build), `shell/src/bluetooth`, `Setup.qml`, `BluetoothPane.qml`, `Notifications`, `docs/specs/02-shell.md` (first-boot setup, toasts), `ruya-inputd` and `ruya-devices` (device and hot-plug events), `04` §8

## Scope
1. **(a) A controller appeared:** a toast "<Name> connected" (USB or Bluetooth) with the family glyph (T-199) and the battery when known, once per connection (a debounce for a flaky cable), and "<Name> disconnected" only when the pad was in use (quiet otherwise). The platform event comes from `ruya-inputd`/`ruya-devices` (extend the contract first if the shell cannot tell a pad from a keyboard or mouse); the shell shows nothing for keyboards and mice here.
2. **(b) First-run guidance:** where T-203 shows its "no controller" state (wizard step, picker, empty Settings), show **per-family steps** in plain words, with our own simple drawings (no vendor art or marks): PlayStation-style ("hold PS and Create until the light bar flashes"), Xbox-style ("press the pairing button on top until the logo flashes fast"), 8BitDo ("hold Start and the Y/X combination for your mode; use the Bluetooth or X-input mode": text from `T-261`'s findings), Switch-style, "other". While the screen is open the pairing window of T-203 is open and discovery runs; each discovered input device appears in a list as it is found, with its family glyph, and **one A press pairs it** (progress, success with "Connected, remembered", failure with a reason and Retry). Controller-only, B backs out.
3. **(c) "Press a button to try":** after a pad connects during onboarding, a small screen shows the pad's buttons and sticks lighting up as pressed (a light version of T-217's button test: reuse its component if it exists, else build the minimal one and leave T-217 to extend it) and "Continue".
4. **(d) The paired list** in Settings -> Bluetooth (controllers section, or a Controllers pane if T-217 made one): each paired pad with name, family glyph, battery, state (Connected / Reconnects automatically / Not in range), **Rename** (on-screen keyboard, stored by BlueZ alias) and **Forget** (confirmation naming the pad); a "Pair a new controller" row that opens (b).
5. Mock and tests: scripted USB connect, pairing success, timeout, rejected device class; Turkish; accessible names.

## Out of scope
- Remapping and dead zones (T-217), the drivers themselves (T-261), wake from suspend (T-262), PIN pairing (B-006), pairing audio devices, pads' firmware updates.

## Acceptance criteria
- [ ] QML tests (mock): the connected toast once per connection and its debounce, no toast for keyboards and mice, the per-family steps and the discovered list update in place with focus kept, one-press pairing and its failure/Retry, the try-a-button screen, Rename and Forget with confirmations, controller-only operation, focus asserted.
- [ ] Rust tests only if the contract changed (events for pad connect/disconnect).
- [ ] Screenshots (English and Turkish) against `04` §8.
- [ ] Hardware (lead, the Dell, checklist in T-261): USB connect toast with a DualSense cable, the guided pairing with a bond removed, rename and forget, reconnect after reboot.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`._
