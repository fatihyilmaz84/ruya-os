# T-151 — `ruya-update`: the `Update1` service over `bootc`

Status: done · Phase: 2 · Depends: T-135 · Area: services, image · Size: M

## Goal
Settings → System → Updates works for real: in the VM, "Check for updates" finds a newer image in the dev registry, the download stages it, and after "Restart to finish" the VM boots the new version; an admin can roll back. Until now only the shell's mock followed `Update1`.

## Read first
- `docs/specs/01-platform.md` §4 (updates, rollback, channels); `docs/specs/00-overview.md` ADR-006
- `api/dbus/org.ruyaos.Update1.xml` (**the contract**, including the lead's admin decision in its header) and `api/dbus/org.ruyaos.Store1.xml`
- `services/CLAUDE.md`; `services/ruya-store/` (**the pattern**: pure core in `service.rs` behind a trait for the external tool, a fake for tests, `dbus.rs` adapter, job thread with events, `caller_is_admin`)
- `shell/src/update/` (mock rules the service must match; `DBusUpdateBackend` is unverified until this task)
- `docs/dev-setup.md` "Update / rollback drill" (local registry, WSL IP, insecure registry config) and "Store check" (how `vm-store-check.sh` is run)
- The `ruya-store` unit and bus policy under `image/rootfs/` (copy their hardening)

## Scope
1. **Service** `services/ruya-update` (Rust, system bus, `/org/ruyaos/Update1`), following `ruya-store`'s layout. A `Bootc` trait over the commands (`bootc status --json`, `bootc upgrade --check`, `bootc upgrade`, `bootc rollback`, `bootc switch`), a fake for tests, a pure state machine for the status record and its rules (the same `busy`/`unavailable`/`invalid` rules as the mock). Long commands run off the D-Bus thread; `StatusChanged` on every change. Progress: whatever `bootc` reports; if it reports none, `0` then `100` is acceptable (say so in the Outcome).
2. **Versions and channel** come from `bootc status --json` (the booted, staged and rollback images; the version from the image's version label, else the tag). The channel is the image tag (`stable`, `beta`): `SetChannel(c)` remembers the tag to track (state under `/var/lib/ruya-update`) and clears `available`; the next `Check`/`Download` look at that tag (`bootc switch` stages it). Record the exact commands in the Outcome.
3. **Admin check (lead decision):** `Rollback` and `SetChannel` answer `forbidden` unless the caller is root or `ruya-shell` while the active profile is an admin, exactly like `ruya-store`'s `AddRemote`. Add `forbidden` to the XML status list, the shell mock (a test hook makes the active profile non-admin) and `DBusUpdateBackend`, in this commit.
4. **Image:** the binary, a hardened unit (no weaker than `ruya-store`'s; it needs to run `bootc`, so say which hardening options had to go and why), a restrictive bus policy (shell and root), the greenboot required check lists it.
5. **VM check script** `scripts/vm-update-check.sh` (run in the guest like `vm-store-check.sh`): status over the bus, `Check` against the dev registry finds the pushed newer tag, `Download` stages it (`staged` set, `bootc status` agrees), `Rollback` as a non-admin is `forbidden`.

## Out of scope
- Scheduled daily checks and the idle-time reboot (next task), the greenboot rollback event shown in the shell, signed images (cosign), chunked images.
- Reboot: the shell already uses `Power.restart()`.

## Acceptance criteria
- [ ] Rust unit tests with the fake `Bootc`: every status string, each state transition, `busy` while a check or download runs, `unavailable` rules, `forbidden` for a non-admin caller decision.
- [ ] `tst_update.qml` covers `forbidden` in the mock (the existing tests unchanged otherwise).
- [ ] VM: image from this commit and a second tag pushed to the dev registry; `vm-update-check.sh` passes; after a restart from Settings (VM screenshot of the Updates group showing "Restart to finish"), the VM boots the new version (`RUYA_BOOT_OK`, version row shows it).
- [ ] VM: `systemd-analyze security ruya-update` exposure recorded in the Outcome.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh twice (two tags), registry as in dev-setup "Update / rollback drill", make-disk.sh qcow2
.\scripts\smoke-test.ps1 -Keep    # then scripts/vm-update-check.sh in the guest
```

## Docs to update
- `docs/specs/01-platform.md` §4 (what is built), `docs/specs/03-services-and-apps.md` (service list), `docs/dev-setup.md` ("Update check" next to "Store check"), the XML header.

## Hints
- `bootc` needs root; the service runs as root like `ruya-store` does for system Flatpak operations, with the hardening that still allows it.
- Clean up the registry tags afterwards (dev-setup step 6): each pins about 4.7 GB in WSL.
- A fresh disk copy has new SSH host keys: use the batch SSH options in `docs/dev-setup.md`.

## Outcome
Verified: **vm** (images `0.0.20-t151` and `0.0.21-t151`, booted in QEMU, real bus; `vm-update-check.sh` ALL PASSED) and **host** (`dev.ps1 test` ALL GREEN, 210 QML, Rust incl. 25 new `ruya-update` tests).

**Built.** `services/ruya-update`: `bootc.rs` (a `Bootc` trait, `BootcCli` running `bootc status --json | upgrade --check | upgrade | switch | rollback`, a pure `parse_status`, `FakeBootc`), `service.rs` (the state machine: statuses, state transitions, rules, channel file), `dbus.rs` (thin zbus adapter, jobs on a thread, `StatusChanged` through a channel, admin check copied from `ruya-store`'s `AddRemote`), `main.rs` (`--session` runs over a fake host). Image: `ruya-update.service`, bus policy `org.ruyaos.Update1.conf`, Containerfile install and enable, greenboot required check `51-ruya-update.sh` (service active within 60 s). Contract: `forbidden` added to the XML (status list, header); the mock answers `forbidden` for `Rollback`/`SetChannel` after `Update.mockSetCallerIsAdmin(false)`; `DBusUpdateBackend` already passes any status through. `tst_update.qml` gained `test_forbidden_for_a_non_admin_caller`. `scripts/vm-update-check.sh`; `vm-goto.ps1` got a `settings-system` target.

**Commands.** `Check`: `bootc upgrade --check`, then `bootc status --json`; `available` is `booted.cachedUpdate` unless its digest equals the booted or staged one (version label, else tag). `Download`: `bootc upgrade`, or `bootc switch <repo>:<channel>` while the chosen channel differs from the tag the host tracks. `Rollback`: `bootc rollback`; the previous image then shows as `staged` and `rollback_available` is false (`rollbackQueued`). `SetChannel`: writes `stable|beta` to `/var/lib/ruya-update/channel` (atomic; a corrupt file stops the service) and clears `available`. Without a chosen channel the host's tag is followed (a dev tag just upgrades).

**Deviations / decisions.**
- **Progress** is `0` while `bootc` works, then `100` (nothing of its output is parsed; the Download took about a minute in the VM).
- A check for a *different* channel cannot ask the registry (`bootc` cannot look at another tag without staging it): `available` is then the channel name (not a version) and the version shows once staged. Not VM-tested (needs a `beta` tag); unit-tested with the fake.
- `Rollback` without a prior `Check` works in any state but `checking`/`downloading` (`busy`). Root's `Rollback` verified in the VM (`ok`, then `unavailable`, `staged` = previous version); the admin-profile path through `Profiles1` is the same code as `ruya-store` and is unit-tested only as the `admin` boolean.
- `ruya-update` repeats `caller_is_admin`/`active_profile_is_admin` from `ruya-store` (Inbox: share them).

**Hardening** (`systemd-analyze security ruya-update`: **4.8 OK** in the VM; `ruya-store` is 3.3, `ruya-profiles` 1.6). Options that had to go, found by bisecting `bootc upgrade --check` under `systemd-run`: no `ProtectSystem=` (bootc remounts `/sysroot` and writes `/boot`, `/etc`, `/var`) and so `CAP_SYS_ADMIN`; `CAP_SYS_PTRACE` (bootc reads `/proc/1/ns/mnt`, even for `status`; without it "Permission denied"); **no `RestrictSUIDSGID`** (with it bootc fails with ENOSYS "Opening runtime auth file", and an ostree checkout must create setuid files); no `PrivateDevices`/`PrivateNetwork`. Kept: `NoNewPrivileges`, `PrivateTmp`, `PrivateIPC`, a bounded capability set, `SystemCallFilter=@system-service @mount`, `ProtectProc=invisible` (ineffective while `CAP_SYS_PTRACE` is held: kept, with a comment in the unit), `ProtectKernel*`, `ProtectClock`, `ProtectHostname`, `ProtectControlGroups`, `RestrictAddressFamilies`, `RestrictRealtime`, `LockPersonality`.

**VM run.** Image A pushed as `<wsl-ip>:5000/ruyaos:stable`, disk made, VM `bootc switch`ed to that tag and rebooted; image B (version `0.0.21-t151`, with the unit fixes) pushed over the same tag. `vm-update-check.sh`: active, current `0.0.20-t151`, `Check` finds `0.0.21-t151` (second `Check`: busy), `Download` stages it (`bootc status` has a staged deployment), `Rollback` and `SetChannel` by `ruya-shell` without an admin profile: `forbidden`, `nobody` refused by the bus policy, `SetChannel nightly`: `invalid`. That run used a drop-in repeating the two unit fixes on image A (A's unit predates them); after the reboot into B (below) the unmodified unit answered `Check` (`up-to-date`). Screenshot `output/vm-shots/settings-system.png`: Updates group with the real service: "Version 0.0.20-t151 · Stable", "Restart to finish: Version 0.0.21-t151 is ready"; Accept, then Confirm, rebooted the VM: `RUYA_BOOT_OK 0.0.21-t151`, Version row shows it. Greenboot passed on B (required check lists `51-ruya-update.sh`). Registry container and tags removed afterwards. A first `make-disk.sh` failed once with "Cannot allocate memory" writing to `/mnt/d`; `drop_caches` and a retry worked (WSL RAM, not the code).

**Follow-ups (Inbox).** Scheduled daily check and idle-time reboot (planned next); share the admin-caller code between services; the Settings pane says only "The update could not be started." for `forbidden` (needs a string + Turkish).

**Lead review 2026-11-01:** found a rollback/check race, a `bootc switch` to a tagless reference when the tracked image is unknown, and that a bad channel file stops the service (with the required greenboot check, every boot fails, also after a rollback); also `ProtectProc=invisible` is ineffective while `CAP_SYS_PTRACE` is held. All in T-153.
