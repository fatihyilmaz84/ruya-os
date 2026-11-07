# T-262 — Wake from suspend with a controller

Status: todo · Phase: 3 · Depends: T-166, T-202, T-203 · Area: image, services, shell · Size: M · Owner: lead

## Goal
When the console is asleep, pressing the PS or Xbox button of a paired controller (or a key on a USB pad or keyboard) wakes it, where the hardware allows, and the UI is honest where it does not. Owner request, 2026-11-07 (controller onboarding, "ideally"). It needs suspend itself (T-166: under eglfs, in the VM and on the Dell), the sleep timeout (T-202) and the pairing/reconnect work (T-203). Real hardware only for the final check: mark `hw`.

## Read first
- T-166 and T-202 (suspend, sleep timeout, "wake by controller" lines), T-203 (reconnect behaviour), `docs/specs/01-platform.md` (power), `Power1` and `ruya-devices` (Bluetooth), kernel docs for `power/wakeup`, BlueZ `bluetoothd` and `input.conf` (`UserspaceHID`, `ClassicBondedOnly`), logind sleep hooks (`/usr/lib/systemd/system-sleep/`)

## Scope
1. **Mechanisms to evaluate (document what the Dell supports):** (a) the Bluetooth **adapter's** USB wakeup (`/sys/bus/usb/devices/*/power/wakeup` for the Intel dongle or the internal module) so that a bonded device's connection request wakes the host; (b) BlueZ's handling around suspend (hand the connection over: reconnect on resume, `Trusted` devices, the controller's own wake behaviour: DualSense wakes a host through a classic HID reconnect; some pads only wake through the vendor dongle); (c) the vendor **USB dongles and wired pads** (`power/wakeup` of the HID device, `usbhid` remote-wakeup); (d) firmware/BIOS settings (USB power in S3, "wake on USB/Bluetooth") that the user must set: list them per board in the hardware checklist, do not change firmware.
2. **Image/service side:** a small service step (a `ruya-devices` method or a sleep hook) that, just before suspend, enables wakeup on the adapter and on the paired HID devices the user allows, and restores the defaults after; per-device and global switch in Settings -> Bluetooth ("Wake the console with this controller"; off by default? decide with the power task: recommendation on, because the owner asked for it, but a wake-up from a pad in a bag is annoying: the switch is per controller). Never leave a wakeup source enabled that the user turned off.
3. **UI honesty:** the switch is hidden or disabled with a plain reason ("This console's Bluetooth adapter cannot wake it") where the adapter lacks wakeup capability; after a resume the shell shows Home, the pad reconnects, and a short toast "Woken by <controller>" only when that is known.
4. **Resume correctness:** the pad that woke the console must not leave a stuck key or a double press (the first press is consumed as "wake" and is not delivered to the UI), and Bluetooth comes back without a restart.
5. Verification plan: VM checks only for the sysfs and hook logic (a fake `power/wakeup` tree, like the thermal fake in `vm-devices-check.sh`); real wake = the Dell checklist.

## Out of scope
- Wake-on-LAN, HDMI-CEC power on (a later task), hibernation, changing firmware settings, Wi-Fi wake.

## Acceptance criteria
- [ ] Rust tests with a fake sysfs tree: the wakeup sources enabled before suspend and restored after; per-device opt-out respected; a device without the attribute is reported as unsupported; contract-first (`Devices1.xml`: a `SetWakeEnabled(address, bool)` style call and a `WakeCapable` flag; the lead decides the shape).
- [ ] QML tests (mock): the per-controller switch, the unsupported state with its reason, controller-only operation.
- [ ] Hardware (lead, the Dell, with a DualSense and with the Intel dongle): suspend from the shell, wake with the PS button; record success, latency, whether the first press is swallowed, and the BIOS settings needed; if it does not work, record why (adapter, pad, firmware) and make the UI say so.
- [ ] `.\scripts\dev.ps1 test` green; the Outcome states `Verified: hw` only if the Dell woke by the pad.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`._
