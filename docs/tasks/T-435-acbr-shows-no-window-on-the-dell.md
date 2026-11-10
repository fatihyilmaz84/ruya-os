# T-435 - ACBR (Electron) starts on the Dell but never shows a window; orphaned app scopes

Status: in-progress · Phase: 2 · Depends: — · Area: shell (compositor), services (ruya-session) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

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
Verified: hw (vm pending: vm-session-check)
UX notes: on the Dell (0.0.62 shell, this branch's `ruya-session`) ACBR's window came up full screen with the focus (compositor log `app focus app: true`); Guide opened the quick menu with ACBR's app part, Home put Home in front with the focus on ACBR's Running card; Close game from the quick menu over the app stopped it and Home came back. **Resume from the Running card did not work on the Dell** ("ACBR is already running" toast): the 0.0.62 shell has no fix for the late app id; the fix (below) is host-tested only, as no shell was built for the Dell.

**Causes, with evidence (Dell, journal of uid 1000):**
1. **No window:** ACBR is Electron 42 (`/app/acbr/version`), and Chromium chooses its Ozone platform by `XDG_SESSION_TYPE`; the session gave none, so it took X11 and exited: `ERROR:ui/ozone/platform/x11/ozone_platform_x11.cc:257] Missing X server or $DISPLAY`, `The platform failed to initialize. Exiting.`, then SIGSEGV and a core dump that took about 2.5 min (the run stayed "running" all that time). Reproduced through Session1 on 0.0.62 at 14:12. With `XDG_SESSION_TYPE=wayland` the GPU process runs with `--ozone-platform=wayland` and the window is in the app layer (compositor `app ... uid 1000 profile p1`). No protocol was missing in the compositor; XWayland is not needed. `WAYLAND_DEBUG` was not needed once the Chromium log named the cause.
2. **Two scopes per run:** zypak starts the sandboxed zygote through the Flatpak portal (`flatpak-spawn --sandbox`), which makes a second `app-flatpak-com.binarynonsense.acbr-<n>.scope` in the same second (cgroup listing: `bwrap ... run.sh` + browser in one, `zypak-helper child` + zygote in the other). The run attaches the earliest-entered scope, ties by name, so it followed the browser at 10:43 and the **zygote** at 14:12 and 14:20. `Stop` and the kill named only the attached scope: when that was the zygote, the browser (which ignores SIGTERM for more than 45 s) ran on. T-421's "two orphaned scopes" (08:58 to 08:59) were one crashed run still in its core dump plus its zygote scope; "one older than this session" was not borne out by the journal (both started at 08:58:10). A scope systemd had to kill after its stop timeout stays listed as `failed` (seen at 14:06 on a hand-made run).
3. **(found on the way) Resume on a running Electron app launched it again:** the compositor hands the window over before the client sets `xdg_toplevel.app_id` (log: `app   uid 1000`, empty id; later `app gone app:com.binarynonsense.acbr`), and `Shell.addApp` kept the empty id, so `windowOf` never found the window.

**What was built:**
- `services/ruya-session/src/spawner.rs`: `console_env()` (`SDL_VIDEODRIVER=wayland`, new `XDG_SESSION_TYPE=wayland`), used by `main.rs`; `control_command(user, verb, unit, app_id)` now names `app-flatpak-<id>-*.scope` (every scope of the app) next to the unit for Stop and the kill (`scope_target` removed); `sweep_commands(user, app_id)`: `stop --no-block` and `reset-failed` on that pattern.
- `scope.rs`: `Sweep` and `RunScopes::take_sweeps`: each run whose end is handed on (unit end not held, held end released when the scope goes, or after 5 missed looks) yields one sweep; `forget` and unknown units none. `systemd.rs` (`Gate::deliver`, `watch_scopes`, `sweep`) runs the sweeps before it hands the ends on, so the glob is matched before a relaunch can happen.
- `shell/qml/Shell.qml`: `appIdArrived` + a `Connections` in the app guard: a window's late `appId` updates its record.
- `scripts/vm-session-check.sh` (check mode): `XDG_SESSION_TYPE=wayland` in the unit's environment; a second scope of the sleeper app (`extra_scope`, `systemd-run --user --scope` as the user) must be gone after Stop; after a SIGKILL to the attached scope only, a left-over second scope must be stopped by the run's end; no `app-flatpak-<sleeper>-*` unit listed with `--all` (no `failed` either) after Stop and after the run's end.
- Specs: 03 (real spawner paragraph: several scopes, Stop/kill pattern, the sweep, the environment, T-165 note), 02 §1.5 (late app id).

**Tests (red without the change):** `scope::the_end_of_a_run_sweeps_the_other_scopes_of_its_app`, `scope::every_way_a_run_ends_sweeps_once` (undid the `sweeps.push` in `end_run`: both failed), `spawner::console_apps_are_told_it_is_a_wayland_session` (removed the `XDG_SESSION_TYPE` entry: failed), `scope::stop_also_stops_the_scope` rewritten for the pattern (made `control_command` push an exact `app-flatpak-<id>-1.scope`: failed), `spawner::sweep_stops_every_scope_of_the_app_and_clears_failed_ones` (argument lists), `tst_appflow::test_a_window_that_names_its_app_late_resumes_from_its_card` (`revert-check.ps1` emptying `onAppIdChanged`: CAUGHT). The old assertions of `stop_also_stops_the_scope` that the attached exact scope is named and that `scope_target` refuses foreign names went with `scope_target` (the behaviour they pinned is the bug); the new version asserts the pattern and that a bad app id or user is refused.

**hw (Dell, this branch's `ruya-session` built in a `fedora:44` container on the Dell and bind-mounted over `/usr/bin/ruya-session`, shell 0.0.62):** `list-units --all 'app-flatpak-*'` empty before each run. Launch through `Session1.Launch` (ACBR is not on the Games page; it is on Home's row): window shown (KMS captures `hw1-app`, `hw7-app`), Guide, Home (Running card, `hw3-home`), Close game from the quick menu over the app: both scopes stopping at once (pattern), the browser's killed after the grace time, `ListRunning` empty, **no `app-flatpak-*` unit listed**. `Session1.Stop` from Home: the same. A SIGKILL to the browser (AppExited path, `status=137`): run ended, nothing listed (the zygote ended by itself there; the sweep's commands, a no-match glob included, return 0 on the Dell). Captures were reviewed and are not in the repo.

**Dell (what was done):** profile p1 already signed in; keys through a throw-away uinput keyboard; KMS captures with ffmpeg; ACBR launched seven times (by hand with `systemd-run` twice, through Session1 five times) and stopped each time; `fedora:44` pulled, a `ruya-session` built in it, bind-mounted over `/usr/bin/ruya-session` for about 10 min (a first try with a drop-in to `/var/tmp` and `/usr/local` failed to start the service with 203/EXEC for a few seconds: PrivateTmp and a read-only `/usr`); at the end: unmounted, the 0.0.62 `ruya-session` restarted (sha256 `aaff1f11…`), `/var/tmp/t435`, `/var/lib/t435` and the `fedora:44` image removed, no drop-in, no manager environment change, no `app-flatpak-*` unit left, Home on screen.

**Deviations:** the Resume fix in the shell (cause 3) is beyond the task's Scope list but within its Goal ("Home and back"); on the Dell it is unverified until an image carries it. The VM check is extended (the criterion asked only for "still PASS") so the image proves the sweep and the pattern.

**Not done / unverified:** the shell fix on hardware; `vm-session-check.sh` changes not run in a VM (lead queue); the Resume step of the hw criterion therefore fails on 0.0.62.
