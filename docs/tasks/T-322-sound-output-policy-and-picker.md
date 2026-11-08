# T-322 — Choose the sound output by what is usable, and let the player choose: ports, test sound, remembered

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-devices audio policy), api (Devices1), shell (AudioPane, mock) · Size: M · Owner: builder

## Goal
Silent sound is the first thing a player needs to fix, and today neither the default nor the chooser helps. Found on the Dell (2026-11-08): the card had `Analog Stereo Duplex` active, so the only sink was the analog jack; a monitor with a valid ELD sat on an unused HDMI profile. "HDMI first" (T-320) was wrong: the owner's monitor has no speakers and the Dell's internal speaker (`analog-output-speaker`, available "unknown", priority 10000) is the right output. Neither "HDMI first" nor "analog first" is right everywhere, and an ELD alone does not prove speakers.

## Scope
1. **Default policy** in `ruya-devices` (spec §2.3 gets the rule): the user's saved choice for a device wins; else a plugged headset/headphones (usb, bluetooth, jack with `available = yes`); else an HDMI/DP output whose ELD is valid **and** the owner has not rejected it before; else the internal speaker; else whatever exists. The saved choice is per device (card plus port), stored in `/var/lib/ruya-devices`, survives reboot and hot-plug, and is cleared by "Reset". A new device shows a toast "Sound moved to <name>" (and the old one returns when it disappears; this exists for headsets, extend to ports).
2. **Cards expose all their outputs.** The service switches the card profile / route as needed so every usable port of a card is a selectable output (analog speaker, headphones, HDMI 0..n) even though PipeWire shows only the sinks of the active profile: contract `ListOutputs` (id, name, kind: speaker/headphones/hdmi/usb/bluetooth, card, port, available, is_default, is_saved), `SetOutput(id)`, `TestOutput(id)` (plays a short tone on that port without changing the default); extend `Devices1.xml` first, then the Rust service, mock, D-Bus client.
3. *(Moved to T-348: the pane. Moved to T-347: card profile switching, item 4, and volumes, item 6. This task defines the contract those two use: `ListOutputs`, `SetOutput`, `TestOutput`; `TestOutput` may play on the current profile only until T-347.)*
5. **Default after a reboot:** the saved choice is applied by the service at start and on every hot-plug (it sets PipeWire's default sink and, if needed, the card profile), so the default does not depend on whatever WirePlumber remembered last time (`default.configured.audio.sink` may name a node that does not exist this boot). If the saved output is absent at boot, the policy table picks a fallback **without overwriting the saved choice**, and the saved output becomes the default again the moment it returns (a TV switched on late). A first start with no saved choice uses the policy table.
7. **Remove the T-320 HDMI-first rule** (done by the lead: the file is deleted; T-320's Outcome says why).

## Acceptance criteria
- [ ] Policy table tests (Rust) for: nothing plugged (speaker), HDMI with ELD only, headset plugged and unplugged, saved choice beats the rest, a monitor without speakers that the user rejected stays rejected, **reboot cases**: saved output present at start is the default; saved output absent gives the fallback and keeps the saved choice; it becomes default when it appears; a stale `default.configured` node name is overridden (fake PipeWire state).
- [ ] Contract, mock, D-Bus client and service agree (`ListOutputs`, `SetOutput`, `TestOutput`, signal on change); a `tst_audio` test reads the mock list through the client.
- [ ] VM (lead run): `vm-audio-check.sh` (extend): a fake card or the VM's HDA shows the speaker output chosen; after restarting `pipewire`/`wireplumber` (and after a reboot in `vm-reboot-check.ps1` if cheap) the saved output is still the default sink. Dell (hw): the speaker is the default, plugging HDMI audio does not steal it unless chosen.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; 02 and 03 updated.

## Hints
- **Sliced 2026-11-08 (lead-5):** this task is the policy, the saved choice, the contract and the service (items 1, 2, 5); **T-347** adds card profile/port switching and the volumes; **T-348** is the Settings pane. Each keeps contract, mock, client and service in step.
- Related: T-330 (the ambient bed must be audible) is independent; the 'Settings > Audio should list the card's other outputs by switching its profile' and 'first-start volume 40 % is low' Inbox notes of 2026-11-08 are item 4 and 6 here. **Owner decision (2026-11-08): the first-start volume is HIGH (about 1.00), set once on the first output with a marker file so it never re-applies, later changes are kept; implemented in T-347.**

- (T-330 builder, 2026-11-08) The first-start 0.40 is WirePlumber 0.5.19's own default (`device.routes.default-sink-volume = 0.064`, shown by wpctl as 0.40 on its cubic scale); nothing in `image/` or `ruya-devices` sets a volume. Decided by the owner on 2026-11-08: about 1.00, once (marker file), by `ruya-devices` (T-347); a WirePlumber drop-in is not the route because it cannot be "once". Details: T-330 Outcome.

## Outcome
_Filled in by the implementer._
