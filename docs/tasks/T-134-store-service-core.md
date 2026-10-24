# T-134 — `ruya-store` service: catalogue and job core over the `flatpak` CLI, in the VM

Status: todo · Phase: 3 · Depends: T-110 · Area: services, image · Size: M

## Goal
`org.ruyaos.Store1` is served by a real `ruya-store` service in the image: the shell lists a catalogue read from a local Flatpak test repository, installs and uninstalls a small app from it, and shows progress, with no mock.

## Read first
- ADR-005 and ADR-011 in `docs/specs/00-overview.md`; `docs/specs/03-services-and-apps.md` §4
- `api/dbus/org.ruyaos.Store1.xml` (statuses and records are binding; extend it per the contract rule if a field is missing)
- `services/CLAUDE.md`; `services/ruya-profiles` and `services/ruya-devices` (pure core, thin D-Bus adapter, unit, policy)
- `shell/src/store/` (what the client calls)

## Scope
1. New crate `services/ruya-store`: pure core (catalogue model from AppStream data, search, job queue with one transaction at a time, status mapping, CLI output parsers) behind a trait for "run flatpak" that tests fake. D-Bus adapter implements the whole XML (`GetApp`, `Rollback`, `ListRemotes`, `AddRemote` included; `AddRemote` is admin-only and refuses unsigned remotes).
2. systemd unit with hardening (score recorded), D-Bus policy (shell and root only), enabled in the image, `flatpak` installed in the image.
3. A local test remote for the VM: `scripts/vm-store-check.sh` builds a tiny Flatpak (or uses a pre-built repo fixture, no Flathub runtime download), adds it as a remote, and drives the service over the bus.
4. `Store.create` default stays mock on Windows; on Linux the default becomes D-Bus, like the other services.

## Out of scope
- Store UI (T-111), permissions prompts (shell side), Flathub filtering, updates scheduling when idle.

## Acceptance criteria
- [ ] Unit tests with a fake `flatpak`: queue runs jobs one at a time, `busy` for a duplicate, progress never decreases, each error kind maps to its `JobFinished` status, search matches name/summary/id.
- [ ] VM: `RUYA_BOOT_OK`; `vm-store-check.sh`: catalogue lists the test app, `Install` then `ListInstalled` shows it, `JobProgress` reaches 100 and `JobFinished` is `ok`, `Uninstall` removes it, `AddRemote` by a non-admin is `forbidden`.
- [ ] Shell in the VM shows the same through `DBusStoreBackend` (first runtime check of that client), evidence in the Outcome.
- [ ] `dev.ps1 test` ALL GREEN; unit exposure score in the Outcome.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh, make-disk.sh qcow2; then scripts\smoke-test.ps1 and scripts/vm-store-check.sh
```

## Docs to update
- Spec 03 §4.3 (as built), `docs/dev-setup.md` (check script), STATUS (B-004 done).

## Hints
- Image work needs the WSL disk repaired first (STATUS Open owner decisions).

## Outcome
_Filled in by the implementer._
