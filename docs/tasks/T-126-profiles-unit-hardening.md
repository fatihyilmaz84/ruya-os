# T-126 — Harden `ruya-profiles.service` (capabilities, syscall filter, umask)

Status: done · Phase: 2 · Depends: — · Area: image, scripts · Size: S · Owner: lead

## Goal
`ruya-profiles` runs as root because it creates Unix users with `useradd`. `systemd-analyze security` rated it **6.0 MEDIUM** in the VM (T-120): all capabilities, no syscall filter, default umask, `/proc` fully visible. Cut it down to what `useradd` and the store need, without breaking profile creation.

## Read first
- Root `CLAUDE.md` security invariants ("Services keep their systemd hardening")
- `image/rootfs/usr/lib/systemd/system/ruya-profiles.service`
- `services/ruya-profiles/src/accounts.rs` (`useradd` call), `src/store.rs` (file modes)
- `scripts/vm-profiles-check.sh`, T-120 Outcome

## Scope
1. Add to the unit: a `CapabilityBoundingSet` limited to what `useradd --create-home` needs, `SystemCallFilter=@system-service` (with `SystemCallErrorNumber=EPERM`), `UMask=0077`, `ProtectProc=invisible`, `ProcSubset=pid`, `PrivateDevices`, `ProtectClock`, `ProtectHostname`, `ProtectKernelLogs`, `RestrictRealtime`, `RestrictSUIDSGID`, and anything else that does not break it.
2. `vm-profiles-check.sh create`: creates a first admin and a standard profile over the bus as root (no UI driving), so the check is one command.
3. VM verification on a fresh disk.

## Out of scope
- Running the service as a non-root user (would need a privileged helper for `useradd`; a later design question).
- Code changes to the service.

## Acceptance criteria
- [ ] In the VM, `vm-profiles-check.sh create` makes both profiles: `ok` replies, Unix users `ruya-p1`/`ruya-p2`, homes in `/var/home`, `profiles.toml` 0600 (output in the Outcome).
- [ ] `/etc/passwd` and `/etc/group` stay 0644 and `/etc/shadow` stays 0000 after a creation (umask must not leak into them).
- [ ] `systemd-analyze security ruya-profiles` is lower than 6.0 (before/after numbers in the Outcome).
- [ ] The image boots with `RUYA_BOOT_OK`.

## Verification
```powershell
.\scripts\dev.ps1 test
```
WSL build, `make-disk.sh qcow2`, `smoke-test.ps1 -Keep`, then `vm-profiles-check.sh create` and `security` over SSH.

## Docs to update
- `docs/specs/03-services-and-apps.md` §1 if it describes the unit's sandbox.

## Outcome
Done by the lead on 2026-10-23.

**Built.**
- `image/rootfs/usr/lib/systemd/system/ruya-profiles.service`: `CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_FOWNER CAP_FSETID`, `SystemCallFilter=@system-service` + `SystemCallErrorNumber=EPERM`, `UMask=0077`, `ProtectProc=invisible`, `ProcSubset=pid`, `PrivateDevices`, `PrivateIPC`, `ProtectClock`, `ProtectHostname`, `ProtectKernelLogs`, `RestrictRealtime`, `RestrictSUIDSGID`. Existing settings kept.
- `scripts/vm-profiles-check.sh create`: first admin and a standard profile over the bus as root, then `state` and the modes of `/etc/passwd`, `group`, `shadow`, `gshadow`.

**Verified (vm).**
- Before, image `0.0.6-lead1` (HEAD `c06c77a`): `RUYA_BOOT_OK`; `create` works; exposure **6.0 MEDIUM**.
- Iterated as a drop-in in that VM, then baked in. Image `0.0.6-lead2` on a fresh disk: lint clean, `RUYA_BOOT_OK`, no failed units; `create` → `"ok" "p1"` and `"ok" "p2"`, users `ruya-p1`/`ruya-p2` with homes 0700 in `/var/home`, skel files 0644 with `user_home_t` labels (`restorecon -n` changes nothing, SELinux enforcing), `profiles.toml` 0600, `/etc/passwd` and `/etc/group` 644, `/etc/shadow` and `/etc/gshadow` 0; exposure **1.6 OK**.
- `dev.ps1 test` ALL GREEN.

**Deviations / notes.** `useradd` logs `Creating mailbox file: Read-only file system`, before and after this change (`/var/spool/mail` is outside `ReadWritePaths`); harmless, profile users get no mail. Not checked: `userdel` (no caller yet; T-118 adds one and its VM criterion says to add a capability if needed). Unverified: sign-in through the shell UI on this image (the unit change does not touch `SwitchTo`; T-120's key-driven flow was not repeated).
