# T-347 - Sound outputs on other card profiles, and a sane volume per output

Status: todo · Phase: 2 · Depends: T-322 · Area: services (ruya-devices audio), image (WirePlumber drop-in), scripts · Size: M · Owner: builder

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
_Filled in by the implementer._
