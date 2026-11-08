# T-296 — VM check script fixes: checks that pass for the wrong reason, early exits, missing cases

Status: done · Phase: 2 · Depends: — · Area: scripts (vm-*-check) · Size: M · Owner: builder

## Goal
The VM checks fail when the thing they check is broken (not only when the call itself fails), clean up after themselves on every exit, and cover the cases review rounds found missing. The lead's next VM run exercises them.

## Read first
- `docs/dev-setup.md` (VM checks), PLANNING.md lesson "VM checks parse JSON, never key order"
- The scripts: `scripts/vm-storage-check.sh`, `vm-iso-check.ps1`, `vm-sample-check.sh`, `vm-devices-check.sh`, `vm-sounds-check.sh` and `vm-sounds-probe.qml`, `vm-power-saving-check.sh`, `vm-boot-check.sh`, `vm-lib.ps1`
- STATUS-parked.md "Inbox triage 2026-11-07", bullets T-296 (and "Inbox lines parked 2026-11-06": T-193, T-214, VM 0.0.48-lead)

## Scope
1. **`vm-storage-check.sh`:** a refused action must be `pkcheck` exit 1, not any non-zero; the "left the list" waits first assert that `ListVolumes` succeeded (an error reply is not an empty list).
2. **`vm-iso-check.ps1`:** refuse `output\qcow2\disk.qcow2` and `work.qcow2` as `-Disk` (they are the dev disks; the check wipes the target).
3. **`vm-sample-check.sh`:** `trap cleanup EXIT` so an early failure still cleans; the "within 5 s" poll gets 6 s.
4. **`vm-devices-check.sh`:** volume records are split by parsing `busctl --json=short` with python3, not at the `"drive"` key (BTreeMap order); the `storage` part keeps its retry, `thermal-fake` its exponent parser (host-checked only until the VM run).
5. **`vm-sounds-check.sh`:** add a directory-symlink escape case (a theme whose subfolder links outside is refused); `vm-sounds-probe.qml` runs with the shell user's `XDG_RUNTIME_DIR`.
6. **`vm-power-saving-check.sh`:** after the display comes back on, check that frames are being produced again (DPMS versus atomic page flips), e.g. the compositor's frame counter or a screenshot differing from the black one.
7. **`vm-boot-check.sh`:** state in a comment (and in the Outcome) that it cannot see the grub-menu unit's own `/boot` remount (private namespace), and check the observable result instead (`/boot` mounted ro afterwards).

## Out of scope
- Running the VM (lead run); new service features; `vm-audio-check.sh` headset cycles (hardware).

## Acceptance criteria
- [ ] Every script passes `bash -n` (or PowerShell parse for `.ps1`) and `scripts\lint-text.ps1`; `git ls-files -s` shows the exec bit on `.sh` files.
- [ ] For each of items 1-7 the Outcome names the line that makes the check fail on a broken service, and for the ones that can run on the host (sample/devices JSON splitting with a canned `busctl` output file, `vm-iso-check.ps1` refusing the dev disks) a host run shows the refusal or the right split.
- [ ] `vm-devices-check.sh` records are parsed by key, with a canned-output test: reversed key order gives the same result.
- [ ] Outcome `Verified: host (vm pending: the seven scripts above)`; the lead's VM run result is added to the Outcome by the lead.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```
VM (lead): the listed scripts on the next image.

## Docs to update
- `docs/dev-setup.md` (check list, if a command changes).

## Hints
- Backslash paths (`vm-iso-check.ps1`) are written with Write/Edit only.
- Overlaps T-290, T-292, T-287, T-293 (they extend other `vm-*` scripts: `vm-session-check.sh`, `vm-usage-check.sh`, `vm-display-check.sh`, `vm-power-saving-check.sh` for audio): coordinate on `vm-power-saving-check.sh`, run after T-293.

## Outcome
Verified: host (vm pending: vm-storage-check.sh, vm-iso-check.ps1, vm-sample-check.sh, vm-devices-check.sh, vm-sounds-check.sh, vm-power-saving-check.sh, vm-boot-check.sh)

**What ran where.** `bash -n` on all 17 `vm-*.sh` and the PowerShell parser on every `vm-*.ps1`; the new host tests `scripts/test-vm-checks.sh` (30 assertions) and the ISO refusals through `scripts/lint-vm-checks.ps1`, now a step of `dev.ps1 test` and of the CI lint job (`VM check lint`). No shellcheck on this machine (reviewed by eye). Nothing ran in a VM.

