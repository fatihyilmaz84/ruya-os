# T-386 - Play starts the game: the Library's launch reaches Session1.Launch

Status: done · Phase: 3 · Depends: T-164 · Area: shell (library, session facade) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: host (vm pending: the lead's Dell run, STK starts from Games with A; no `vm-session-check.sh` step, see Notes)

Model: Sonnet 5.5, effort high, round 1.

**Built.** The wire is in one place in QML, in `Shell.qml` next to the existing `Session` toast `Connections` (the Library C++ and the Home/Games pages are unchanged, so both Play paths use it):
- `Connections { target: Library }` `onLaunchRequested(id, launchSpec)`: a `flatpak:<id>` spec goes to `Session.launch(<id>, Profiles.activeProfile)`; any other spec (Steam's `steam://rungameid/<n>`) goes as it is, because Session1 only knows Flatpak application ids and answers `unknown-app` (the honest error until Steam has a launch path). The title is remembered per app id for the toast.
- `Connections { target: Session }` `onLaunchFinished`: `ok` and `already-running` say nothing more (the window comes with `AppStarted`, `appOpen` follows); any other status toasts (kind `error`) "<title> could not be started" (`qsTr`, `ruyashell_tr.ts` has "%1 başlatılamadı"). The "Starting <title>..." toast of the pages stays.
- No new D-Bus method; the mock already answered failures (`unknown-app` for ids outside `org.example.*`, `already-running`, `unknown-profile`), so it was not changed; the tests read the mock's answer through `Session.launchFinished`.

**Tests** (`tst_games.qml`): `test_play_starts_the_game` (filter Flatpak, A on Turbo Racer: `launchFinished("org.example.Racer", "p2", "ok")`, the instance shows in `Session.running`, exactly one toast, no error), `test_refused_launch_shows_an_error_toast` (A on Portal 2: `unknown-app`, toast "Portal 2 could not be started", kind `error`, nothing running). `init()` now resets the mock session and clears toasts (three toast places fill up across tests and queue new ones). `tst_home`, `tst_motion`, `tst_session` (existing launch/toast tests) stay green. Screenshot `21b-games-launch-failed.png` (new `test_zz_screenshots_launch_failed`) reviewed: both toasts readable, error toast with the red bar, nothing overlaps the nav or grid.

**Revert check:** `Session.launch(appId, Profiles.activeProfile)` replaced by `void appId` in `Shell.qml` (`revert-check.ps1 -Test tst_games`): both new tests went red (`sessionSpy` count), file restored.

**Files:** `shell/qml/Shell.qml` (only the new launch `Connections`, placed above the app-exit one; not the L0/Glass parts), `shell/tests/tst_games.qml`, `shell/i18n/ruyashell_en.ts`, `ruyashell_tr.ts`, `shell/src/library/Library.h` (comment), `docs/specs/02-shell.md` (Home and Library rows).

**Notes and limits**
- UX notes: no new state or focus; Back and focus are unchanged (the toast takes no focus). On a refusal the user sees "Starting X..." and then "X could not be started" (two toasts, the error one with the warning cue).
- VM (lead run) criterion: I wrote no `vm-session-check.sh` step. The wire lives in `Shell.qml`, and the existing probe loads a bare `ruya-shell --load` QML without a signed-in `Shell`, so a faithful step would need the shell signed in plus key injection (as `vm-display-check.sh`); I could not run or test that here. The Dell run (STK from Games with A) covers it, as the criterion allows.
- Steam games still cannot start: Session1 has no Steam launch path (Steam is off in the image anyway); they now say so instead of "Starting..." forever.
- `dev.ps1 test`: two earlier full runs each had one unrelated red under load from other builders (`tst_timezone::test_the_status_clock_follows_a_zone_change_at_once`, then `tst_settings::test_a_hidden_focused_row_hands_the_focus_on`); each file passed alone, the settings one also on unmodified main. Final full run: ALL GREEN, 1020 passed, 80 skipped.
