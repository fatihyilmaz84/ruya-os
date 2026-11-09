# T-347 - Sound outputs on other card profiles, and a sane volume per output

Status: done · Phase: 2 · Depends: T-322 · Area: services (ruya-devices audio), image (WirePlumber drop-in), scripts · Size: M · Owner: builder

## Goal
Two findings from the Dell (2026-11-08): (1) PipeWire shows only the sinks of the card's active profile (`Analog Stereo Duplex`: the jack only; `HDMI Stereo`: HDMI only), so an output on another profile cannot be chosen; (2) the first-start volume was 0.40: WirePlumber 0.5.19's own default (`device.routes.default-sink-volume = 0.064`, shown by `wpctl` as 0.40 on its cubic scale), nothing in `image/` or `ruya-devices` sets a volume. This task makes every usable port selectable and gives each output a sensible, remembered volume.

## Read first
- `docs/tasks/T-322-sound-output-policy-and-picker.md` (contract `ListOutputs`/`SetOutput`/`TestOutput`, saved choice) and its Outcome once merged; `docs/tasks/T-330-ambient-bed-must-be-audible-on-small-speakers.md` Outcome (the volume finding, the numbers)
- `services/ruya-devices` audio module (PipeWire/WirePlumber access, the fake), `image/rootfs` WirePlumber configuration, `docs/specs/03-services-and-apps.md` audio paragraphs, `docs/specs/01-platform.md` §2.3

## Scope
1. **Profile and port switching (service):** when the chosen output lives on another profile of the same card, the service switches the card profile and the active route/port to reach it; the other profile's outputs stay listed as selectable (`ListOutputs` reads card profiles and routes, not just sinks); a profile borrowed only for `TestOutput` is restored afterwards; a card is never left on a profile with no sink.
2. **First-start volume (owner decision, 2026-11-08: HIGH, set once):** a fresh install starts **high, about 1.00 (full), on the first output only**, because the TV or monitor controls the loudness. `ruya-devices` sets it **once**, at first boot / when the first sink appears, and writes a **marker file** under `/var/lib/ruya-devices` so it **never re-applies**: not after a reboot, a service restart, a profile or output change, or an update. Whatever the player sets afterwards is kept forever (a later change is never overwritten, and neither is a volume WirePlumber saved). The service does it, not a WirePlumber default drop-in (a drop-in would apply to every route and every boot and cannot know "once"); if the builder finds the drop-in route clearly better, say why in the Outcome and keep the "once, marker file" behaviour. Outputs that appear later keep WirePlumber's own default or saved volume (the decision names the first output only: record in the Outcome what the second output starts at, and add an Inbox line if that is too low). The volume is remembered per output (switching to HDMI and back restores each); the UI sound level sliders (T-227) are untouched; the test tone's own level is capped (80 % of full scale) so a high sink volume cannot make it painful.
3. **Fake PipeWire/route model** in the service tests with two profiles on one card (speaker + jack on analog, HDMI on another).

## Out of scope
- The Settings pane (T-348), new output kinds, loudness normalisation.

## Acceptance criteria
- [ ] Rust tests: `choose_output_switches_the_card_profile`, `test_output_restores_the_profile`, `a_card_is_never_left_without_a_sink`, `first_output_starts_at_full_volume`, `first_start_volume_is_applied_once_and_the_marker_is_written`, `first_start_volume_never_reapplies_after_the_player_changed_it` (set a volume, restart the service and reboot the fake: unchanged, marker present), `a_set_volume_is_never_touched`, `volume_is_remembered_per_output`, `test_tone_is_capped_at_80_percent` (each turns red when the behaviour is removed; say how in the Outcome).
- [ ] VM (lead run): `vm-audio-check.sh` extended: on the VM's HDA card the first-start volume is about 1.00 and the marker file exists, a volume set by hand survives a restart of `pipewire`, `wireplumber` and `ruya-devices` (the marker stops it being re-applied). Outcome `Verified: host (vm pending: vm-audio-check.sh)`. Dell (hw): speaker volume after a fresh boot (high, not 0.40), then lowered by hand and still lowered after another reboot, HDMI listed and selectable.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; `01`/`03` updated.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (audio: profiles, volumes), `docs/dev-setup.md` if the VM check changes.

## Hints
- The service must not fight WirePlumber: set the profile through the same PipeWire/`wpctl`/D-Bus path the policy uses, one writer per setting.
- `image/` changes (the drop-in) need the "VM (this task)" rule of CLAUDE.md only if they are unit/policy changes; a conf drop-in is checked by `vm-audio-check.sh` in the lead's image run.

## Outcome
Verified: host (vm pending: vm-audio-check.sh)

