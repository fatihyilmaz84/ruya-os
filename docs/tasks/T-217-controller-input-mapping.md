# T-217 — Controller input mapping: InputPlumber, button test, player numbers, remapping

Status: todo · Phase: 3 · Depends: — · Area: image, services, shell · Size: M · Owner: lead · Developer surface: public-API

## Goal
Controllers behave the same in every game and the player can see and adjust how: the console presents every pad to apps as a standard virtual gamepad, shows each connected controller with its battery and player number, has a button test, and lets the player swap A/B, adjust dead zones and, in a second step, remap buttons. Owner request, 2026-11-06 ("input mapping"). Today `ruya-inputd` (a stopgap, ADR-003) turns pad events into navigation keys for the shell and does not grab devices; games read the raw devices.

## Read first
- `docs/specs/00-overview.md` ADR-003 (InputPlumber, virtual Xbox-style pads), the input paragraphs (B-006 in `STATUS.md`: also owns key repeat, stick repeat speed, Accept long-press/context menu 02 §4.3, Bluetooth PIN pairing, player assignment, button test, remapping, T-136), `docs/specs/02-shell.md` §4.3 (controller rules), `services/ruya-inputd`, `image/rootfs/usr/lib/udev/rules.d/70-ruya-input.rules`
- InputPlumber (ShadowBlip): D-Bus API (`org.shadowblip.InputManager`), device YAML (capability maps), composite devices, the virtual device types (Xbox 360/Elite, DualSense, generic), and whether a Fedora 44 package exists or it must be built (licence: GPL-3.0: compatible; packaging decision recorded)
- The Dell: DualSense (054C:0CE6) over Bluetooth and the dongle; `evtest` output; what Steam Input/Flatpak apps see today

## Scope
1. **Spike and decision (first, in the Outcome):** InputPlumber in the image (package or build step, service unit, D-Bus policy, hardening, memory), what it grabs and re-emits, how the shell's navigation keeps working (the shell reads the virtual pad), whether `ruya-inputd` can be retired, and the effect on Bluetooth reconnect time (T-207) and the login screen (T-203). If InputPlumber does not fit, propose the alternative with the same acceptance (record it as an ADR *Proposed*, `blocked` with the question).
2. **Phase 1, built here:** (a) every pad is re-emitted as one virtual Xbox-style gamepad (a per-controller choice later), the physical devices are grabbed so games never see duplicates; (b) shell navigation and the Guide button keep working from the virtual pad (the existing shell tests and `vm-app-check.sh` pass); (c) **Settings -> Controllers** (new pane next to Bluetooth, or the Bluetooth & controllers pane): one row per connected controller (name, icon per T-199, battery per T-223, player number 1-4, connection type), **Player number** (assign; the DualSense light bar/LED and Xbox ring follow where the hardware allows), **Button layout** (Xbox / Nintendo: swaps A/B and X/Y), **Dead zones** (left and right stick sliders, trigger threshold), **Vibration test**, **Motion/touchpad on/off** (DualSense gyro and touchpad as separate inputs: off by default for navigation); (d) a **Button test** page: a drawn pad whose buttons, sticks and triggers light up live, plus the raw values, for the selected controller; B twice to leave; (e) settings stored per controller (by unique id) per device; per-profile mapping is Inbox (needs profile preferences).
3. **Phase 2, a follow-up task if it does not fit:** button **remapping** (any button to any button, per controller), saved and applied through the InputPlumber device config; presets (Default, Southpaw, Nintendo).
4. Key repeat, stick-to-navigation repeat speed and Accept long-press / context menu decisions from B-006 are recorded in the Outcome (implemented here or filed).

## Out of scope
- PIN/passkey Bluetooth pairing (B-006 later), Steam Input configuration UI (Steam's own), gyro aiming, macros, mouse/keyboard emulation from the pad (desktop mode), force-feedback effects authoring.

## Acceptance criteria
- [ ] The spike section in the Outcome answers each question in Scope 1 with evidence from the VM and the Dell (versions, memory use, a trace of a pad's events before/after).
- [ ] VM (this task, image build): the image boots, the virtual pad exists next to a (virtual) physical one, the physical device is grabbed, the shell navigates from the virtual pad (`vm-inject-key.py`-style injection through uinput), the existing VM checks pass; `ruya-inputd` is removed or its remaining job is stated.
- [ ] Rust/QML tests for the layout swap, dead-zone mapping, player assignment and the settings persistence; the Controllers pane and Button test pane tests with a mock backend (every control operable with the controller keys only, focus asserted); screenshots of the pane and the button test (English and Turkish), read against `04` §8.
- [ ] Hardware (lead, the Dell): the DualSense shows in Controllers with its battery and player 1, the button test lights every button, A/B swap changes navigation and a game test app's reading, the dead zone is felt in the test app.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- ADR-003 status in `00-overview.md`, `01-platform.md`/`02-shell.md` (input), `03` (the controller paragraphs), `docs/developers/` (the controller input chapter, T-214: what apps receive), `docs/dev-setup.md`, B-006 in `STATUS.md`.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): the standard virtual gamepad is what every app sees. Missing: update `docs/developers/controller-input.md` (button map, dead zones as the app sees them), a sample, a conformance check; rumble pass-through is unplanned.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
