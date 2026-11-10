# T-435 - ACBR (Electron) starts on the Dell but never shows a window; orphaned app scopes

Status: todo · Phase: 2 · Depends: — · Area: shell (compositor), services (ruya-session) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
Play on an Electron app (ACBR on the Dell) shows its window through the shell, and an app that exits or is stopped leaves no scope running, so Play never looks dead.

## Read first
- `docs/tasks/T-421-*.md` (Outcome: ACBR seen, two orphaned scopes), T-363 (ruya-session follows a Flatpak's own scope), T-164 (per-profile Wayland sockets), T-358 (GPU buffers, the patched dmabuf plugin), T-386 (launch)
- `shell/qml/compositor/`, `services/ruya-session/`, `docs/specs/03-services.md` (Session1)

## Scope
1. On the Dell: launch ACBR from Games, find why no window appears (Electron/Ozone flags: `--ozone-platform=wayland`, the socket it connects to, `xdg_wm_base` or a missing protocol in our compositor, XWayland expected?), with the journal and `WAYLAND_DEBUG=1` evidence.
2. Fix it in code (compositor protocol, launch environment, or a Flatpak override the Store writes) so any Electron app starts the same way.
3. Find why two ACBR scopes outlived their session (one from before T-421's session): `Stop` and `AppExited` must leave no `app-flatpak-*.scope`; fix and test in Rust.

## Out of scope
- XWayland support in general, if the cause turns out to be that (then a Proposed ADR line in the Outcome and an Inbox line).

## Acceptance criteria
- [ ] The cause named with its evidence; a test red without the fix (Rust for the scope; QML or a compositor test for the window part if possible).
- [ ] hw (the builder may use the Dell): ACBR's window shown through the shell (a KMS capture), Home and back, Close; no scope left (`systemctl list-units 'app-flatpak-*'` before and after).
- [ ] VM (lead run): `vm-session-check.sh` still PASS; Outcome `Verified: hw (vm pending: vm-session-check)`.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services.md` (Session1 scope cleanup) and 02 §1.5 if launch behaviour changes.

## Hints
- From the STATUS Inbox (T-421), planned by lead-9 on 2026-11-10. Stop anything started by hand by its `app-flatpak-*.scope` (LEAD.md).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
