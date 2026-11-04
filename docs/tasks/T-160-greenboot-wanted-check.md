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
Verified: vm (paired with T-163, same image 0.0.30-t163, booted `RUYA_BOOT_OK 0.0.30-t163`). Host: `dev.ps1 test` ALL GREEN.

**Finding.** `01_update_platforms_check.sh` ships in `greenboot-default-health-checks-0.16.4` (`rpm -qf`). It is a wanted check that curls the URLs in `/etc/ostree/remotes.d`, the ostree remotes of rpm-ostree systems; a bootc console has none, so it failed every boot. It does not apply, so it is added to `DISABLED_HEALTHCHECKS` in `image/rootfs/etc/greenboot/greenboot.conf` (greenboot 0.16 supports this list; the repository DNS check was already there). Our own required checks and the stock `02_watchdog.sh` run unchanged.

**Journal** (`journalctl -b -u greenboot-healthcheck`):
- `Skipping disabled script: 01_repository_dns_check.sh`
- `required script .../02_watchdog.sh success!`, `50-ruya-shell.sh success!`, `51-ruya-update.sh success!`
- `Skipping disabled script: 01_update_platforms_check.sh`
- `greenboot health-check passed.` and no failing script.

**Update drill:** booted the image, `bootc switch` to a local registry tag, rebooted (health check passed again), built 0.0.31-t163 and pushed it as the same tag; `vm-update-check.sh check`: Check found 0.0.31-t163, Download staged it, `bootc status` has the staged deployment, rollback/SetChannel by the shell are forbidden, nobody refused, auto_restart cases pass. Two lines failed ("Check did not answer ok", "Download did not answer ok") only because the script's `call` helper stripped `s "x"` but Update1 returns `ss`; the calls had worked (the following steps passed). I fixed the helper (`sed -E` keeping the quoted status word of `s` and `ss` replies, checked on sample replies) but did not re-run the whole check afterwards: the guest was already holding a staged update. So: ALL PASSED is not literally shown; the pre-fix run had 2 format-only FAILs, the rest PASS.

Files: image/rootfs/etc/greenboot/greenboot.conf, docs/specs/01-platform.md (section 4), scripts/vm-update-check.sh.