Built (all in `services/ruya-devices`):
- **Profiles:** the `PipeWire` trait lost `activate` and gained `card_profile`, `switch_to`, `restore_profile`; `Audio::activate_output` is the one path for `SetOutput`, the policy and the headset rule. `WpCtl` (Linux, `pipewire.rs`) implements them with `wpctl set-profile`, `pw-cli set-param ... Route {save: true}` and polling `pw-dump`; the pure planning (`plan_switch`, `card_state`, `parse_state`, `find_sink`) is unit-tested on a dump. A failed switch or default restores the old profile. `TestOutput` on a sink-less output borrows the profile and restores it (the call waits for the tone, under half a second), then re-asserts the default.
- **First-start volume:** `Audio::with_first_start_marker` (main.rs passes `first-volume-done` next to `audio.toml`): the first time a default sink exists, `set_volume(100)`, then the marker is written; a marker that exists or a failed write never lets it repeat. Service, not a drop-in (as the task prefers). Second output: WirePlumber's own default (0.40 as `wpctl` shows it), then WirePlumber's per-route saved volume; the service never writes a volume otherwise. If 0.40 is too low for the second output, see the inbox line.
- **Policy re-apply:** the first read with any output (not an empty list at boot) is the "first" one, so the policy still runs once WirePlumber has outputs.
- **Tone:** `TONE_CAP = 0.8`, tone level 0.4.
- Fake: `FakeCard`/`FakeProfile` (analog: speaker + empty jack, hdmi, a `dead` profile with no sink, `off`), per-route volumes like WirePlumber.

Tests (445 lib tests in ruya-devices): the nine named in the criteria plus `the_policy_may_pick_an_hdmi_port_on_an_inactive_profile`, `an_empty_first_read_waits_...`, `first_start_volume_waits_for_the_first_output`, and three `pipewire.rs` parser tests. Revert checks (done by hand with a mutate-build-test-restore script, `revert-check.ps1` is QML-only): no restore after a failed switch -> `a_card_is_never_left_without_a_sink`; no restore after the tone -> `test_output_restores_the_profile`; volume 50 instead of 100 -> `first_output_starts_at_full_volume`; marker not honoured -> `first_start_volume_never_reapplies_...`; `first_start_done` never set -> `first_start_volume_is_applied_once_...`, `a_set_volume_is_never_touched`; fake without per-route memory -> `volume_is_remembered_per_output`; switch always failing -> `choose_output_switches_the_card_profile`; tone level 1.0 without the cap -> `test_tone_is_capped_at_80_percent`.

Files: `audio.rs`, `pipewire.rs`, `output_policy.rs`, `dbus.rs` (trait forwarding), `main.rs`, `scripts/vm-audio-check.sh` (marker, volume set by hand survives pipewire/wireplumber/ruya-devices restarts: `AUDIO_VOLUME_KEPT_OK`), `docs/specs/03-services-and-apps.md` (`01` needs no change). 

Unverified on the host: `WpCtl` switching (`wpctl set-profile`, `pw-cli set-param Route`, the settle polling), the marker under the unit's real state directory, WirePlumber restoring each route's volume (the fake models it). Dell: high volume after a fresh boot, HDMI selectable.

### Round 2 (review fixes)
- Marker and `outputs.toml` live in the `ruya-shell` user unit's state directory, `/var/lib/ruya-shell/.local/state/ruya-devices` (spec 03 and `vm-audio-check.sh` corrected). The check now asserts: `AUDIO_FIRST_VOLUME_OK` only with the marker and a volume >= 0.95 read before the manual set; waits 12 s for WirePlumber to save before restarting pipewire, wireplumber, ruya-devices (`AUDIO_VOLUME_KEPT_OK`).
- `SetOutput`, `TestOutput`, `ResetOutputChoice` and the watcher's refresh run through `dbus::with_audio` (`blocking::unblock`). Other `Audio` calls still wait for the same lock during a switch; other interfaces are not blocked. Test `a_slow_card_switch_does_not_block_the_executor` (fake switch delay 600 ms; a timer on the same executor finishes within 300 ms); run inline instead of `unblock` it fails.
- Only the very first `refresh()` swallows its changes (`read_once`); the late first non-empty read reports sinks, outputs and default (`an_empty_first_read_...` extended; reverting to `if first` fails it).
- Marker write failures are logged; an existing install (`audio.toml` present at start) gets the marker at once and no forced volume (`an_existing_install_gets_the_marker_...`; edge: a fresh install whose shell writes `audio.toml` before any sink exists, then a service restart, is treated as existing: volume not forced). `plan_switch` prefers a route device that belongs to the chosen profile's `EnumProfile` `card.profile.devices` (fixture with two candidate devices; the format of `classes` in real `pw-dump` is read tolerantly and unverified). `WpCtl::restore_profile` waits for the old sink before `test_output` re-sets the default.
