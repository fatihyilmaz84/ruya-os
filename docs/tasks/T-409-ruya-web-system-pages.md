# T-409 - Ruya Web: downloads, apps, storage and saves pages over their own services

Status: todo · Phase: 6 · Depends: T-406, T-391, T-403, T-310 · Area: services (ruya-web allow-list), web front end · Size: M · Owner: builder · Developer surface: internal

## Goal
The same downloads, installed apps, storage devices and saves the TV shows, managed from the browser with the same actions and the same admin-PIN rules.

## Read first
- ADR-029 and `09-ruya-web.md` (the allowed methods), ADR-026 (downloads), T-403 (drives), T-310 (saves manager), the proposal §10, §12-§14

## Scope
1. Pages for downloads (pause, resume, cancel), apps (details, update, uninstall with the admin PIN), storage (devices, free space, unavailable content, eject), saves (list, back up, restore with confirmation), each only if its service exists.
2. Live updates from the services' signals through one event stream; state is always re-read after a reconnect.

## Acceptance criteria
- [ ] Web tests per page; every admin action refused without the PIN (test); VM (lead run): `vm-web-check.sh system`; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
