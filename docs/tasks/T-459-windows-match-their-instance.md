# T-459 — A window finds its running game by process, not by the name it gives itself; Close is never dropped

Status: done · Phase: 2 · Depends: — · Area: api, services (ruya-session), shell (compositor, Shell.qml) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
Close game, the Hub's title, the Running pill, Switch to and the pause work for every game, also when its window calls itself something else than its Flatpak id ("python3.12" for pygame games), and a Close never silently does nothing.

## Found (lead-10, Dell 0.0.63, 2026-11-10)
- Asteroid Shooter (pygame/SDL2) names its xdg_toplevel `python3.12`; Superfluous Returnz `superfluous-returnz`; TFE's dialog `zenity`. The compositor passes that id on (`shell/compositor/Compositor.qml:109`).
- `Shell.runningFor()` (`shell/qml/Shell.qml:650-653`) matches a running record only by `record.appId`, finds none, so `quickMenuApp.instance` is "" and `closeFrontGame()` (`Shell.qml:709-713`) skips `Session.stop` silently and goes Home: the game keeps running (owner report). A manual `Session1.Stop` ended it in under 1 s.

## Read first
- `02` §1.5, §1.6; `03` (Session1, scopes, T-363, T-435, T-457); `api/dbus/org.ruyaos.Session1.xml`
- `shell/compositor/Compositor.qml`, `shell/qml/Shell.qml` (`runningFor`, `windowOf`, `closeFrontGame`, `appIdArrived` from T-435), `services/ruya-session/src/` (scope tracking)

## Scope
1. Contract first: `Session1.InstanceOfPid(pid) -> (status, instance)`: the service reads the process's cgroup and answers the running instance whose unit or app scope contains it (`not-found` otherwise). Root reads any `/proc/<pid>/cgroup`; the shell never parses other users' cgroups itself.
2. Compositor: take the client's pid from its Wayland credentials when a toplevel appears and ask `InstanceOfPid`; the window record carries the instance; the app id the window gives itself becomes a display fallback only.
3. `runningFor`, `windowOf`, Switch to, the Hub title/art, the Running pill and HubPause use the instance first, the app id second.
4. `closeFrontGame()`: when no instance is known, fall back to the profile's newest running instance; if there is still none, show a `warning` toast ("Could not close <title>.") instead of going Home silently.

## Out of scope
- XWayland (X11-only games: an owner/ADR question); the Closing screen (T-458).

