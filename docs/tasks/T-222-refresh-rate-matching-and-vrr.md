# T-222 — Refresh-rate matching and VRR: spike, decision and first step

Status: todo · Phase: 4 · Depends: T-198 · Area: shell, image · Size: M · Owner: lead

## Goal
Video and games run at their own rate on a display that can follow: 24/25/30/50/60 Hz content without judder (frame-rate matching), and variable refresh rate (VRR / Adaptive-Sync / HDMI VRR) for games where the display supports it. Owner request, 2026-11-06: "screen refresh rate support". T-198 delivers choosing the resolution and refresh rate in Settings (and the keep-or-revert flow); this task is the *automatic* side. Spec 02-2.4 lists refresh-rate matching as an opt-in Phase 4 item and VRR as a stretch goal.

## What is known (verify)
- The shell is the compositor on Qt `eglfs_kms`; the mode is chosen at start (`QT_QPA_EGLFS_KMS_CONFIG`) so changing it at run time currently means restarting the compositor (the plan in T-198). A seamless runtime switch needs our own KMS mode-setting (atomic commit with a new mode) or a different output layer.
- KMS exposes `vrr_capable` / `VRR_ENABLED` (kernel 5.x+, AMD and Intel DP Adaptive-Sync; HDMI VRR depends on the driver), and the mode list per connector has all rates the EDID declares (including 23.976/24, 50, 60, 119.88/120, 144/240 on monitors). Wayland has no stable standard for an app to request a display rate; useful signals are the app's own frame cadence (surface commits, `wp_presentation` feedback), `wp_content_type` (video/game hint) and `wp_fifo`/`commit-timing` (newer).
- gamescope handles VRR and frame pacing for games; mpv, Kodi and Jellyfin can request modes on other platforms through their own integrations (`--display-fps-override`, Kodi's refresh-rate switching under GBM).

## Scope
1. **Measure and decide first (Outcome, with evidence on the Dell, a 120/144 Hz monitor if available, and QEMU):** which modes each connector offers; what switching cost a mode change has (black time) via the restart route and via an atomic KMS modeset prototype in the shell; whether the Intel UHD 630 output over DP supports Adaptive-Sync (`vrr_capable`), and the HDMI path; how a fullscreen app's cadence can be measured in the shell (commit timestamps over 2 s, tolerance) and what hints apps give (`wp_content_type`, MPV/Kodi behaviour under our compositor).
2. **Frame-rate matching (build if the measurements support it):** a Settings -> Display switch "Match frame rate" (Off by default) with the compositor measuring the foreground fullscreen app's cadence and, when it is stable near 23.976/24/25/29.97/30/50/59.94/60 Hz, switching to the matching or an integer-multiple mode the display lists (24 -> 24 or 48/72/120), and switching back on exit/Guide; a brief "Switching..." cover to hide the black time; never while the Guide overlay or a modal is up; safe fall-back if a mode fails. If a seamless runtime modeset cannot be done in Qt eglfs, deliver the decision (an ADR *Proposed*) and the smallest working variant (for example per-app launch-time selection via the restart route, only for apps that declare a content rate with an AppStream key `x-ruya-frame-rate`).
3. **VRR:** report feasibility; if the display and driver support it and the modeset path exists, an on/off in Display ("Variable refresh rate: Auto / Off", default Off until measured), enabling `VRR_ENABLED` only while a fullscreen app runs; otherwise an ADR with the route (gamescope for games, T-218's decision) and the blocker.
4. **Docs for developers:** how an app signals its rate and what the console does (chapter in `docs/developers/`, T-214).

## Out of scope
- HDR (T-218), HDMI-CEC, automatic resolution switching, per-app display profiles, calibration, frame generation/upscaling, game-mode low-latency (ALLM) signalling (a note in the ADR is enough).

## Acceptance criteria
- [ ] The Outcome has the Scope 1 measurements (a table per connector and per route) and states what is built and what is only decided.
- [ ] If matching is built: tests for the cadence detector with fake commit timestamps (24 fps, 23.976, 25, 30, 50, 59.94, 60, jittery, variable, a stall), the mode choice (exact, multiple, none available) and the revert-on-exit state machine with a fake clock; a mock Display service for the Settings row; screenshots of the switch and the cover; Turkish.
- [ ] Hardware (lead, the Dell with a display that offers 24/50/60 Hz): a 24 fps test video measured (dropped/repeated frame count with `mpv --vo=gpu` stats or a frame-time capture) with matching Off and On; the black time of a switch in ms; the Guide button and exit return to the original mode.
- [ ] An ADR (*Proposed*) for what is not built (VRR route, runtime modeset) in `00-overview.md`, with the owner decision it needs listed in `STATUS.md`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN (if code was touched).

## Docs to update
- `02-shell.md` §2.4 / Display, `03` Display, `00-overview.md` (the ADR), `docs/developers/`, `docs/dev-setup.md` (how to read modes and measure).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: findings, what was built, the ADR, follow-ups._