**The line that makes the check fail on a broken service**
1. `vm-storage-check.sh`: `polkit_expect` (line 55) passes a `deny` only for `pkcheck` exit 1; exit 0 is "polkit allows", every other code (2 asks for a password, 126/127/crash) is a FAIL. `list_ok` (line 75) is asserted before `gone` (149), `eject` (224) and `meject` (309) say a volume left the list; their wait loops also wait for a successful call. (`gone` already failed on an error reply by accident, because `"" != 0`; `eject` and `meject` printed PASS.)
2. `vm-iso-check.ps1`: `Resolve-ScratchDisk` (line 37) throws for `output\qcow2\disk.qcow2` and `work.qcow2` (relative, absolute, other case, `..` forms), before any file is touched. Host run: all five spellings refused; `output\iso-test.qcow2` and `output\qcow2\drill.qcow2` reach the tool check.
3. `vm-sample-check.sh`: `finish` (trap on EXIT, line 90) stops the signal monitor, deletes a profile the check created, removes app, override, remote and the work directory on every exit, including the early `exit 1`s; the normal end calls it too (idempotent). The grace check is `-le 6` (line 147: whole-second clock plus a 1 s poll). Host test: with `systemctl` failing, the exit is 1 and the `flatpak override --reset / uninstall / remote-delete` calls happen.
4. `vm-devices-check.sh`: the SaveReport volume comes from `pick_removable_volume` (line 501, python3 on `busctl --json=short`), each volume read by its keys; the split at `"drive"` is gone. A bad JSON reply is a FAIL, "no eligible volume" the existing SKIP. Canned-output test: key order sorted, reversed and shuffled give the same id and mount point; read-only, unmounted and internal volumes are not picked. The `storage` retry and the `thermal-fake` exponent parser were already in the script and are unchanged (host-checked only until the VM run).
5. `vm-sounds-check.sh`: new case (lines 52-60): a theme whose `sub` folder is a link to a folder outside it, manifest `sub/select.wav`, must be refused by `--check-sound-theme`; right before it a control with a real `sub` folder must be accepted, so the refusal is the link's. The playback probe runs with `XDG_RUNTIME_DIR=/run/user/<uid of ruya-shell>` (line 79). Host observation: the control layout is accepted by `ruya-shell.exe --check-sound-theme`; with a Windows directory junction in place of `sub` the checker also **accepted** it (Qt's `canonicalFilePath` on Windows does not resolve a junction as Linux does). On Linux `resolve()` compares the real path with the theme root and should refuse; the VM run decides (Inbox: if it accepts, `resolve()` must reject any link in the path).
6. `vm-power-saving-check.sh`: `timeline` now ends with `wake_check` (line 91): a uinput key (`vm-inject-key.py home`, must be copied next to the script) wakes the display; FAIL without a `display on` line, with no active CRTC in `/sys/kernel/debug/dri/*/state`, with `dpms` not `On`, with a pageflip/commit error in the journal since the start, and (line 130) with **no delivered vblank event (`drm_vblank_event_delivered` in tracefs) in the 4 s after the key**. Without tracefs or debugfs it prints `UNVERIFIED:` instead of passing. The old "now send a key from the host" step is gone. Not host-testable.
7. `vm-boot-check.sh`: the comment says the unit's own `/boot` remount happens in its private mount namespace and cannot be seen; the check is the observable result: `/boot` is its own mount (lines 38-39: otherwise the read-only root would make "ro" true for the wrong reason), is mounted `ro`, and creating a file fails with `Read-only file system` (line 45).

**Revert checks** (copy of `scripts/`, one change undone, `test-vm-checks.sh` run): `[ "$rc" = 1 ]` back to `!= 0` -> two assertions failed (exit 2, exit 127); `list_ok` branch removed in `gone` -> the busctl-error assertion failed; in `eject` -> two failed; in `meject` -> two failed; `trap finish EXIT` removed -> three failed (override, uninstall, remote); the `read_only` condition removed from the picker -> three failed; the ISO refusal compare replaced by `$false` -> five findings in `lint-vm-checks.ps1`.

**Files.** `scripts/vm-storage-check.sh`, `vm-iso-check.ps1`, `vm-sample-check.sh`, `vm-devices-check.sh`, `vm-sounds-check.sh`, `vm-power-saving-check.sh`, `vm-boot-check.sh`; new `scripts/test-vm-checks.sh` (exec bit set), `scripts/lint-vm-checks.ps1`; `scripts/dev.ps1` (`Test-VmChecks` in `test`), `.github/workflows/ci.yml`, `docs/dev-setup.md`.

**Deviations.** `vm-storage-check.sh` and `vm-devices-check.sh` got a `VM_CHECK_LIB_ONLY=1` early return before their `case`, so the tests can source their helpers; the lint is a new step in `dev.ps1 test` and CI (the criteria ask for the checks to run on the host). Not tested on the host: items 5 (needs the shell binary and real symlinks), 6 and 7 (need a guest).

**Pending for the lead's VM run:** all seven scripts; `vm-power-saving-check.sh` needs `vm-inject-key.py` copied with it and shows whether the VM kernel has tracefs with the `drm` events (virtio-gpu may deliver page flips without hardware vblank; if `UNVERIFIED:` appears, say so here); the sounds directory-link case decides the checker question above.
