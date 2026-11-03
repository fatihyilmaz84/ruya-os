# T-162 — `ruya-session` in the image: real spawner, unit, bus policy

Status: todo · Phase: 2 · Depends: T-130, T-139 · Area: services, image · Size: M · Owner: lead

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
