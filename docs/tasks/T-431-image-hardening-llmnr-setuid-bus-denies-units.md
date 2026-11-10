# T-431 - Image hardening from the baseline: LLMNR off, no setuid helpers, explicit bus denies, three loose units

Status: todo · Phase: 2 · Depends: — · Area: image, scripts · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
The first measured security baseline (T-424, 0.0.61) gets tighter where nothing needs the looseness: no LLMNR listener, no setuid sudo/pkexec helpers, bus policies that deny by default in writing, and the three barely hardened units hardened.

## Read first
- `docs/tasks/T-424-vm-security-posture-check.md` (Outcome: the numbers and the "should not ship" list), `image/security-baseline.json`, `scripts/vm-security-check.sh`, `scripts/lint-bus-policies.ps1` (T-423)
- `image/CLAUDE.md`, root `CLAUDE.md` Security invariants, `docs/specs/01-platform.md` §3, the units `ruya-boot-marker`, `ruya-compositor@`, `ruya-flathub-remote`

## Scope
1. systemd-resolved: LLMNR off (a `resolved.conf.d` drop-in); tcp/udp 5355 gone from the baseline.
2. sudo, pkexec and pam_timestamp_check: remove the packages if nothing in the image needs them (check `rpm -q --whatrequires`), else drop the setuid bit in the Containerfile; remove them from the baseline. If something needs one, keep it and say why in its reason.
3. The six bus policy files: explicit default-context `deny own` and send rules; then make `lint-bus-policies.ps1` require them (its rule 1), with a fixture.
4. Harden `ruya-boot-marker`, `ruya-compositor@` and `ruya-flathub-remote` (`ProtectSystem`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, capability bounding, `RestrictAddressFamilies`, `SystemCallFilter` where they still work) and lower their `max_exposure` in the baseline to the measured value, each with a reason.
5. `vm-security-check.sh` compares ports as proto:scope:port (loopback vs any address), so a loopback listener that moves to every address fails (fixture in `test-vm-checks.sh`).

## Out of scope
- SELinux confinement of our services (T-432); the release profile without sshd (T-425).

## Acceptance criteria
- [ ] VM (this task): `scripts/build.sh` + `make-disk.sh` in WSL, `scripts\smoke-test.ps1` to `RUYA_BOOT_OK`, then `vm-security-check.sh check` PASS against the tightened baseline, and `vm-queue.ps1`'s default checks still PASS (the compositor still shows the shell; Flathub remote still added).
- [ ] The new lint rule and the port-scope rule each have a fixture they refuse (named in the Outcome).
- [ ] `dev.ps1 test` ALL GREEN; `scripts\free-space.ps1` after the VM checks.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/01-platform.md` §3 (what listens, setuid policy); `docs/dev-setup.md` if a check changed.

## Hints
- From the STATUS Inbox (T-423 review, T-424 and its review), planned by lead-9 on 2026-11-10. One image build at a time (lead coordinates).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
