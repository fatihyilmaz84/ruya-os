# T-390 - Update1: the OS download as a v2 job (bytes, rate), cancel, pause, resume

Status: todo · Phase: 3 · Depends: T-388 · Area: api, services (ruya-update), shell (Update client, mock) · Size: S · Owner: builder · Developer surface: internal

## Goal
The OS image download shows bytes, rate and ETA like a Store job, and can be cancelled, paused and resumed without breaking staging, greenboot or rollback.

## Read first
- ADR-026 and the T-388 Outcome (bootc progress source, what a paused pull keeps), `api/dbus/org.ruyaos.Update1.xml`, `services/ruya-update`, `image/CLAUDE.md` (update and rollback rules)

## Scope
1. The v2 job record for the one image job (same field names as Store1) and `CancelDownload`/`PauseDownload`/`ResumeDownload` from T-388's draft; a cancelled download leaves the booted and rollback deployments untouched.
2. Scheduled downloads honour the policy of T-392 when it exists (until then: unchanged).
3. Mock and client.

## Acceptance criteria
- [ ] Rust: the state machine and refusals (cancel while staging: refused with a status), progress parsing from a fixture of T-388's chosen source.
- [ ] VM (this task): `vm-update-check.sh` gets `pause`: a download from the local registry is paused, resumed and staged; another is cancelled and `bootc status` is unchanged; the update/rollback drill still passes; `RUYA_BOOT_OK`.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