## Acceptance criteria
- [ ] XML, service, mock, client agree; Rust tests: a pid in the unit, in a second app scope (Electron, T-435), in another profile's scope (`not-found` for a different profile's caller context is not needed: shell-only), an unknown pid (tests)
- [ ] Shell: a window whose app id is `python3.12` closes its game from the Hub, shows its title, gets its Running pill, can be switched to and paused (tests, mock window with a mismatched id)
- [ ] No instance at all: Close shows the warning toast and does not go Home silently (test)
- [ ] hw (lead run): Asteroid Shooter on the Dell: Hub title right, Close ends it, no unit or scope left
- [ ] VM (lead run): `vm-session-check.sh` extended: `InstanceOfPid` of the test app's main pid answers its instance
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03` (Session1), `02` §1.5.

## Hints
- Planned by lead-10 on 2026-11-10 from the owner's report and a Dell run. QtWaylandCompositor: `QWaylandClient::processId()`.

## Outcome
Verified: host (vm pending: vm-session-check)
UX notes: no new screen. Over a `python3.12` window the Hub shows the game's title and art, Close game stops it and goes Home with the focus on its Running card; Accept there brings the same window back (no launch); "Switch to" names it by its game; the Hub pauses it. With no instance at all, Close game shows the `warning` toast "Could not close <title>." and the Hub stays open with the focus on Close game. Doubt: the toast names the window's own id when nothing else is known (e.g. "Could not close python3.12.").

**Built.**
- **Contract** (`api/dbus/org.ruyaos.Session1.xml`): `InstanceOfPid(u pid) -> (s status, s instance)`, statuses `ok`, `invalid` (pid 0), `not-found` (new). Internal (shell and root only, like the rest of Session1), so no stability tag.
- **Service** (`ruya-session`): `Session::instance_of_pid` (pure): reads the cgroup through the new `Spawner::process_cgroup`, parses the v2 line below `user@<uid>.service` (`spawner::parse_cgroup`), names the uid's user (`Spawner::user_name`; Linux `getpwuid_r`), and walks the units deepest first: an instance's own unit or any of its app's Flatpak scopes (`is_app_scope`, so both Electron scopes and never a sibling id), only in that instance's own user's manager; hidden instances never. `systemd.rs` reads `/proc/<pid>/cgroup`. The lead's plan said root reads every `/proc/<pid>/cgroup`; I checked it on the Dell under the unit's own `ProtectProc=invisible`, `ProcSubset=pid`, empty `CapabilityBoundingSet` (a transient root unit with those settings read a `ruya-p1` process's cgroup; ruya-session's own `/proc` mount is `hidepid=invisible`), so no hardening change. D-Bus adapter `instance_of_pid` in `dbus.rs`.
- **Shell C++**: `SessionBackend::instanceOfPid(int)` + `instanceOfPidFinished(pid, status, instance)`, D-Bus client, mock (every launched instance gets a pid, 4001 up; `Session.mockPidOf(instance)` for tests), facade `Session.instanceOfPid`.
- **Compositor**: each surface item gets `pid` (`client.processId`, Wayland credentials); the "app" log line prints it.
- **Shell.qml**: the window record has `pid` and `instance`; `addApp` asks `Session.instanceOfPid`, `instanceArrived` stores the answer and ends the launch splash when the window turns out to be the app being launched (before, a `python3.12` window never ended the splash: it waited for "Still starting"). `appIdOf(record)` is the instance's app id, the window's own as a fallback; `windowOf` (Resume, Play on a running game, Switch to), `quickMenuOthers` and `runningFor` (the Hub's title, art, the instance Close game stops and HubPause freezes) go by the instance first. `closeFrontGame`: the window's instance (round 2 below for the fallback); nothing at all: `warning` toast, Hub stays. New string "Could not close %1." (Turkish "%1 kapatılamadı.").
- **VM check** `scripts/vm-session-check.sh` (`check`): "InstanceOfPid (T-459)": the test app's process in the run's scope and the `sleep 3001` in the second scope answer the instance; pid 1 `not-found`; pid 0 `invalid`.
- **Docs**: `03` §4.1 (contract, shell side, a new InstanceOfPid bullet), `02` §1.5 (windows go by their process; Close game with no instance).

**Tests.** Rust: `a_cgroup_file_names_the_user_manager_and_the_units_deepest_first` (spawner), `a_pid_in_the_unit_or_any_app_scope_names_its_instance` (unit, both Electron scopes, another profile's scope of the same app, a second app), `a_pid_outside_every_instance_is_not_found` (sibling id, system service, the manager's own process, unknown pid, pid 0, an ended instance), `a_pid_of_an_unknown_user_is_not_found`; the status-string test has `not-found`. QML `tst_window_instance.qml` (8 in round 1): the mock's answers; a `python3.12` window: splash ends, Hub title, pause (freeze), Close (thaw, stop, gone); Home's Running card has the focus and its pill, Accept resumes the same window; Switch to names and reaches it, then pauses it; no instance: warning toast, Hub open, focus on Close game, no stop; fallback to the newest app.

**Revert checks.** `revert-check.ps1 -Test tst_window_instance` on `Shell.qml`, each CAUGHT: no `Session.instanceOfPid` call in `addApp` (4 fail); `runningFor` ignoring the instance (3); the toast replaced by the old silent `sendAppsHome()` (1); the newest-app fallback off (1); `appIdOf` returning the window's own id (2); `instanceArrived` not ending the splash (3). Rust by hand (`cargo test pid`, source restored): dropping `|| is_app_scope(..)` fails `a_pid_in_the_unit_or_any_app_scope...`; dropping the own-user filter fails it and `a_pid_outside_every_instance...`.

**Changed on purpose.** `tst_appflow::test_switch_to_another_running_app` (a window naming `org.example.Puzzle`, which no Session1 record runs) went red in my first cut because `runningFor` fell back to the newest app for any unmatched id; I narrowed the newest fallback to Close game only, so the test is unchanged and green.

**Dell (hw check is the lead's):** read `/proc/<pid>/cgroup` of a probe unit from a hardened transient root unit; launched Asteroid Shooter for p1 through `Session1.Launch`, read its processes' cgroups (python3 in `app-flatpak-io.github.denzilferreira.asteroid_shooter-<n>.scope` under `user@1000.service`), then `Session1.Stop`: ListRunning empty, no unit or scope left. Nothing else changed, no reboot. The 0.0.63 compositor logged the window with an empty app id at creation.

**Round 2 (review: Close could stop the wrong game).** `closeFrontGame` no longer takes the newest app: it stops the window's instance, else its own app id's running app; for a window that names no running app it takes `unclaimedInstance`: the profile's only running (not stopping) app that no other window shown to the profile claims by instance or app id, and none at all if another window names no running app either; otherwise the warning. While the window's InstanceOfPid answer is pending (`record.pending`), Close waits for it (`closeWaitsFor`, at most `closeWaitMs` 2 s) and then goes on. `instanceArrived(pid, status, instance)` now sees every answer: it ignores an instance that runs as another profile than the window's and logs a failed or ignored answer (`console.warn`, once per window, as each pid is asked once). Toast with nothing to name: "Could not close the running app." (Turkish "Çalışan uygulama kapatılamadı."). Mock: `Session.mockDelayPidAnswers(ms)`. Merged main first (the `.ts` conflicts were taken from main and the translations refreshed).
New tests (`tst_window_instance`, now 14): two games with an unmapped window in front stop nothing; one game with two unmapped windows stops nothing; two games where the other window is mapped stop the remaining one; Close waits for a pending answer and stops the game it names; an instance of another profile is not taken; the generic wording. **Renamed:** `test_close_falls_back_to_the_newest_app` -> `test_close_falls_back_to_the_only_app` (same case, one game; the "newest" rule is gone). Revert checks (`revert-check.ps1 -Test tst_window_instance`, each CAUGHT 1): the claimed filter off (`takes_the_one_game...`), the "another unmapped window" guard as `continue` (`two_unmapped_windows`), `free.length >= 1` (`between_two_games`), no wait while pending (`waits_for_the_answer`), the profile check off (`another_profile...`), the generic wording replaced (`unnamed_window...`).

**Unverified:** the D-Bus client, the compositor's `client.processId` and `getpwuid_r` under the unit run only on Linux (vm-session-check and the hw run). Screenshots: none taken (no new visual; the toast is the existing `warning` kind).
