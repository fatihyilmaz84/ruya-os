# T-193 — VM scripts: no false passes, no leftovers

Status: todo · Phase: 0 · Depends: — · Area: scripts · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
