# T-347 - Sound outputs on other card profiles, and a sane volume per output

Status: todo · Phase: 2 · Depends: T-322 · Area: services (ruya-devices audio), image (WirePlumber drop-in), scripts · Size: M · Owner: builder

## Goal
Two findings from the Dell (2026-11-08): (1) PipeWire shows only the sinks of the card's active profile (`Analog Stereo Duplex`: the jack only; `HDMI Stereo`: HDMI only), so an output on another profile cannot be chosen; (2) the first-start volume was 0.40: WirePlumber 0.5.19's own default (`device.routes.default-sink-volume = 0.064`, shown by `wpctl` as 0.40 on its cubic scale), nothing in `image/` or `ruya-devices` sets a volume. This task makes every usable port selectable and gives each output a sensible, remembered volume.

## Read first
- `docs/tasks/T-322-sound-output-policy-and-picker.md` (contract `ListOutputs`/`SetOutput`/`TestOutput`, saved choice) and its Outcome once merged; `docs/tasks/T-330-ambient-bed-must-be-audible-on-small-speakers.md` Outcome (the volume finding, the numbers)
- `services/ruya-devices` audio module (PipeWire/WirePlumber access, the fake), `image/rootfs` WirePlumber configuration, `docs/specs/03-services-and-apps.md` audio paragraphs, `docs/specs/01-platform.md` §2.3

## Scope
1. **Profile and port switching (service):** when the chosen output lives on another profile of the same card, the service switches the card profile and the active route/port to reach it; the other profile's outputs stay listed as selectable (`ListOutputs` reads card profiles and routes, not just sinks); a profile borrowed only for `TestOutput` is restored afterwards; a card is never left on a profile with no sink.
2. **First-start volume:** the first time a sink is seen with no saved volume the service sets 70 % (decide whether the WirePlumber default drop-in `wireplumber.conf.d/50-ruyaos-volume.conf` or the service does it, one place only, and say why in the Outcome); a volume the player set is never changed, across restart and reboot; the volume is remembered per output (switching to HDMI and back restores each); the UI sound level sliders (T-227) are untouched; a test sound plays at the output's volume, never above 80 %.
3. **Fake PipeWire/route model** in the service tests with two profiles on one card (speaker + jack on analog, HDMI on another).

## Out of scope
- The Settings pane (T-348), new output kinds, loudness normalisation.

## Acceptance criteria
- [ ] Rust tests: `choose_output_switches_the_card_profile`, `test_output_restores_the_profile`, `a_card_is_never_left_without_a_sink`, `first_start_volume_is_70_percent`, `a_set_volume_is_never_touched`, `volume_is_remembered_per_output`, `test_tone_is_capped_at_80_percent` (each turns red when the behaviour is removed; say how in the Outcome).
- [ ] VM (lead run): `vm-audio-check.sh` extended: on the VM's HDA card the first-start volume is 70 %, a volume set by hand survives a restart of `pipewire` and `wireplumber`. Outcome `Verified: host (vm pending: vm-audio-check.sh)`. Dell (hw): speaker volume after a fresh boot, HDMI listed and selectable.
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
