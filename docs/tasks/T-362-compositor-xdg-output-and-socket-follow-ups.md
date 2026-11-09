# T-362 - Compositor: xdg-output for games, profile-socket and log follow-ups

Status: todo · Phase: 2 · Depends: — · Area: shell (compositor), scripts · Size: S · Owner: builder · Developer surface: none

## Goal
Games learn the real output size and scale (SuperTuxKart disabled display scaling and ran at a low resolution because `zxdg_output_manager_v1` is missing), and the per-profile socket code stops leaking and logs what it means.

## Read first
- `docs/specs/01-platform.md` (compositor, ADR-002, ADR-023), `shell/CLAUDE.md`
- `shell/compositor/Compositor.qml`, `ProfileSockets.cpp/.h`, `IdleInhibitManager.cpp` (how an extra protocol is added)
- T-164 and T-355 Outcomes (follow-up lists only); `scripts/vm-session-check.sh` (display mode)

## Scope
1. **xdg-output:** expose `zxdg_output_manager_v1` (QtWaylandCompositor's `XdgOutputManagerV1` in QML, available in Qt 6.8) with the output's logical position, size and name.
2. **Socket leak:** `ProfileSockets` skips the sync on an empty profile list (it leaks an idle listening fd each time the list empties briefly).
3. **Logs:** the `focus` log line names the focused item even when the System list has it; `appId`/`title` are logged once they arrive, not before.
4. **VM client:** the VM test client passes an app id (it runs as `org.ruyaos.ld-linux-x86-64`).

## Out of scope
- Fractional scaling, HDR, multi-output, dmabuf follow-ups (T-358).

## Acceptance criteria
- [ ] QML/C++ tests: a client sees `zxdg_output_manager_v1` with the output's logical size (`tst_compositor_*`); `an_empty_profile_list_keeps_the_listeners` (fd count stable over 5 empty/non-empty flips); red when removed.
- [ ] VM (lead run): `vm-session-check.sh display` checks that `wayland-info` (or the probe) lists `zxdg_output_manager_v1`; Outcome `Verified: host (vm pending: vm-session-check.sh display)`.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `01` compositor protocol list.

## Hints
- Inbox lines (T-164 reviews, T-355 item 3) are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-09 (lead-7)".

## Outcome
_Filled in by the implementer._
