# T-261 — Controller families and drivers: what the image supports, what is missing, and a hardware checklist

Status: todo · Phase: 2 · Depends: — · Area: image, services, docs · Size: M · Owner: lead

## Goal
Know, per controller family, what works on RuyaOS today over USB, Bluetooth and a vendor dongle, and close the gaps that are feasible. Today only a DualSense over Bluetooth is verified (Dell, 0.0.44). Owner request, 2026-11-07 (controller onboarding): DualSense, Xbox and 8BitDo must be detected and usable. Feeds T-260 (the guidance text), T-199 (family detection) and T-217 (mapping). Owner-level parts (firmware and driver licensing, brand names) become Proposed ADR text, not decisions.

## Read first
- `image/build/20-base.sh` and `docs/image-packages.md` (what the image ships: kernel, firmware, `iwlwifi`/`ibt` Bluetooth firmware), `ruya-inputd` (`linux.rs` key map), `docs/specs/00-overview.md` ADR-003 (InputPlumber), T-217, T-199, T-203, `docs/specs/01-platform.md`

## Scope
1. **Audit by family** (a table in `docs/specs/01-platform.md` or a new `docs/controllers.md`, with the kernel/driver, the package, the transport and the verification state):
   - **DualSense / DualShock 4 / DualSense Edge:** `hid-playstation` in the kernel (USB and Bluetooth), rumble, light bar, touchpad, motion; known issues (the identity-address change after pairing, `Bonded` check).
   - **Xbox One/Series pads:** USB via `xpad` (in the kernel), Bluetooth via the kernel's `hid-microsoft`/`xpad` support or `xpadneo` (out of tree: is it packaged for Fedora 44? licence GPL-3.0), the **Xbox Wireless Adapter** (needs `xone` or `xow`: out-of-tree, firmware is Microsoft's and **not redistributable**: owner-level), Series pad firmware revisions that break Bluetooth bonding.
   - **8BitDo:** modes (X-input, D-input, Switch, macOS/Android mode): which mode shows as which device, Bluetooth versus the 2.4 GHz dongle, `xpad` quirks, the mode-switch key combos (text for T-260), the `hid-generic` fallback.
   - **Switch Pro / Joy-Con:** `hid-nintendo`; **generic HID** pads and the `SDL_GameControllerDB`-style mapping question (belongs to T-217).
2. **Close feasible gaps:** missing kernel modules or udev rules in the image (small, with a VM check where a device can be faked, e.g. `uinput`/`umockdev` for the device node and the classification in `ruya-inputd`); **any out-of-tree driver or firmware is written up (licence, size, who maintains it) as a Proposed ADR and an Inbox line, not added**.
3. **Detection rules:** the `family` and `kind` classification (vendor/product IDs, Modalias, names) as one table shared with T-199 and T-260; unit-tested on fixtures of the real IDs.
4. **Hardware checklist** `docs/hw-checklists/controllers.md` for the Dell (and any owner pad): per pad a table of tests (USB connect toast, Bluetooth pair from a bond-less state, reconnect after reboot, reconnect after the pad slept, battery shown, rumble, button test, behaviour at the login screen, wake from suspend once T-262 exists), a column to fill in, and the commands to collect logs (`bluetoothctl`, `journalctl -u bluetooth`, `udevadm info`, `evtest`).

## Out of scope
- Installing out-of-tree drivers or firmware (owner decision), mapping UI (T-217), the onboarding screens (T-260), wake from suspend (T-262).

## Acceptance criteria
- [ ] The family table exists with a verification state per cell (`hw`, `vm`, `unverified`) stated honestly; every unsupported cell says what would be needed and who decides.
- [ ] Classification table with tests on fixtures; T-199 and T-260 refer to it.
- [ ] Any image change passes `scripts/check-image-manifest.sh` and has a "VM (this task)" check or is listed on the VM queue.
- [ ] The hardware checklist is written and linked from `docs/dev-setup.md`; Proposed ADR text and Inbox lines for the owner-level items.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`._
