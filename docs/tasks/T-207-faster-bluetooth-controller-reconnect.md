# T-207 — Controllers reconnect faster after Bluetooth is switched off and on

Status: todo · Phase: 2 · Depends: — · Area: services, image, shell · Size: S · Owner: lead

## Goal
After Bluetooth is switched off and on again (the Settings toggle, or the adapter coming back), a bonded controller is usable again within a few seconds, not tens of seconds. Owner report, 2026-11-06: "the speed at which the controller reconnects after turning Bluetooth off/on is slow; see if it can be faster".

## What decides the speed (to measure, then tune)
- **The host must be connectable at once.** After `Powered=true` BlueZ starts page scan with a slow default interval. `[BR] FastConnectable=true` in `main.conf` makes the adapter use the fast page-scan setting while it waits for incoming connections (more power, much faster reconnects: the right trade for a mains-powered console).
- **Who reconnects whom.** A DualSense or Xbox pad reconnects when its button is pressed (the pad pages the host); an A2DP headset is usually reconnected by the *host* (`[Policy] ReconnectAttempts`, `ReconnectIntervals`, `ResumeDelay`) or by the headset on power-up. BlueZ defaults are `ReconnectAttempts=7` and `ReconnectIntervals=1,2,4,8,16,32,64` s (exponential back-off: a device that is not there for the first tries is retried only after 8, 16, 32 s).
- **Our own sequence.** `ruya-devices` `set_powered` then a snapshot, a 300 ms debounce and the shell's refresh; `ruya-inputd` hot-plug latency for the new evdev node; PipeWire/WirePlumber attaching the Bluetooth sink; `bluetooth.service` start-up order at boot.
- Adapter level: scan parameters, `Connectable`, `ConnectionTimeout`, USB autosuspend of the dongle (`btusb` `enable_autosuspend` is `Y` on the Dell).

## Scope
1. **Measure on the Dell first** (Intel dongle `hci0`, DualSense, WH-1000XM4): timestamped `btmon`/journal for (a) toggle off -> on, then press PS: time to `Connected: yes` and to the first navigation key in the shell; (b) the headset powered on after the toggle: time to the sink; (c) cold boot to connected at the picker. Put the table in the Outcome (before).
2. **Tune, one change at a time, re-measure:** `FastConnectable=true`; `ReconnectIntervals`/`ReconnectAttempts` (denser early retries, for example `1,1,2,3,5,8,13`); `btusb` autosuspend off for the dongle (udev rule or `modprobe.d`); ordering/`After=` for `ruya-inputd`; have `ruya-devices` call `Connect` on trusted, bonded, in-range devices right after power-on (bounded, off the executor). Keep what measurably helps; revert what does not.
3. **Ship the settings in the image** (a `/usr/lib/bluetooth/main.conf.d/` drop-in if the installed BlueZ reads it, otherwise a documented default through the image) with a comment per setting and the measured effect; note the idle-power cost of `FastConnectable`.
4. If a power-saving idle disconnect exists (T-202), a pad that was disconnected for idleness must also reconnect quickly on a button press.

## Out of scope
- LE audio, pairing flows (T-203), controller battery policy (T-161), power-saving timers (T-202).

## Acceptance criteria
- [ ] Before/after table on the Dell (toggle -> connected, PS press -> navigation key, headset power-on -> sink present, cold boot -> connected at the picker), three runs each, median and worst in the Outcome; target: the pad usable within about 3 s of the press after the toggle.
- [ ] The settings are in the image and `vm-devices-check.sh` (bluetooth part) asserts they are active (the file present and read by `bluetoothd`), so a base-image change cannot silently drop them.
- [ ] If `ruya-devices` gained a "connect trusted after power-on" step: Rust tests (fake BlueZ: only trusted, bonded, not-connected devices; bounded retries; nothing when powered off; the executor is never blocked).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; the hardware numbers are the proof (the VM has no adapter).

## Docs to update
- `03` Bluetooth paragraphs (reconnect behaviour), `image/CLAUDE.md` (the drop-in), `docs/dev-setup.md` (how to measure: the `btmon` recipe).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
