# T-151 — `ruya-update`: the `Update1` service over `bootc`

Status: todo · Phase: 2 · Depends: T-135 · Area: services, image · Size: M

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
