# T-296 — VM check script fixes: checks that pass for the wrong reason, early exits, missing cases

Status: in-progress · Phase: 2 · Depends: — · Area: scripts (vm-*-check) · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
