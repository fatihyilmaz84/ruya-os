# T-165 — Profile switch and sign-out freeze the profile's apps

Status: todo · Phase: 2 · Depends: T-164 · Area: api, services, shell · Size: M · Owner: builder

## Goal
Switching to another profile (or back to the picker) never leaves the previous profile's game on screen or running in the background: its apps are suspended and hidden, and they come back where they were when that profile signs in again (ADR-004: "switching profiles suspends the previous profile's apps").

## Read first
- `docs/specs/00-overview.md` ADR-004; `03-services-and-apps.md` §1.1 (switch flow), §4.1 (`ruya-session`); `02-shell.md` §1.5
- `api/dbus/org.ruyaos.Session1.xml`; `services/ruya-session/src/session.rs`, `spawner.rs`; `shell/src/session/`
- T-162 and T-164 Outcomes; `services/CLAUDE.md`, `shell/CLAUDE.md`

## Scope
1. **Contract first:** a way to suspend and resume one profile's apps (for example `Suspend(profile)` / `Resume(profile)` → status), and a new instance state `suspended` in `ListRunning`; update the XML header. Mock, D-Bus client, service follow.
2. **Service:** suspending freezes each of the profile's app units (systemd `FreezeUnit` on the user manager; cgroup v2 freezer) and resuming thaws them; pure state in the core, the systemd call behind `Spawner`; Rust tests for the state machine (stop of a suspended app works, a crash while suspended is reported once).
3. **Shell:** when a profile switch or sign-out completes, the shell calls `Suspend` for the previous profile and hides its app surfaces (they stay in `apps`, not destroyed); after the profile signs in again it calls `Resume` and the app is back in the app layer, focused. The nightly-restart "app running" report (T-154) counts suspended apps as running.
4. Turkish for any new strings; specs 03 §1.1, §4.1 and 02 §1.5.

## Out of scope
- A per-profile "stop instead of suspend" setting, memory-pressure policies, PipeWire.

## Acceptance criteria
- [ ] Rust tests for suspend/resume in the core; `dev.ps1 test` ALL GREEN.
- [ ] Mock: an app running for Ada, switch to Player One → `Session.running` shows it `suspended` and no app item is visible; switch back → `running`, visible, focused (QML test in `tst_session.qml` or the switch tests).
- [ ] VM (lead run): image built, `RUYA_BOOT_OK`; `vm-session-check.sh` extended: Suspend freezes the unit (`systemctl --user -M ruya-p1@ show -p FreezerState` = `frozen`), Resume thaws it, ALL PASSED.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md` and `vm-session-check.sh` over SSH.

## Docs to update
- `03-services-and-apps.md` §1.1, §4.1; `02-shell.md` §1.5; the Session1 XML header.

## Hints
- `FreezeUnit` is a method on `org.freedesktop.systemd1.Manager` of the user's manager; T-162 found how the service reaches that manager.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
