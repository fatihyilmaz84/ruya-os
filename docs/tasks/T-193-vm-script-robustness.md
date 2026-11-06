# T-193 — VM scripts: no false passes, no leftovers

Status: in-progress · Phase: 0 · Depends: — · Area: scripts · Size: S · Owner: builder

## Goal
The `scripts/vm-*` checks are only as good as their ability to fail. Reviews of T-178, T-180, T-183 and T-184 found places where a check could pass without testing anything, or leave state behind. Tighten them; the lead runs them in the VM later (nothing here needs an image).

## Read first
- `scripts/vm-devices-check.sh`, `vm-storage-check.sh`, `vm-storage-check.ps1`, `vm-library-check.sh`, `vm-iso-check.ps1`, `vm-update-check.sh` lines ~18-20 (the `busctl --json=short` + python3 pattern)
- Reviews' notes in the Outcomes of `T-180`, `T-183`, `T-178`, `T-184`

## Scope
1. **Registered polkit ids:** in `vm-devices-check.sh` and `vm-storage-check.sh`, before expecting `pkcheck` exit 1 for a "refused" action, check the id exists (`pkaction --action-id X` exits 0); a mistyped or removed id must be a FAIL, not a pass.
2. **JSON, not order:** parse `ListVolumes` in `vm-storage-check.sh` with `busctl --json=short` + python3, as `vm-update-check.sh` does, instead of splitting a line on the first key.
3. **Cleanup on failure:** `vm-library-check.sh` registers a `trap` (stop the signal monitor, remove the test repository and remote) so an early `exit 1` leaves nothing behind.
4. **`vm-iso-check.ps1`:** print the installed disk's boot entry titles (`/boot/loader/entries/*.conf`, `title` lines) into the check output; resolve an absolute `-Disk` correctly and refuse a path outside `output\` (the script deletes the target first).
5. `bash -n` on every `.sh` you touch; PowerShell syntax by running the script with `-?` or the parser check `[System.Management.Automation.Language.Parser]::ParseFile`.

## Out of scope
- Running the checks in a VM (lead), new checks, image changes.

## Acceptance criteria
- [ ] Each of 1-4 is visible in the diff and described in the Outcome with the failure it now catches (e.g. "an unknown action id prints FAIL").
- [ ] Where a piece can be exercised without a VM (the python3 `ListVolumes` parser on a sample JSON with shuffled keys; the `pkaction` loop with a fake `pkaction` on `PATH`; the path guard in `vm-iso-check.ps1`), the Outcome shows it run.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN. Outcome: `Verified: host (vm pending: vm-devices-check, vm-storage-check, vm-library-check, vm-iso-check)`.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md` if a script's usage changed.

## Hints
- Scripts stay LF with the exec bit; no Windows-mangled backslashes (write with Write/Edit).

## Outcome
Verified: host (vm pending: vm-devices-check, vm-storage-check, vm-library-check, vm-iso-check)

What each change catches now:
1. **Registered polkit ids.** `vm-devices-check.sh` (`polkit_expect <id> <pid> <want-exit> <text>`) and `vm-storage-check.sh` (`polkit_expect <id> <pid> allow|deny <text>`) run `pkaction --action-id X` first; an id polkit does not know prints `FAIL: polkit action X is not registered ...` instead of passing as "refused" (pkcheck also answers 1 for unknown ids). Both the "allowed" and the "refused" loops use it.
2. **JSON, not order.** `vm-storage-check.sh` reads `ListVolumes` through `busctl --system --json=short call` and python3 (`field_of LABEL KEY`, `volume_count`), so key order no longer matters; the `sed 's/"drive" s/\n&/g'` splitting and the unused `dict_of`/`dict_labelled` are gone. New in `baseline`: `ListVolumes answers parsable JSON (N volumes)` must PASS before "the stick is not there yet" means anything (a failed call or unparsable output used to read as "no stick").
3. **Cleanup on failure.** `vm-library-check.sh` has an `EXIT` trap (`on_exit`, plus `INT/TERM/HUP` -> `exit 1`): it stops the signal monitor and, once `need_clean=1` (set right before `build_repo`), runs `clean_all` (uninstall the test apps and runtime, delete the remote, `rm -rf $work`). `seed` keeps its apps when it succeeded and cleans up when `fail` is set. `clean` and the end of `check` call the same `clean_all`.
4. **`vm-iso-check.ps1`.** The probe prints `boot entry <file>: <title>` for every `/boot/loader/entries/*.conf` (or `boot entries: none in ...`), part of the state printed in the output. `-Disk` goes through `Resolve-ScratchDisk`: an absolute path is used as it is (it was glued to the repository root by `Join-Path` before), `..` is resolved, and anything not strictly inside `<repo>\output\` throws before any file is touched.
5. `bash -n` on the three `.sh`; `Parser::ParseFile` on the `.ps1`: no errors. Exec bits and LF unchanged.

Run on this host (helper scripts in the git-ignored `output\t193\`, not committed):
- `storage-test.sh`: the python3 parser against a sample with shuffled keys (label first, label in the middle, drive last): ids, bools, ints and strings read right; missing label or key give nothing; garbage and a failing `busctl` make `volume_count` fail. The polkit helpers of both scripts with a fake `pkaction`/`pkcheck` on `PATH`: a registered allowed/refused id PASSes; an unregistered id whose fake `pkcheck` answers 1 FAILs (the old loop passed it); a wrong verdict FAILs. 22 of 22 expectations held.
- `library-test.sh` (fake `flatpak`): an early `exit 1` with a running monitor stops the monitor, runs the uninstall/remote-delete and removes the work dir; a normal end cleans once; a successful `seed` leaves everything, a failed one cleans; `SIGTERM` cleans. Under Git Bash/MSYS the EXIT trap ran twice when a background job had been killed (reproduced with a 3-line script); `clean_all` is idempotent, so this is harmless and Linux bash runs it once.
- `guard-test.ps1`: the extracted `Resolve-ScratchDisk` accepts `output\iso-test.qcow2`, the same path absolute, `OUTPUT\sub\x.qcow2`, `output\..\output\ok.qcow2`; refuses `D:\elsewhere\...`, `C:\Windows\...`, `output\..\scripts\dev.ps1`, `output`, `output\`, `output2\...` and `disk.qcow2` (repo root). Running the real script with `-Disk C:\Windows\x.qcow2` exits 1 with the refusal before anything else. The new probe line was run under `sh` against a fake entries directory (two entries, then none).
- `.\scripts\dev.ps1 test`: ALL GREEN (382 QML passed, 30 skips, cargo test ok).

Not run (needs the VM, lead run): all four checks end to end. In particular the exact shape of `busctl --json=short call ... ListVolumes` is assumed to be `{"type":"aa{sv}","data":[[{key:{"type","data"}}, ...]]}` (the same shape `vm-update-check.sh` relies on for `a{sv}`); if it differs, `baseline` FAILs at the new "parsable JSON" check instead of passing silently. `/boot/loader/entries` on the installed ostree system is assumed to be reachable through its symlink.

Files: `scripts/vm-devices-check.sh`, `scripts/vm-storage-check.sh`, `scripts/vm-library-check.sh`, `scripts/vm-iso-check.ps1`, `docs/dev-setup.md`, this file. Deviations: none. The refused-action check in `vm-storage-check.sh` still accepts any non-zero `pkcheck` exit (as before); only registration was added.
