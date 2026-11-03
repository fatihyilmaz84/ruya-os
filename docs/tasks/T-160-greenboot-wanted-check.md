# T-160 — Greenboot: no failing wanted check on a healthy boot

Status: in-progress · Phase: 0 · Depends: — · Area: image · Size: S · Owner: builder

## Goal
A healthy boot logs no failing greenboot check. Today the wanted script `01_update_platforms_check.sh` fails on every VM boot; it is harmless ("wanted"), but it hides real failures in the journal and will confuse the first hardware install (B-002).

## Read first
- `docs/specs/01-platform.md` §4 (greenboot, required checks)
- `image/CLAUDE.md`, `image/Containerfile` (the greenboot lines), `image/rootfs/usr/lib/greenboot/`
- `docs/dev-setup.md` (image recipe, `vm-reboot-check.ps1`)
- T-153 Outcome (where the failure was seen)

## Scope
1. In the VM, find which package ships the script and what it checks (`rpm -qf`, read the script, `journalctl -u greenboot-healthcheck`). Write the answer in the Outcome.
2. If the check does not apply to a bootc console (for example it tests rpm-ostree/ostree remotes that RuyaOS does not use), disable it the way greenboot supports (its config file's disabled-checks list if the installed greenboot has one, otherwise remove the script in the Containerfile with a comment). If it does apply, make it pass instead.
3. Our own required checks stay untouched.

## Out of scope
- Shortening greenboot timeouts (B-002 decides that on hardware), new health checks.

## Acceptance criteria
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; `journalctl -b -u greenboot-healthcheck` shows no failing script and "health-check passed" (record the lines in the Outcome).
- [ ] `scripts/vm-update-check.sh` ALL PASSED (the update and rollback drill still works).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then `scripts/build.sh`, `make-disk.sh qcow2`, `scripts\smoke-test.ps1`, and the journal check over SSH (`docs/dev-setup.md`).

## Docs to update
- `docs/specs/01-platform.md` §4 (one sentence on which stock checks run).

## Hints
- Small enough to pair with another image task in one session (one image build covers both); say so in both Outcomes.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
