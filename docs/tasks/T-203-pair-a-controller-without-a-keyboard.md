# T-203 — Pair a controller on a fresh install, with no keyboard (first boot and login screen)

Status: in-progress · Phase: 2 · Depends: — · Area: services, shell, image · Size: M · Owner: builder

## Goal
A console with no keyboard can be set up and used with a Bluetooth controller alone. Today the first-boot setup (`Setup.qml`) and the profile picker have no way to pair a controller: Settings → Bluetooth exists only after sign-in, and signing in needs input. Owner report, 2026-11-06: "from a cold boot the controller doesn't connect when it is on the login screen". The firmware cause is fixed in the image (T-162 session); this is the other half: a bonded controller must reconnect at the login screen (verify), and a controller that is **not** paired yet must be able to pair itself there.

## Facts (Dell, `0.0.44`)
- Cold boot with the Intel dongle: the adapter had no firmware (`ibt-19-0-4.sfi` missing in the image) -> `No default controller available` -> nothing connects. Fixed by shipping the firmware (`image/build/20-base.sh`); verify on a cold boot of the new image.
- A bonded + trusted DualSense reconnects by itself when its PS button is pressed (BlueZ accepts the connection; `ruya-inputd` creates the navigation device on hot-plug). Needs checking at the picker.
- BlueZ keeps the adapter not pairable; `ruya-devices` opens `Pairable` only for the length of a `Pair` call (T-162 session). An unpaired pad in pairing mode (PS + Create) is therefore ignored, and there is no BlueZ agent to accept an incoming pairing.
- The first-boot wizard has no Bluetooth step; the picker has no hint.

## Scope
1. **Controller pairing window (service):** `ruya-devices` can open a bounded window (default 120 s) in which the adapter is discoverable-for-HID/pairable and a registered BlueZ agent (`NoInputNoOutput`, "just works") **accepts incoming pairings only from input devices** (Class of Device major class Peripheral `0x05`, i.e. gamepad/keyboard/mouse; anything else is rejected), marks them trusted, and lets the HID connection through. The window is opened by a D-Bus call (`Bluetooth.StartControllerPairing(seconds)`, `StopControllerPairing`, a `ControllerPairingState` property/signal) and closes itself on timeout, on success, or when stopped. Contract first in `Devices1.xml`. Security: the window is only opened by `ruya-shell` (existing bus policy), never by default; no PIN/passkey device is accepted here (B-006 owns PIN pairing); the agent must not accept audio or unknown classes.
2. **When the shell offers it:** (a) in the first-boot wizard, as its first step when no HID input device other than the built-in virtual one exists ("No controller or keyboard found. Hold PS + Create (or the pairing button) on your controller"), skipped when any input device is already present; (b) on the profile picker when there is no input device at all, as a hint plus the window opened automatically; (c) Settings → Bluetooth gets a "Pair a controller" row that opens the same window (the current manual scan-and-pair flow stays). Copy in `qsTr` + Turkish; the screens are controller-first, so the wizard step itself must be passable with the newly paired pad.
3. **Reconnect at the picker (verification, no new code if it works):** with a bonded pad and a cold boot, the pad reconnects at the picker within a few seconds of the PS button and navigates; if the shell starts before BlueZ/`ruya-inputd` see the adapter, make the ordering/retry robust (`After=bluetooth.service` on `ruya-inputd` if useful) and record what was needed.
4. **Mock and tests:** the mock offers the window with scripted outcomes (success, timeout, rejected device class).

## Out of scope
- PIN/passkey pairing (B-006), pairing several players' pads in one flow, renaming pads, Wi-Fi onboarding (a later OOBE task), a keyboard-only path (a USB keyboard already works).

## Acceptance criteria
- [ ] Rust tests (fake BlueZ + fake agent): the window opens and closes by timeout, stop and success; an incoming pairing from a gamepad class is accepted and trusted; from an audio/phone/unknown class is rejected; only one window at a time; `Pairable` is restored afterwards; a request from the wrong caller is refused by the contract's status string.
- [ ] `tst_wizard.qml`/`tst_picker.qml`: the controller step shows only when no input device exists; success moves on; timeout offers Retry; Back/B works with the pad; the picker hint shows only with no input device. `tst_bluetooth.qml`: the new row opens the window.
- [ ] Screenshots of the wizard step, the picker hint and the Settings row, read against `04` §8.
- [ ] Hardware (lead, the Dell, new image): (1) cold boot with the bonded DualSense: it connects at the picker and navigates; (2) remove all bonds (`bluetoothctl remove`), reboot, hold PS + Create at the first screen: it pairs, bonds (`Bonded: yes`) and the wizard continues with the pad; (3) a phone in pairing mode nearby is not accepted.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `Devices1.xml`, `03` Bluetooth paragraphs, `02-shell.md` §1.3 (first-boot setup) and the picker, `docs/dev-setup.md`.

## Hints
- BlueZ agent API: `org.bluez.AgentManager1.RegisterAgent`/`RequestDefaultAgent` with capability `NoInputNoOutput`; `RequestAuthorization`/`AuthorizeService` for just-works; check the device class via `Device1.Class` (`0x0508` gamepad, `0x0540` keyboard, `0x0580` pointing device).
- Some pads (DualSense, 8BitDo) reconnect with a different identity address after pairing; check `Bonded`/`Trusted` after the first reconnect.
- Reuse the 120 s `CALL_TIMEOUT` style deadline logic and the debounced `DevicesChanged` flow from T-173.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
