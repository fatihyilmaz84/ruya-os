# T-223 — Top-right status: each connected device's battery, with the right icon and level

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
The top-right status cluster shows the battery of every connected wireless device that reports one (controllers, headsets, other Bluetooth devices), each with its own icon, a battery glyph that matches the level, and the percentage. Owner report, 2026-11-06: "show connected devices' battery percentage at the top right (right now it shows a hardcoded battery symbol it seems)".

## What is there today
`shell/qml/Shell.qml` (the status cluster, ~line 418 to 460): one chip, `batteryStatus`, shown while `Batteries.lowest >= 0`: it shows only the **lowest** battery of all devices, the icon is `battery_alert` when low, `battery_charging_full` when the lowest is charging and **`battery_full` otherwise, whatever the level** (so 40 % looks like a full battery), and the percentage text. The data is real (`Batteries`: `Devices1.Batteries`/UPower, T-161); the glyphs are the problem, plus you cannot tell which device the number belongs to.

## Read first
- `shell/qml/Shell.qml` (status cluster), the `Batteries` singleton (`shell/src/battery/*`: `lowest`, `lowestState`, `low`, the list model and its fields `id`, `name`, `percent`, `state`), `api/dbus/org.ruyaos.Devices1.xml` (`Batteries`), spec 03 "Battery, as built (T-161)" and "Which source wins for a controller", `04-design-system.md` §3.7 (icons), §5 (status pill), `docs/tasks/T-199` (device kind icons: use them once T-199 lands; until then `sports_esports` for pads, `headphones` for headsets)
- The Dell: DualSense via `hwmon`/UPower, a WH-1000XM4 headset (BlueZ `Battery1` feeds UPower)

## Scope
1. **One chip per device** (up to three, ordered: lowest battery first; more than three collapse into one "+N" chip that lists the rest in the Guide overlay or the Settings -> Bluetooth page): device icon (by kind), a **level glyph** that matches the percentage (`battery_0_bar` ... `battery_6_bar`/`battery_full` in seven steps: 0-7, 8-21, 22-35, 36-50, 51-64, 65-78, 79-100 %; `battery_charging_full` with the bolt while charging; `battery_alert` at the low threshold, warning colour), the percentage text. Chips hide for devices without a battery value and for a wired, charging pad that is 100 % (decide and say: hide at 100 % while charging).
2. **Icons:** add the missing Material Symbols glyphs to the subset (`scripts/subset-icons.sh`, `icons.txt` + `Icon.qml` table, `lint-icons` green): the six `battery_N_bar` and others needed. The nav gear lesson (T-206): check the new glyphs at their real size in a GPU screenshot, not only half-size.
3. **Accessibility:** each chip's accessible name says device and level ("DualSense Wireless Controller battery 62 percent, charging"); low-battery toast behaviour from T-161 stays unchanged.
4. **Layout:** the cluster keeps its glass pill, spacing and focus behaviour (it is not focusable today); the chips share the pill; long names are never shown (icons only); it must not overlap the profile and clock at 720p/1080p/4K and with the largest text scale.
5. **Mock and tests:** the mock `Batteries` offers several devices, levels and states.

## Out of scope
- Battery details pages, history, a power/charge setting, battery of the console itself (it has none), per-device low thresholds, the Controllers pane rows (T-217 reuses these).

## Acceptance criteria
- [ ] `tst_battery*.qml`: each mock device gets a chip with the icon for its kind and the glyph for its level (assert the icon names at 0, 7, 8, 35, 36, 64, 65, 78, 79, 100 %), charging uses the charging glyph, low uses the alert glyph and colour, ordering lowest first, "+N" beyond three, chips update in place and disappear when a device disconnects, a device without a value shows no chip; accessible names as specified.
- [ ] `tst_icon.qml`/`lint-icons`: the new glyphs are in the font and the table.
- [ ] Screenshots at 1080p (GPU): one, two and four devices, charging, low, 720p and the largest text scale, read against `04` §8 and crops at 1:1 for glyph crispness.
- [ ] Hardware (lead, the Dell): the DualSense and the headset each show their own chip with the real percentage.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02-shell.md` (status cluster), `04` §3.7 (the glyph list and the level mapping), spec 03 battery paragraph.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
