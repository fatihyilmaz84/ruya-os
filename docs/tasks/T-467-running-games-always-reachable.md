# T-467 — Running games are always reachable: the Hub lists them, Play opens that instance

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
_Filled in by the implementer._
