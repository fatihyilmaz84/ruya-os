# T-386 - Play starts the game: the Library's launch reaches Session1.Launch

Status: in-progress · Phase: 3 · Depends: T-164 · Area: shell (library, session facade) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
Pressing Play (A) on a game in Games or Home starts it: the shell calls `Session1.Launch` for the signed-in profile and the game's window comes to the front. Owner report 2026-11-09 on the Dell (0.0.60): SuperTuxKart shows "Starting SuperTuxKart..." and then nothing happens.

## Read first
- `shell/src/library/Library.h:46` and `Library.cpp:74` (`launch` only emits `launchRequested`, which nothing connects to), `shell/src/session/` (the Session facade and `DBusSessionBackend.cpp`'s `Launch`), `api/dbus/org.ruyaos.Session1.xml` (`Launch(ss) -> (ss)`: argument meaning and status strings)
- `shell/qml/GamesPage.qml:35` and `Shell.qml` (~975: the "Starting ..." toast), `shell/PATTERNS.md`
- T-147 (the full launch experience: splash, quick menu, close) stays its own task; this one is only the wire and an honest error.

## Scope
1. Connect the launch path to `Session.launch(appId, profile)` with the signed-in profile (the facade the shell already has; no new D-Bus method). Do it in C++ or in one place in QML; say which in the Outcome.
2. The answer's status: on success nothing more (the app layer brings the window, `appOpen` follows); on a failure status the toast says the game could not start (`qsTr`, existing toast component), not "Starting..." forever.
3. Mock: the mock session records the call and can answer a failure, so both paths are tested off Linux.

## Out of scope
- Launch splash, quick menu, Close (T-147); the ruya-session boot race (Inbox).

## Acceptance criteria
- [ ] QML: `tst_games` (or the page's test) presses A on a game and asserts the mock session got `Launch` with that app id and the signed-in profile (red without the wire); a failure answer shows the error toast.
- [ ] VM (lead run): `vm-session-check.sh` gets a step that starts the test app from the shell's Library path (or the lead's Dell run: STK starts from Games with A); Outcome `Verified: host (vm pending: <check>)`.
- [ ] `dev.ps1 test` ALL GREEN; a screenshot of the error toast reviewed.

## Outcome
_Filled in by the implementer._
