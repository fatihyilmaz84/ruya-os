# T-339 - VM check scripts: power-saving wake, sounds probe and `jq`

Status: todo · Phase: 2 · Depends: — · Area: scripts · Size: S · Owner: builder

## Goal
Four VM checks passed on image 0.0.54 for the wrong reasons or failed for a script reason. Fix the scripts so the next image run (0.0.55 or later) gives a verdict that means what it says. No product code changes.

## Read first
- `scripts/vm-power-saving-check.sh` (`wake_check`, `ambient_on`, `VM_CHECK_LIB_ONLY`), `scripts/vm-sounds-check.sh`, `scripts/vm-sounds-probe.qml`, `scripts/test-vm-checks.sh`, `scripts/lint-vm-checks.ps1`, `docs/tasks/T-193-vm-script-robustness.md` (house rules for VM scripts)
- The findings (verbatim) are in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)": the lines tagged T-296, T-313, T-321 and "0.0.54 VM run"
- `docs/tasks/T-296-*.md`, `T-313-*.md`, `T-321-*.md` Outcomes (what the checks cover)

## Scope
1. `vm-power-saving-check.sh` `wake_check`: count frames only after the key press (or require `on_frames > off_frames`); make sure `tracing_on` is 1 before counting; print "ALL PASS (n UNVERIFIED)" when something was unverified instead of a bare pass; a `trap` that removes the idle-divisor drop-in and the tracepoint on every exit path; running the file as a program with `VM_CHECK_LIB_ONLY` set exits 2 with a message. `ambient_on` waits for a running Stream/Output/Audio node instead of reading once.
2. `vm-sounds-check.sh`: the ambient playback probe fails on the image with `Requested output sample rate 0 is invalid` (Qt ffmpeg in an offscreen `--load` probe, even with `XDG_RUNTIME_DIR`, D-Bus and `QT_AUDIO_BACKEND=pulseaudio`) while the real shell's ambient stream is in the graph. Decide: run the probe inside the compositor session, or drop it and keep the graph check (a `running` ambient stream) as the proof; say which and why. Replace the `jq` use by `python3 -I` JSON parsing (the image has no `jq`; PLANNING.md: VM checks parse JSON with python3, never key order). Re-check the "no second copy of the bundled theme" step against what T-294 changed.
3. `vm-session-check.sh`: the comment in check mode "forgets them when it restarts" is outdated since T-290; fix it. (The usage check's power cut kills the app too since T-290: confirm the comment says so.)
4. `scripts/test-vm-checks.sh` gets a case for each fixed function that can run off a fixture (no VM): the frame counter with a fixture trace, the JSON parse without `jq`.

## Out of scope
- Changing what the product does; the DRM page-flip errors on virtio-gpu (Dell look-at list); the checker rules for the sound theme (T-330).

## Acceptance criteria
- [ ] `scripts/test-vm-checks.sh`: `wake_counts_only_frames_after_the_key` (a fixture trace where frames before the key must not count; revert: count from the start turns it red), `unverified_checks_do_not_print_a_bare_all_pass`, `json_parse_needs_no_jq`, `lib_only_as_a_program_exits_2`.
- [ ] `scripts/lint-vm-checks.ps1` and `dev.ps1 test` ALL GREEN (`bash -n` on every touched script).
- [ ] VM (lead run): `vm-power-saving-check.sh timeline` and `vm-sounds-check.sh` on the next image give a verdict without script errors. Outcome `Verified: host (vm pending: vm-sounds-check.sh, vm-power-saving-check.sh)`.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md` (what the two checks print and need), the Outcome of nothing else.

## Hints
- `$` and backslashes in WSL/bash through PowerShell are mangled: write the scripts with Write/Edit.
- Overlap: T-341 also touches `scripts/` (lint) but different files.

## Outcome
_Filled in by the implementer._
