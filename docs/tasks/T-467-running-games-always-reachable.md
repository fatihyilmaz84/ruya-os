# T-467 — Running games are always reachable: the Hub lists them, Play opens that instance

Status: done · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From a running game the player goes Home and can always get back to it: the Hub lists every running game, and Play (or Accept) on a running game's card opens that very instance. Today (owner, 2026-11-11, on the Dell): after Home, the Hub no longer shows the game, and its card says Running but Play only toasts "<game> is already running".

## Found (lead-11)
- `Shell.qml` `onLaunchFinished` ~693-699: on `already-running` the shell calls `windowOf(appId)`; with no window found it toasts "is already running". So the shell has lost the game's window record, or never matched it: `windowOf` and the Hub's Switch to list (`quickMenuOthers`, built from shown app windows) go by the window's app id, which pygame/SDL games and others do not set to their Flatpak id. T-459 matched windows to instances by process for Close only.
- An older Inbox line (T-147 reviews) already asked for Resume or Switch to in the quick menu while apps are behind Home.

## Read first
- `02` §1.5-1.6 (Running card, Resume, the Hub's Switch to, Home leaves the game frozen); T-459's Outcome (InstanceOfPid, `client.processId`), T-464's Outcome (`fallbackFront`, `appsBehindHome`)
- `shell/qml/Shell.qml` (`windowOf`, `runningFor`, `focusApp`, `quickMenuOthers`, `onLaunchFinished`), `shell/qml/QuickMenu.qml` (Switch to rows)

## Scope
1. Reproduce first on the mock (and say which Dell game the owner's case most likely was): a game whose window's app id differs from its Flatpak id, frozen behind Home.
2. The shell keeps one record per Session1 instance and binds windows to it by process (InstanceOfPid, as T-459), falling back to the app id; `windowOf`, Resume, Play/Accept on a running card and the Hub's Switch to all go through the instance.
3. The Hub, opened from Home or over a game, lists every instance in `Session.running` of the signed-in profile (frozen or not) as Switch to rows; one with no window yet says so and does nothing harmful.
4. Play on a running game with a window focuses it (thawing it if the Hub froze it); with no window at all the toast stays, but it must be the rare case.

## Acceptance criteria
- [ ] A game whose window app id differs from its Flatpak id: Home, then its card's Play brings that window back to the front, thawed (test)
- [ ] The Hub from Home lists every running game of the profile, and Switch to opens it (test)
- [ ] Two instances or profiles with the same app id never cross (test)
- [ ] VM (lead run): extend `vm-app-check.sh` or `vm-session-check.sh` with a window whose app id differs; `Verified: host (vm pending: <check>)`; the Dell case goes on the look-at list
- [ ] `dev.ps1 test` ALL GREEN; `shots` only if a screen changes

## Hints
- Planned by lead-11 from the owner's report. T-464 just changed `fallbackFront` and HubPause's belt: keep its tests green. The T-464 review noted `appFrozen`'s app-id lookup takes the first match across profiles: fix it here with the instance record.

## Outcome
Verified: host (vm pending: vm-app-check.sh reachable)
possibly public (lead, from the review): what a running app experiences changes. A game whose window Session1 could not map (pygame/SDL: a window app id that is not its Flatpak id, or no pid) used to keep running under the Hub (`quickMenuApp.instance` was empty, so HubPause froze nothing); now the Hub freezes it, Home leaves it frozen and Play thaws it, like every other game. T-468 documents this for developers.

UX notes: no new screen; the Hub gains rows. States reached in tests: Home with a game behind it (window naming itself `python3.12`, Session1 could not map its process; frozen by the Hub's Home): Running card with the focus, Play brings the window back and the game is thawed, no toast, no second launch. The Hub opened from Home (no app part) now lists a "Switch to <game>" row per running game of the profile, first in the list, with the focus on the first; Accept on a game with a window opens it and closes the Hub (focus in the game, thawed); Accept on one with no window yet toasts "<game> has no window yet." (`info`), the Hub stays with the focus on that row; Back leaves the Hub as before. Doubts: the wording "(no window yet)" is mine; focusing the first Switch to row (rather than Recent) when the Hub opens from Home with a game running is my reading of "always reachable" and is a one-line change in `QuickMenu.present()`.

**Cause (most likely the Dell case).** A pygame/SDL game (BombSquad, Asteroid Shooter) whose window says `python3.12` and whose process InstanceOfPid cannot map (or a window that arrives with no app id and no pid): `appIdOf` returned the window's own id, so `windowOf("<flatpak id>")` found nothing (Play toasted "already running"), and the Hub, which listed Switch to rows only over an app (`if (hasApp)` in `QuickMenu.keysNow`) and only for windows, listed nothing from Home. I could not tell on the host which of the two (process not mapped, or an empty id) it was; both are covered.

**Built.**
- `Shell.instanceOfWindow(record)` (new): the one binding of a window to its Session1 instance: its process's instance (T-459), else the instance running the app id the window gives itself **in the window's profile** (profile "" = the signed-in one), else the profile's only running app that no other window claims (`unclaimedInstance`, the rule Close game already used; not while the InstanceOfPid answer is pending, not for a hidden window). `appIdOf`, `appFrozen` and `runningFor` all go through it, so `windowOf` (Play/Accept on a running card, Resume, Switch to), the Hub's header, the instance HubPause freezes, and the front-app fallback agree. `appFrozen`'s old lookup by app id took the first match across profiles when the window's profile was ""; it now reads the window's own instance (the T-464 review point).
- `quickMenuOthers`: a row for every running (not stopping) app of the signed-in profile except the one in front, frozen or not, with or without a window (`hasWindow`), then any other window whose app Session1 does not list. `QuickMenu`: the rows are no longer tied to `hasApp`; from Home they come first and `present()` focuses the first; a row without a window reads "Switch to %1 (no window yet)". `switchToApp` with no window toasts "%1 has no window yet." and keeps the Hub open. New strings translated (en, tr).
- HubPause (belt and sweep) is unchanged: both already work on Session1 instances, not windows.
- `scripts/vm-app-check.sh reachable` (new): after the drive described in the script (a Session1 game frozen behind Home, the key client as the window with another app id, Accept on the card) no game is frozen and the last compositor focus is the client's. Dell: for the look-at list, Play on BombSquad's / Asteroid Shooter's Running card after Home.
- Docs: `02` §1.5 (window binding), the Hub rows (table, §1.6 list, the quick menu paragraph).

**Tests** (`tst_running_reachable.qml`, new, 9; self-contained fixture): Play on the card of an unmapped `python3.12` window after Home brings it back thawed; the same for a window with no pid and no app id; the Hub from Home lists every running game (one without a window) as Switch to rows, Accept on the windowless one toasts and leaves the Hub, on the other opens the thawed window; a frozen game behind Home is listed and Switch to thaws it; two profiles running the same app id never cross (window lookup, `instanceOfWindow` for pid-less windows of both profiles, `appFrozen` per window, the Hub lists mine once); two unmapped windows are not guessed; Play on a game with no window at all still toasts. **Changed on purpose:** `tst_window_instance::test_close_falls_back_to_the_only_app` asserted the Hub's `quickMenuApp.instance` was `""` for an unmapped window with one game running; it is now that game's instance (the point of this task); the Close assertions of that test are unchanged and pass. `tst_hub_pause`, `tst_appflow`, `tst_quickmenu` green unchanged.
**Revert checks** (`revert-check.ps1 -Test tst_running_reachable`, each CAUGHT): the unclaimed step in `instanceOfWindow` removed (2 fail: both Play tests); the profile check in the app-id step removed (the profiles test); the no-window toast replaced by closing the Hub (the Hub-from-Home test); the Switch to rows moved back inside `hasApp` (2 fail).

Files: `shell/qml/Shell.qml`, `shell/qml/QuickMenu.qml`, `shell/tests/tst_running_reachable.qml`, `shell/tests/tst_window_instance.qml`, `shell/i18n/ruyashell_{en,tr}.ts`, `scripts/vm-app-check.sh`, `docs/specs/02-shell.md`. No log line, D-Bus answer or unit name changed (grepped `vm-*.sh`/`dell-*.sh` for Switch to / already running: none). No D-Bus contract change. Unverified: Linux-only parts (real compositor pids); the Dell case.
