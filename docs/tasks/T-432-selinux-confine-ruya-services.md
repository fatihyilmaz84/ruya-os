# T-432 - SELinux: confine the ruya services (today every one runs unconfined_service_t)

Status: todo · Phase: 2 · Depends: T-431 · Area: image (SELinux policy module), services (unit files) · Size: M · Owner: builder · Complexity: hard · Developer surface: none

## Goal
"SELinux enforcing" (01 §3) protects our own services: each ruya-* service runs in its own domain that allows what it does and nothing else. T-424 measured on 0.0.61 that inputd, library, profiles, session, shell, store and update all run as `unconfined_service_t`.

## Read first
- `docs/tasks/T-424-vm-security-posture-check.md` (Outcome), `image/security-baseline.json` (the `selinux` section), `docs/specs/01-platform.md` §3, `docs/specs/03-services.md` (what each service touches), `image/CLAUDE.md`
- Fedora's `selinux-policy-devel` and how a bootc image ships a module (`semodule -i` at build time)

## Scope
1. A spike first (written into the Outcome): one policy module per service or one module with a domain each; build-time install in the Containerfile; how to develop it (permissive per domain, `audit2allow` on the VM, then enforcing).
2. Domains for at least `ruya-profiles` (holds PIN hashes) and `ruya-update` (root, writes the deployment) enforcing, with their file contexts; the others permissive-per-domain if time runs out, each named in the Outcome.
3. `vm-security-check.sh`: the baseline lists the expected domain per process and fails on `unconfined_service_t` for a confined service (fixture).

## Out of scope
- Confining Flatpak apps (Flatpak's own sandbox) and the compositor's GPU paths beyond what works.

## Acceptance criteria
- [ ] VM (this task): build, `make-disk`, `smoke-test.ps1` to `RUYA_BOOT_OK`; the `vm-queue.ps1` default checks PASS with the new domains enforcing; `ausearch -m avc` after the queue shows no denials for the confined domains (numbers in the Outcome).
- [ ] `vm-security-check.sh check` PASS with the per-process domains; its fixture refuses an unconfined one.
- [ ] `dev.ps1 test` ALL GREEN; `free-space.ps1` after.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/01-platform.md` §3 (which services are confined, how to add a domain); `image/CLAUDE.md` (one line: a new service needs its domain).

## Hints
- From the STATUS Inbox (T-424), planned by lead-9 on 2026-11-10. Dispatch to Opus (Complexity hard). Trust-boundary task: an abuse test per domain (a denied write, logged as an AVC).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
