# T-287 — Display service follow-ups: hot-plug signal, check the real mode after the restart, recovery argument

Status: todo · Phase: 2 · Depends: T-282 · Area: api, services (ruya-devices display), shell (display backend), scripts · Size: M · Owner: builder

## Goal
Plugging or unplugging a screen updates the Display pane without reopening it; after a mode change the shell compares what Qt actually shows with what was asked and reverts at once if they differ; a console whose confirmed mode the new TV cannot show recovers from the boot menu.

## Read first
- `api/dbus/org.ruyaos.Devices1.xml`, interface `Display` (safe-switching text, `ListOutputs`, `GetPending`, `Keep`, `Revert`, the display guard)
- `services/ruya-devices/src/display.rs`, `edid.rs`, `dbus.rs`; `shell/src/display/` (`Display`, `DBusDisplayBackend`, `MockDisplayBackend`); `shell/qml/DisplayPane.qml`, `ModeConfirm.qml`
- T-198 Outcome; `scripts/vm-display-check.sh`; T-282 item 9 (the recovery decision); T-269 (hidden boot menu, kernel arguments)
- STATUS-parked.md "Inbox triage 2026-11-07", bullets T-287

## Scope
1. **Contract first** (XML, then Rust service with tests, mock, D-Bus client): a signal `OutputsChanged` when a connector's status or mode list changes. Source: a udev monitor if the crate set already has one, else poll `/sys/class/drm/*/status` every 2 s like `InputPresent`; a fakeable source with fixtures. Debounce bursts.
2. **Shell:** `Display` reloads the outputs on the signal; an open mode picker whose output vanished closes with a toast ("Screen disconnected").
3. **Real vs asked mode:** after the restart, when `GetPending` is non-empty, compare the real `QScreen` size and refresh with the pending ones; a mismatch calls `Revert` at once without showing the 15 s dialog (reason in the journal). Qt's eglfs name/`mode` key behaviour is from memory until the VM `switch` check: verify there.
4. **Recovery argument:** per T-282 item 9 (default: the kernel argument `ruya.display_reset=1`, set from a boot-menu entry, honoured once by `ruya-devices --display-guard`, which then drops the stored mode and answers `TakeFallbackNotice`). If T-282 chose otherwise, follow it.

7. **Dell finding, 2026-11-08 (hardware, owner's Gigabyte G32QC 2560x1440@144 on the OptiPlex 7080):** the connector is `HDMI-A-1` but the kernel detected a **DP dual-mode adapter type 1 (max TMDS 165 MHz)**, so it pruned every mode above 1080p60 (`dmesg` with `drm.debug=0x16`: `Rejected mode ... (CLOCK_HIGH)` for 2560x1440 at 60/120/144, 1080p120/144, `NO_420` for 4K60). Our Display service nevertheless listed and defaulted to `1920x1080@143.85` (an EDID timing the kernel rejected; the real mode is 1080p60, `port_clock=148500`). Fix: list **only modes in the connector's kernel `modes` file** (EDID timings only refine the refresh rate of a mode the kernel offers), never mark a pruned EDID mode preferred or current; and when the EDID has modes the kernel pruned, let the Resolution row say why ("Your cable or adapter limits this screen to 1080p. A DisplayPort cable allows up to 2560x1440 at 144 Hz.") using the EDID's best mode and the dmesg-free signal that the EDID's preferred mode is missing from the kernel list. Add a Rust test with this exact EDID shape (a 1440p DTD plus a kernel list without it).

## Out of scope
- Multi-output layouts, a "Screen" row for several outputs (T-288), HDR/VRR (T-218, T-222), any image change beyond the boot-menu entry text (if the entry needs `image/` edits, add an Inbox line for T-299).

## Acceptance criteria
- [ ] Rust tests: a fake source flipping a connector emits `OutputsChanged` once per burst; the guard with the argument drops the stored mode, without it keeps it (each fails with the logic reverted).
- [ ] `tst_display.qml::test_outputs_changed_reloads` and `::test_picker_closes_when_output_vanishes` (mock backend can emit the signal); `::test_mode_mismatch_reverts` with the mock reporting a different `QScreen` mode.
- [ ] Contract, mock, client and service agree (method, signal and status names).
- [ ] UX: from every new state Back leaves; focus lands sensibly after the picker closes; Outcome has a `UX notes:` line.
- [ ] VM (lead run): `scripts/vm-display-check.sh` gains a `hotplug` part (fake connector status via the fixture path the check already uses) and a `reset` part; Outcome `Verified: host (vm pending: vm-display-check.sh hotplug reset)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```
VM (lead): `scripts/vm-display-check.sh hotplug reset` on the next image.

## Docs to update
- Display interface text in the XML, `03-services-and-apps.md` (Display), `01-platform.md` if the boot argument is new.

## Hints
- Reference: `services/ruya-devices/src/storage.rs` events and `InputPresent` for a polled source.
- Overlaps T-288 (`DisplayPane.qml`, `tst_display.qml`): run in sequence.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
