# T-273 — EPIC: multitasking and task switching (app sessions, task switcher, background policy)

Status: todo · Phase: 3 · Depends: T-164 · Area: docs · Size: M · Owner: lead · Developer surface: internal

## Goal
The player can have several apps open and move between them quickly and smoothly, like iOS, Xbox or PlayStation: a task switcher with a live-looking card per open app, one button to jump back to the last app, apps that wait frozen in the background (a paused game, the weather app where you left it), and a system that closes background apps by itself, politely, when memory is needed for the game in front. The shell must never feel slow while this happens. Owner request, 2026-11-07: "session management ... switch between apps ... with games if we could pause them somehow ... smooth, similar to iOS, Xbox or PlayStation ... the system could kill background apps to improve performance when a game is running ... a dedicated button for switching, or a long press".

## What exists and what is planned (checked 2026-11-07)
- **Built:** `ruya-session` (Session1: `Launch`, `Stop`, `ListRunning`, per-app systemd units as the profile's user, T-162); the app layer in the shell (`Shell.addApp/focusApp/removeApp`, T-150); the play ledger (T-247, foreground time per game); one idle clock (T-202).
- **Planned, not built:** T-164 per-profile Wayland sockets (an app's window appears in the shell: nothing below works without it, and Play does nothing today); T-147 the quick menu with Resume / Home / Close / "Switch to" as a plain list and the Running card on Home; T-165 freeze (cgroup freezer via `FreezeUnit`) of a *profile's* apps on a profile switch (ADR-004); T-201 watchdogs, OOM protection of the shell, force-close of a stuck app.
- **Missing (this epic):** per-app freeze and an atomic "switch to" operation; app lifecycle states and what an app is told; last-frame snapshots and a smooth switch animation; the switcher UI and the quick-switch gesture; the memory and priority policy while a game runs; save-state cooperation and background audio rules; a measured spike on freezing real games.

## Model (proposed; ADR-019 Proposed in `00-overview.md`)
One **foreground** app. Others are **background**: *frozen* (cgroup freezer: no CPU, memory stays; the default), or *kept running* only for apps that declare a reason (audio playback, an active download) and only while the reason holds. A frozen app resumes in a frame or two; it is told by `xdg_toplevel` suspended/visibility events (03 §4.6) before and after. Under memory pressure the system closes the **least recently used** background app first (never the shell, never the foreground app), tells the app (SIGTERM, 5 s grace to save, as today) and shows a toast "Weather was closed to free memory"; its card stays in the switcher as "relaunch". At most N open apps (default 4, scaled by RAM).

## Children
T-274 spike (lead): freeze/thaw real games on the Dell · T-275 per-app freeze and `Switch` in `ruya-session` · T-276 compositor: snapshots, visibility events, smooth switch (lead) · T-277 task switcher UI and quick-switch gesture · T-278 background and memory policy ("game mode") (lead) · T-279 app cooperation: save state, background audio, developer guide.

## Open owner decisions (recommendations in STATUS)
The switch gesture (Guide short = quick menu with the switcher row; Guide double-press = previous app; hold = power as today); whether apps may run in the background at all beyond audio and downloads; whether a game is ever frozen when it has an online session (it would disconnect: warn first).

## Scope of this task (docs only)
Write the spec: a section in `03-services-and-apps.md` (app states and transitions, the policy, the contract draft) and in `02-shell.md` §1.5 (switcher, gesture, toasts), and keep ADR-019 consistent. Every child task's Scope must trace to a paragraph.

## Acceptance criteria
- [ ] The two spec sections exist and agree with ADR-019 and the children; `.\scripts\dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
