# T-330 — The ambient bed must be audible on a small speaker and on a TV, and the checker must say so

Status: in-progress · Phase: 2 · Depends: T-321 · Area: scripts (make-sounds.py), shell (SoundThemeCheck, fixtures, sound-themes guide), image (sink default volume, as a finding) · Size: M · Owner: lead

## Goal
With T-321 the Dreamglass ambient bed finally plays on the Dell (stream `running` at 24 kHz, no format errors), but the owner hears nothing: the bed has its energy at 73-150 Hz (peak -12 dBFS before gain) and plays at theme gain 0.7, Ambient slider 100 % and a sink volume of 0.40 through the OptiPlex 7080's tiny internal speaker, which does not reproduce below about 200 Hz. A bed that cannot be heard on a 5 cm speaker or a TV is a design failure.

## Scope
1. **Redesign the beds** in `scripts/make-sounds.py` for every bundled and example theme: a soft pad with its energy between about 200 Hz and 4 kHz (fifths and octaves above 200 Hz, gentle low-pass near 4 kHz, little below 120 Hz), seamless loop of whole cycles as today (loop points, `--verify`), a perceived level of about -26 to -22 LUFS integrated before theme gain (quiet but audible on a 5 cm speaker at a normal sink volume) and a true peak below -3 dBFS; the FLAC frame headers keep naming the sample rate (T-321).
2. **Checker rule** (`SoundThemeCheck.cpp`, fixtures, `lint-sound-themes.ps1`, `docs/developers/sound-themes.md`): an ambient file is refused when more than a stated share of its energy is below 150 Hz or when it is nearly silent (RMS window), with a fixture of each (a sub-bass-only bed, a near-silent bed) and an accepted one; keep it cheap and hostile-file-safe (decode with the existing path, bounded work, no hang).
3. **Listen on the Dell** (the owner's standing permission: the Dell is a test machine, root over SSH with `~/.ssh/ruyaos_dev`, `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`; overlays in `/run` vanish on reboot; report every change as `Dell: ...`). The runtime overlay of T-321 is still there: `/usr/share/ruyaos/sounds/dreamglass/ambient.flac` is a bind mount of `/run/t321/ambient.flac` and the drop-in `/run/systemd/system/ruya-compositor@tty1.service.d/90-t321-ambient.conf` does it; replace the file in `/run/t321/` with your new bed and restart `ruya-compositor@tty1`. Measure with the sink monitor (`pw-record --target <sink>.monitor`, peak and RMS in the 200-4000 Hz band) and say what the owner should hear; the lead relays "listen now" to the owner. The Dell sink volume was set to 1.00 by the lead for the test.
4. **Finding to record (no code):** the sink volume at first start was 0.40 on the Dell. Say in the Outcome whether that is our default or a leftover (look for `ruya-devices`/WirePlumber defaults) and propose a sane console default (a high sink volume, the TV controls the loudness): that becomes part of T-322.

## Acceptance criteria
- [ ] The regenerated Dreamglass and example beds measure within the stated level and band rules (numbers in the Outcome); loops still whole cycles, `--verify` green.
- [ ] The checker refuses the two bad fixtures and accepts the shipped themes; `.\scripts\dev.ps1 test` ALL GREEN.
- [ ] On the Dell the new bed is `running` and measured at the sink; the lead gets a sentence to relay to the owner.

## Outcome
_Filled in by the implementer._
