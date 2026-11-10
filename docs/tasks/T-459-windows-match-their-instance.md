# T-459 — A window finds its running game by process, not by the name it gives itself; Close is never dropped

Status: in-progress · Phase: 2 · Depends: — · Area: api, services (ruya-session), shell (compositor, Shell.qml) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

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
_Filled in by the implementer._
