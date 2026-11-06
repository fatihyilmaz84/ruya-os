# T-162 — `ruya-session` in the image: real spawner, unit, bus policy

Status: done · Phase: 2 · Depends: T-130, T-139 · Area: services, image · Size: M · Owner: lead

## Goal
`Session1.Launch` over the real system bus starts an app in the profile user's systemd user manager, and `AppStarted`/`AppExited` report it correctly. This is the first half of "launch an app from the shell" (the Wayland half is T-164).

## Read first
- `docs/specs/00-overview.md` ADR-004, ADR-010; `03-services-and-apps.md` §4.1 (launch, `ruya-session`); `01-platform.md` §2
- `api/dbus/org.ruyaos.Session1.xml`; `services/ruya-session/src/*` (T-139 Outcome: what is built and what is not)
- `services/CLAUDE.md`, `image/CLAUDE.md`; a hardened system service to copy: `ruya-store` (unit, bus policy, `caller_is_admin` not needed here)

## Scope
1. **Real spawner** (`spawner.rs`, Linux): run `spawner::launch_command` (`systemd-run --user --machine=ruya-<id>@.host --unit=… -- flatpak run <id>`), follow the unit (`PropertiesChanged` on the user manager's unit, or `systemd-run --wait`'s exit) into `UnitEvent`s: running, exited with code, or killed by a signal (`ExecMainCode`/`ExecMainStatus`). Stop and kill go to the same unit.
2. **Profile user manager:** make sure `user@<uid>.service` of the profile runs before a launch (start it, or linger set by `ruya-profiles` at creation; decide in the VM and record why). Profile users run no PipeWire against hardware (ADR-010: their user units are masked); check that holds.
3. **`ProfileDirectory` from `Profiles1.ListProfiles`** over the system bus, fetched before each Launch (T-139 design); test the mapping in the core.
4. **Packaging:** Containerfile installs `ruya-session`; a system unit with the usual hardening (it needs to reach other users' managers: find the minimum, likely root with a narrow `CapabilityBoundingSet`, `ProtectHome=read-only`); bus policy: only root owns `org.ruyaos.Session1`, only `ruya-shell` and root call it.
5. **VM check** `scripts/vm-session-check.sh` (copy `vm-store-check.sh`): over `busctl` as `ruya-shell`, Launch a command-line Flatpak (or a test app id the check installs from Flathub; say which) for profile `p1`: `AppStarted`, `ListRunning` shows it as `running`, the unit runs as `ruya-p1`; Stop gives `AppExited … quit`; an app that exits non-zero gives `crashed`; an unknown profile gives `unknown-profile`; a non-`ruya-shell` caller is refused by the policy.
6. Spec 03 §4.1 says what is real now; the shell's D-Bus client (T-138) is checked against the real service in the same VM run (the shell's `Session.running` follows a Launch from `busctl`, read from the journal or a probe).

## Out of scope
- Wayland sockets for profile users (T-164), freezing apps on profile switch (T-165), the full-screen app flow (T-147), PipeWire for profile apps (B-007).

## Acceptance criteria
- [ ] Rust tests for the event mapping (exit code, signal, never-started) and the ProfileDirectory fetch parsing; `dev.ps1 test` ALL GREEN.
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; `vm-session-check.sh` ALL PASSED (each item of Scope 5 is a check); the D-Bus policy refusal is one of them.
- [ ] `systemctl show ruya-session` hardening recorded in the Outcome (`systemd-analyze security` exposure).

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md`, `scripts\smoke-test.ps1`, `vm-session-check.sh` over SSH.

## Docs to update
- `03-services-and-apps.md` §4.1, `01-platform.md` (services list), `docs/dev-setup.md` (the new check), the Session1 XML header if behaviour changed.

## Hints
- `systemd-run --machine=user@.host` needs the caller to reach that user's bus through `systemd-machined`'s `.host` container: try it as root first in the VM before writing the unit.
- Flathub needs network in the VM; `vm-store-check.sh` already installs from it.

## Outcome
Verified: vm (image `0.0.44-t162`: `RUYA_BOOT_OK`; `vm-session-check.sh` ALL CHECKS PASSED on the fresh disk, 45 checks incl. the profile deletion; `vm-devices-check.sh` 57 PASS with `-Audio`, unchanged by the PipeWire drop-ins; `vm-iso-check.ps1` on the installer ISO built from it: ISO CHECK PASSED, install 951 s, boots to the shell, greenboot success). `dev.ps1 test` ALL GREEN (381 QML + 30 skips; 36 session tests, 67 + 70 in other crates). `systemd-analyze security ruya-session`: **1.1 OK** (`ruya-profiles` 1.6).

Built (lead, no builder): the real spawner `systemd.rs` (Linux), `spawner.rs` (pure: `launch_command`, `parse_run_line`, `RunFollower`, `LineTail`, `scope_pattern`, `flatpak_app_installed`), `directory::profile_ids`, system mode in `main.rs`, unit `ruya-session.service` (root, **empty** `CapabilityBoundingSet`, `PrivateNetwork`, `AF_UNIX`, `ProtectHome=yes`, `RuntimeDirectory=ruya-session`), bus policy, Containerfile, `scripts/vm-session-check.sh` + `vm-session-probe.qml`, `ruya-profiles` deletes a lingering profile's manager before `userdel`, PipeWire/WirePlumber user units limited to `ruya-shell`. Specs: 03 §4.1, 01, 00 (ADR-010), `dev-setup.md`, Session1 XML header, `image/CLAUDE.md`.

What the VM taught (all in 03 §4.1; each cost an iteration):
- **Stderr must not be a pipe of the service.** `systemd-run --machine=` passes its stderr to PID 1; SELinux refuses PID 1 a pipe made by a service (or a file in `/root`): "Connection reset by peer". The spawner gives it a file in the runtime directory and tails it.
- **The app is not in our unit.** `flatpak run` moves itself into `app-flatpak-<id>-<n>.scope`; stopping the unit left the app running (a first check "passed" `Stop` while the process lived). Stop and kill now address the scope too; the check asserts the process is gone.
- **Linger, then wait for the manager.** Without linger the manager and the app die ~10 s after the call's session closes. `enable-linger` followed at once by a `--machine=` call hangs the start for 45 s, so the spawner runs `systemctl start user@<uid>` in between.
- **PipeWire for profile users was not masked** (ADR-010 said so, the image did not): drop-ins with `ConditionUser=ruya-shell`.
- The Containerfile edit first missed the `install` line (unit failed 203/EXEC in the first image); caught by the check, not by `lint`.

Deviations: Scope 5 "an app that exits non-zero gives crashed" and "Stop gives quit" are checks; the kill after the 5 s grace is **not** VM-tested (a Flatpak sandbox dies at the scope's SIGTERM, so no test app can ignore it; the core's tests cover it) and replaced by "SIGKILL from outside gives killed". No `WAYLAND_DISPLAY` is passed yet (T-164). Test apps come from a local unsigned repository built in the guest (no download).

Follow-ups (Inbox): the registry is empty after a restart of `ruya-session` while apps keep running (adopt `ruya-app-*` units on start); a missing binary in an app (exec 203) shows as `crashed`, not `launch-failed`; `ruya-profiles` deletion should be covered by its own VM check besides this one.
