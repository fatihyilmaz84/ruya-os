# T-360 - Audio service follow-ups: no executor blocking, the boot race, a fresh-install check that holds

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-devices audio, output policy), scripts · Size: M · Owner: builder · Developer surface: none

## Goal
The audio service never stalls other D-Bus calls during a card switch, picks the saved output even when WirePlumber is late at boot, and the "first start at 100 %" rule fires only on a really fresh console.

## Read first
- `docs/specs/03-services-and-apps.md` (audio, output policy, first volume), `services/CLAUDE.md`
- `services/ruya-devices/src/audio.rs`, `output_policy.rs`, `pipewire.rs`, `dbus.rs` (`with_audio`)
- T-322 and T-347 Outcomes (follow-up lists only); `scripts/vm-audio-check.sh`, `scripts/vm-reboot-check.ps1`

## Scope
1. **No blocking:** move the remaining Audio getters/setters in `dbus.rs` onto `with_audio` (or a cached snapshot), so a 4-8 s card-profile switch never blocks the executor through the mutex.
2. **Boot race:** re-apply the output policy when the first non-empty output list arrives (WirePlumber starts after us).
3. **Fresh install:** "existing install" no longer means only `audio.toml` exists (only channel sliders write it); also count `outputs.toml` and WirePlumber's saved state. A failed boot read does not make the watcher's first good read silent.
4. **Second output volume:** a newly seen output starts at the policy's first volume, not WirePlumber's 0.40 (say in `03` which rule holds).
5. **VM check:** `vm-reboot-check.ps1` gets the saved-output case (choose an output, reboot, it is the default).

## Out of scope
- The Output pane (T-348), the toast, headset hot-plug overriding a saved choice (documented in `03`; leave it).

## Acceptance criteria
- [ ] Rust tests: `a_getter_does_not_wait_for_a_card_switch` (a fake switch that sleeps; the getter answers within 100 ms), `the_policy_is_reapplied_on_the_first_non_empty_list`, `saved_outputs_count_as_an_existing_install`, `a_failed_boot_read_does_not_silence_the_first_good_read`, `a_new_output_starts_at_the_first_volume` (each red when its behaviour is removed).
- [ ] VM (lead run): `vm-reboot-check.ps1` saved-output case; Outcome `Verified: host (vm pending: vm-reboot-check.ps1 saved-output)`.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03` audio (first volume, boot race), `docs/dev-setup.md` if the reboot check's arguments changed.

## Hints
- Inbox lines (T-322, T-347 reviews) are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-09 (lead-7)". The Dell recipe for a fresh-boot 100 % (delete `audio.toml`, `first-volume-done`, WirePlumber state) belongs in the Outcome as the hw step for the lead.

## Outcome
Verified: host (vm pending: vm-reboot-check.ps1 saved-output)

Built (all in `services/ruya-devices`):
1. **No blocking.** `Audio` keeps a `View` (sinks, outputs, volume, mute, playing, channels) behind its own small lock, refreshed by `publish()` after every change (`refresh`, `set_output`, `reset_choice`, `set_default_sink`, `set_volume`, `set_muted`, `set_channel`). The `AudioIface` getters read it, so they never wait for the `Audio` mutex a card switch holds (a `with_audio` getter would still have waited the 4-8 s). The setters (`SetDefaultSink`, `SetChannelVolume`, `MasterVolume`/`Muted` writes) now run through `with_audio`.
2. **Boot race.** The "nothing yet" wait now keys on the output list alone (before: outputs and sinks both empty), so a sink without outputs no longer consumes the first-read policy. A policy that fails on the first non-empty list is not retried (unchanged).
3. **Fresh install.** `audio::existing_install(audio.toml)`: `audio.toml`, `outputs.toml` or WirePlumber's `default-routes` / `stream-properties` (sibling `wireplumber/` of our state directory). A failed read now sets `read_once`, so the watcher's first good read emits its signals.
4. **Second output volume.** `outputs.toml` gains `seen` (ids of outputs used). Activating an unseen output through a profile switch writes `FIRST_VOLUME` (100) and marks it; the output in use at each read is marked without a write. `ResetOutputChoice` keeps `seen`. `03` states the rule.
5. **VM check.** `scripts/vm-saved-output-check.sh` (`choose` / `verify`) and `vm-reboot-check.ps1 -SavedOutput` (docs in `dev-setup.md`).

Tests (all in `cargo test`): `a_getter_does_not_wait_for_a_card_switch` (dbus.rs), `the_policy_is_reapplied_on_the_first_non_empty_list`, `saved_outputs_count_as_an_existing_install`, `a_failed_boot_read_does_not_silence_the_first_good_read`, `a_new_output_starts_at_the_first_volume`. Revert checks (each mutation applied by hand, rebuilt by cargo, file restored): getters taking the audio lock first; `nothing_yet` back to outputs-and-sinks; the `outputs.toml` check removed; `read_once = true` on a failed read removed; the first-volume write on an unseen output disabled. Every one turned its test red. Updated: `first_output_starts_at_full_volume`, `first_start_volume_is_applied_once...` (now 2 writes: the second output's first volume), `volume_is_remembered_per_output`, and the reset test compares `saved`/`rejected` (the file also holds `seen`).

Doubts: WirePlumber may write `default-routes` on a truly fresh boot before our service starts, which would make a fresh console count as existing (no 100 %); unknown without hardware. An existing install treats outputs it used before this update but are not in use at update time as new once (they get 100 % on the first switch).

**hw step for the lead (Dell, fresh-boot 100 %):** stop `ruya-devices`, delete `/var/lib/ruya-shell/.local/state/ruya-devices/{audio.toml,outputs.toml,first-volume-done}` and `/var/lib/ruya-shell/.local/state/wireplumber/`, reboot; expect the speaker at 100 %. If `default-routes` appears in `wireplumber/` before `ruya-devices` starts, the doubt above is real (then drop it from the list in `existing_install`).

**Round 2 (hearing safety, lead decision).** `audio::start_volume(kind)`: Speaker and Hdmi start at `FIRST_VOLUME` (100); Headphones, Usb, Bluetooth and an unknown kind (`None`) at `SAFE_NEW_VOLUME` (40). It decides both a later output's first volume and the one-time first start. Before this round the first start wrote 100 % whatever the default output was (headphones included); now it takes the kind of the output behind the default sink. Tests `a_new_headphone_output_starts_at_the_safe_volume`, `an_unknown_kind_counts_as_headphones`, `the_first_start_on_headphones_gets_the_safe_volume`; red when the kind check is removed (the match arm made 100, the first-start call and the activate call each replaced by `FIRST_VOLUME`). `03` states the rule. Round 2 `dev.ps1 test`: ALL GREEN; the tst_settings flake did not recur.

Files: `services/ruya-devices/src/{audio,dbus,main,output_policy}.rs`, `scripts/vm-saved-output-check.sh`, `scripts/vm-reboot-check.ps1`, `docs/specs/03-services-and-apps.md`, `docs/dev-setup.md`.
