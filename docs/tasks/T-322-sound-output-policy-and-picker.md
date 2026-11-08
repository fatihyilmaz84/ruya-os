# T-322 — Choose the sound output by what is usable, and let the player choose: ports, test sound, remembered

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-devices audio policy), api (Devices1), shell (AudioPane, mock) · Size: L · Owner: lead

## Goal
Silent sound is the first thing a player needs to fix, and today neither the default nor the chooser helps. Found on the Dell (2026-11-08): the card had `Analog Stereo Duplex` active, so the only sink was the analog jack; a monitor with a valid ELD sat on an unused HDMI profile. "HDMI first" (T-320) was wrong: the owner's monitor has no speakers and the Dell's internal speaker (`analog-output-speaker`, available "unknown", priority 10000) is the right output. Neither "HDMI first" nor "analog first" is right everywhere, and an ELD alone does not prove speakers.

## Scope
1. **Default policy** in `ruya-devices` (spec §2.3 gets the rule): the user's saved choice for a device wins; else a plugged headset/headphones (usb, bluetooth, jack with `available = yes`); else an HDMI/DP output whose ELD is valid **and** the owner has not rejected it before; else the internal speaker; else whatever exists. The saved choice is per device (card plus port), stored in `/var/lib/ruya-devices`, survives reboot and hot-plug, and is cleared by "Reset". A new device shows a toast "Sound moved to <name>" (and the old one returns when it disappears; this exists for headsets, extend to ports).
2. **Cards expose all their outputs.** The service switches the card profile / route as needed so every usable port of a card is a selectable output (analog speaker, headphones, HDMI 0..n) even though PipeWire shows only the sinks of the active profile: contract `ListOutputs` (id, name, kind: speaker/headphones/hdmi/usb/bluetooth, card, port, available, is_default, is_saved), `SetOutput(id)`, `TestOutput(id)` (plays a short tone on that port without changing the default); extend `Devices1.xml` first, then the Rust service, mock, D-Bus client.
3. **Settings > Audio > Output**: the list of outputs (current marked, unavailable ones greyed with the reason), a **Test sound** row that plays the tone on the focused output, A to choose; the mock gets three outputs for tests; screenshots.
4. **Remove the T-320 HDMI-first rule** (done by the lead: the file is deleted; T-320's Outcome says why).

## Acceptance criteria
- [ ] Policy table tests (Rust) for: nothing plugged (speaker), HDMI with ELD only, headset plugged and unplugged, saved choice beats the rest, a monitor without speakers that the user rejected stays rejected.
- [ ] Contract, mock, client and pane agree; the pane lists ports, marks the current one, tests a sound, remembers the choice (test).
- [ ] VM: a fake card or the VM's HDA shows the speaker output chosen; Dell: the speaker is the default, plugging HDMI audio does not steal it unless chosen.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN; 02, 03, 04 updated.

## Outcome
_Filled in by the implementer._
