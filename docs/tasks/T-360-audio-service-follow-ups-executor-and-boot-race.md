# T-360 - Audio service follow-ups: no executor blocking, the boot race, a fresh-install check that holds

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-devices audio, output policy), scripts · Size: M · Owner: builder · Developer surface: none

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
_Filled in by the implementer._
