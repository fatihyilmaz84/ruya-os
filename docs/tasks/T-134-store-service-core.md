# T-134 — `ruya-store` service: catalogue and job core over the `flatpak` CLI, in the VM

Status: done · Phase: 3 · Depends: T-110 · Area: services, image · Size: M

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
Verified: vm (image `0.0.17-t134`, `RUYA_BOOT_OK`), 2026-10-28. Built by a Sonnet builder session; it stopped before documenting, so the lead ran the final VM check and wrote this Outcome.

- **Built:** crate `services/ruya-store`: `app.rs` (app record, search, validation of ids, remote names and commits), `appstream.rs` (pure-Rust AppStream reader), `flatpak.rs` (the `Flatpak` trait, `FakeFlatpak`, parsers of `flatpak` output, error classification), `queue.rs` (one transaction at a time, `busy` for a duplicate), `service.rs` (the rules: catalogue, jobs, progress that never decreases, statuses, `AddRemote` admin-only and signed-only), `flatpak_cli.rs` (Linux: the `flatpak --system --noninteractive` command; app data removed as each home's owner), `dbus.rs` (thin zbus adapter, jobs on a thread, events forwarded as signals; a job starts 100 ms after its reply, so a client can map the job id first). New dependencies: `quick-xml` and `flate2` (AppStream, pure Rust); `async-io`, `blocking`, `async-channel` are already in the tree through zbus. Spec 03 §4.3 has the as-built detail.
- **Contract change** (`Store1.xml`, comments only, no signature change): permissions are read by `GetApp` on first use, and `InstalledChanged` is also sent once the catalogue was first read and after `AddRemote`. Mock and client agree (the client reads both lists again on `InstalledChanged`).
- **Image:** `ruya-store.service` (system, root, `Type=dbus`, hardened; `UMask=0022` because flatpak deploys world-readable files; exposure **3.3 OK**), D-Bus policy (root owns, root and `ruya-shell` call), enabled in the `Containerfile`. `flatpak` is already in the image.
- **Shell:** `Store::create` defaults to D-Bus on Linux, the mock elsewhere (like Audio and Profiles).
- **VM** (`vm-store-check.sh check`, all PASS): unit active; a signed test repository built in the guest; `AddRemote` by `ruya-shell` without an admin profile is `forbidden`, by root `ok`, an unsigned repository `invalid`; `Search` lists the test app and filters; `GetApp` of an unknown id is `unknown-app`; `Install` queues `job-1`, a second `Install` is `busy`, `JobProgress` 0 → 100, `InstalledChanged` before `JobFinished` `ok`, `ListInstalled` and `flatpak list` agree, `already-installed` and `no-update`; `Uninstall(delete_data)` removes the app and the profile's data (a planted symlink's target and another app's data untouched), then `not-installed`; an option as id and a bad commit are `invalid`; `nobody` is refused. **Shell over the real bus** (first runtime check of `DBusStoreBackend`, `vm-store-probe.qml`): `mock=false available=true`, catalogue with the test app, installed 0 → 1 → 0 following the jobs.
- **Found in the VM:** the image ships Fedora's own Flatpak remote (`fedora`, `oci+https://registry.fedoraproject.org`, from Fedora's flatpak package), so the catalogue has 524 apps, all `developer` source and without names (no AppStream for an OCI remote). Not in spec 03 §4.2's source list: Inbox.
- **Job-signal race** (LEAD-NOTES concern 3): mitigated by the 100 ms start delay, not by the client buffering unknown-job signals. No dropped signal in the VM run.
- `dev.ps1 test` ALL GREEN (164 QML passed, 13 skipped offscreen; 117 Rust). Unverified: real Flathub downloads and progress between 0 and 100 (`flatpak` prints no percentages without a terminal).
