# T-199 — Device icons: a controller, a headset, a keyboard... shown next to each device

Status: todo · Phase: 2 · Depends: — · Area: shell, services, api · Size: M · Owner: builder

## Goal
Every Bluetooth device in Settings → Bluetooth (and the "controller connected" toasts and the battery rows that name a device) shows an icon that says what it is: a gamepad, a headset, a speaker, a keyboard, a mouse. Where we can tell the controller family (PlayStation, Xbox, Nintendo), the icon is that family's pad; where we cannot, the generic gamepad icon is fine. Owner request, 2026-11-06 (first Dell run: the list is text only).

## Read first
- `docs/specs/04-design-system.md` §3.7 (icons: Material Symbols Rounded subset, ADR-013), §5 components, §8 (a missing token or component is an Inbox line / a spec change in the same commit)
- `shell/fonts/icons.txt`, `shell/qml/Icon.qml`, `scripts/subset-icons.sh`, `scripts/lint-icons.ps1`, `docs/dev-setup.md` "Adding an icon (T-157)"
- `api/dbus/org.ruyaos.Devices1.xml` (`Bluetooth.ListDevices` records; today `kind` is `controller | headset | audio | other` and comes from BlueZ's `Icon`), `services/ruya-devices/src/bluetooth.rs` (`kind_of`), `shell/qml/BluetoothPane.qml`, `shell/qml/` toast code for devices

## Scope
1. **Kinds -> generic icons (always):** extend `kind` to cover what BlueZ's `Icon` says (`input-gaming` -> `controller`, `audio-headset`/`audio-headphones` -> `headset`, `audio-card`/speaker -> `speaker`, `input-keyboard` -> `keyboard`, `input-mouse` -> `mouse`, phone, other) in the contract and `kind_of`, with tests; add the matching Material Symbols to the subset font (`sports_esports`, `headphones`, `speaker`, `keyboard`, `mouse`, `bluetooth`...) per `dev-setup.md`, and show the icon in the Bluetooth pane rows and in the "connected/disconnected" toasts. Accessible names stay the device name plus its kind in words.
2. **Controller family (best effort):** the device record gets a `family` key (`playstation` | `xbox` | `nintendo` | `""`), derived in the service from the `Modalias` BlueZ already reports (`usb:v054Cp0CE6d0100` = Sony 054C; Microsoft 045E; Nintendo 057E; and the name as a fallback). The shell shows a family-specific glyph when it has one and the generic gamepad otherwise.
3. **Family art, without trademarks:** draw our own simple pad silhouettes (PlayStation-like, Xbox-like, Switch-like layouts) as part of the icon font or as small SVGs in the design system, in the same line style as the Material icons. **Do not use Sony/Microsoft/Nintendo logos or button-symbol trademarks** (owner-level: legal); if real brand art is wanted it is an owner decision with a licence answer. Record what was drawn and what is deliberately generic in `04` §3.7.
4. **Mock and tests:** the mock devices cover every kind and family so tests and screenshots show them.

## Out of scope
- Icons for Wi-Fi networks, audio sinks and storage (separate rows exist; reuse the same mechanism later), animated icons, the controller battery art.

## Acceptance criteria
- [ ] Rust tests: `kind_of` and `family_of` map the known BlueZ icons and modaliases (Sony 054C/0CE6, 054C/09CC, Microsoft 045E, Nintendo 057E/2009, unknown vendor -> `""`) and the missing-icon case.
- [ ] `tst_bluetooth.qml`: each mock kind/family shows the expected icon name in its row (assert the icon name, not pixels); an unknown kind shows the generic fallback; accessible names include the kind in words.
- [ ] `lint-icons` passes (list and table agree); the new glyphs are in the subset font.
- [ ] Screenshots of the Bluetooth pane with all mock kinds and of a device toast, read against `04` §8.
- [ ] VM/hardware (lead run): `ListDevices` on the Dell reports `kind` headset and controller + `family` playstation for the DualSense and the WH-1000XM4 as headset.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- Devices1 XML, `03` Bluetooth paragraphs, `04` §3.7, `docs/dev-setup.md` if the icon list changes.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
