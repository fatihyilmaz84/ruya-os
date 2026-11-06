# T-238 — `ruya-play` service in the image: sandboxed unpack, signed Flatpak commit

Status: todo · Phase: 7 · Depends: T-229, T-234, T-237 · Area: services, image · Size: M · Owner: lead

## Goal
The importer runs on the console: the shell's Install from USB installs a `.play` as a system Flatpak app `play.<id>`, through an unprivileged, network-less unpack helper and a small root commit step, and the app shows in the library. Shape may change with T-229's answers; edit this file after the spike.

## Read first
- `docs/specs/05-play-packages.md` §7 (all), §9; ADR-014; T-229 Outcome, T-237 Outcome, `T-162` Outcome (unit hardening, SELinux findings), `image/CLAUDE.md`
- `api/dbus/org.ruyaos.Play1.xml` (T-234); `services/ruya-store` (root service, bus policy, unit exposure checks), `docs/image-packages.md`

## Scope
1. Binary adapter: D-Bus `org.ruyaos.Play1` on the system bus (zbus, as the other services), policy: only root owns the name, only `ruya-shell` and root call it.
2. **Unpack helper** as a transient systemd unit per job: `DynamicUser=yes`, `PrivateNetwork=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges`, `SystemCallFilter`, `MemoryMax`, `RuntimeMaxSec`, read access to the source via a passed file descriptor or a bind of the mount, write access to its staging directory only; the same binary, a `--unpack` mode. Target: exposure score as low as `ruya-store`'s or better; record the number.
3. **Commit** (root part, small): generate the Flatpak metadata from the manifest (permission mapping lives in T-240; use a conservative default until then), build the OSTree commit, sign it with the device-local key (generated on first use under `/var/lib/ruya-play/`, root 0600, never in the image), install into the system installation with signature checking on (`ruya-store`'s rule: no `--no-gpg-verify`), announce `InstalledChanged` (via `Store1` or Flatpak's change, whichever T-229 found works), `ListInstalled` shows the app.
4. Removable media mounted `nosuid,nodev,noexec` is a precondition: check, fail with a clear status if not. Nothing is opened before `Install`/`Inspect` is called by the shell.
5. Image: unit file, bus policy, tmpfiles for `/var/lib/ruya-play`, SELinux fixes found in the VM, `docs/image-packages.md` rows.
6. `scripts/vm-play-check.sh`: installs fixture packages built by `ruya-pack`, checks each outcome.

## Out of scope
- Runner resolution and launching (T-239), permission details (T-240), updates (T-241), runners (T-244).

## Acceptance criteria
- [ ] VM (this task): `scripts/build.sh` + `make-disk.sh`, then `scripts\smoke-test.ps1` -> `RUYA_BOOT_OK`, then `scripts/vm-play-check.sh` PASS for: install of the native sample (appears in `flatpak list --system`, `Library1` lists it, `Session1.Launch` starts it); tampered package refused with `bad-signature` and nothing left under `/var/lib/ruya-play/` staging or the Flatpak installation; wrong-key reinstall refused; unsigned refused without developer mode; zip bomb refused with bounded memory (`systemd-cgtop`/unit `MemoryMax` hit or limit error, service alive); the helper cannot reach the network (`unshare`-style probe from a test payload) or write outside staging; removing the stick mid-install fails cleanly.
- [ ] `systemd-analyze security` score for the helper and the service recorded in the Outcome and in `image/CLAUDE.md` if a quirk was found.
- [ ] Hostile fixtures of T-230/T-237 via D-Bus produce the same status codes as the core tests (`vm-play-check.sh`, JSON parsed, never key order).
- [ ] `dev.ps1 test` ALL GREEN; `free-space.ps1` run after the build.

## Verification
VM build and checks as above (background, one image build at a time).

## Docs to update
- Spec 05 §7 as built; spec 03 §4 (one paragraph linking), `docs/dev-setup.md` (the VM check), `docs/image-packages.md`.

## Outcome
_Filled in by the implementer._
