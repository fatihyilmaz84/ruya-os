# T-464 — A frozen game is never thawed behind another game

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
A game the Hub froze stays frozen until the player resumes it. Today a frozen game can be thawed by accident and then runs unseen behind the game in front, at full CPU and GPU.

## Found (lead-11 study on the Dell, 0.0.64, 2026-11-11)
- BombSquad frozen (Hub, then Home). Launching Asteroid Shooter: pygame closes its first window and opens a second. When the first window went, `Shell.qml` `dropRecord()` made the last shown app (the frozen BombSquad) the focused app; `HubPause` thawed it (it thaws the focused app); the new Asteroid Shooter window then took the front, and BombSquad ran on unseen at 116 % of a core.
- The same fallback runs when a just-launched game crashes at start (Superfluous Returnz segfaults on 0.0.64).
- Reproduced with a D-Bus `Launch`; the Play button path (with the launch splash) is not checked yet.
- Also seen: a thawed SuperTuxKart left off-screen kept 33 % of a core.

## Read first
- `02` §1.6 (the Hub freezes the app; Home leaves it frozen; Switch to thaws the chosen app and leaves the old one frozen); T-457's Outcome (HubPause, the sweep); T-459 (instances by process)
- `shell/qml/Shell.qml` (`dropRecord`, the focused-app fallback, `addApp`/`removeApp`), `shell/qml/HubPause.qml`

## Scope
1. When the front app's window goes, the shell never makes a frozen app the front app by itself: it shows Home (or the launch splash while a launch is in flight) instead. Only the player's Resume / Switch to thaws a frozen app.
2. Belt and braces: an app that is not in front and was frozen by the Hub (HubPause's `asked` list) is frozen again if anything thaws it while another app is in front (decide where this belongs, HubPause or Shell, and say why).
3. Check the Play path with the splash and the crash-at-start path (mock: an app whose first window closes before a second opens; an app that exits during launch).

## Acceptance criteria
- [ ] Frozen A behind Home, launch B whose first window closes and a second opens: A stays frozen, B is in front (test)
- [ ] Frozen A, launch B that exits during launch: A stays frozen, Home shows with the crash toast (test)
- [ ] The player's Resume of A from Home or Switch to A from the Hub still thaws it (existing tests stay green)
- [ ] VM (lead run): extend `scripts/vm-session-check.sh` (or `vm-app-check.sh`) with frozen A + a B whose window is recreated; `Verified: host (vm pending: <check>)`
- [ ] `dev.ps1 test` ALL GREEN

## Hints
- Planned by lead-11 from the frozen-game study (`output\frozen-study\` on the lead's checkout, not tracked). The mock session backend already has stop delays and stubborn stops (T-458); add what a recreated first window needs.

## Outcome
Verified: host (vm pending: vm-app-check.sh recreate)

UX notes: no screen changed (Home, the launch splash and the toasts are the existing ones). States reached in tests: Home with the frozen game's Running card (focus on the recent row), then a second launch, a first window that goes (Home again, focus on Home, `focusedApp` null, the frozen game has no focus), a second window (in front, focus on it), Resume from the card (focus on the game). Back from the Hub is unchanged.

Cause: `dropRecord()` only did half of it. The real fallback was `onShownAppsChanged`, which fires synchronously when `apps` changes and picked `shownApps[last]` as the new front app. Both places now call `Shell.fallbackFront()`: the newest shown app that is not frozen (`appFrozen`: the service says `frozen`, or its instance is in `HubPause.asked`; the instance is found by process, else by the window's app id, because a window without a pid has no instance). When only frozen apps are left the shell sets `appsBehindHome` (Home shows, their Running cards bring them back); a launch splash still covers Home while a launch is on.

Belt and braces (scope 2) lives in `HubPause.rebelt()`, run on every change of the running list: a game in `asked` that is `running` and not frozen, of the signed-in profile, not the front app and with no Freeze already on its way, gets a Freeze. In HubPause rather than Shell because `asked` is its state, and its own Thaws (Resume, Switch to, B) take the instance out of `asked` first, so they are never undone; a game being closed (`state` "stopping", thawed on purpose by Stop) is skipped. New `freezing` list tracks Freezes on their way (the Hub's and the belt's) so nothing is sent twice.

Play path and crash-at-start (scope 3): tests use `launchApp` (the Play path with the splash). `crashy` with a window that then goes, and `nolaunch` (exits during launch, no window): the frozen game stays frozen, Home shows, the error toast is shown. The nolaunch case already worked (no window ever dropped); it is a regression test.

Tests (`tst_hub_pause.qml`, 6 new): recreated window (first window removed, then second added: Home between, no Thaw, second in front), crash at start, cannot start, the player still resumes from the card, the belt (a stray `Session.thaw` while another game is in front is frozen again: calls `freeze, thaw, freeze`), Resume is not undone by the belt.
Revert checks: removing the `pause.rebelt()` call fails the belt test; putting the old `shownApps[shownApps.length - 1]` line back in `onShownAppsChanged` fails the recreated-window, crash-at-start and resume-from-card tests.

VM (lead run): `scripts/vm-app-check.sh recreate` (new): with a Session1 game frozen by the Hub and Home pressed, it starts the key client, kills it, starts it again, and fails if the number of frozen games in ListRunning changed. Not run here (no image).

Files: `shell/qml/Shell.qml`, `shell/qml/HubPause.qml`, `shell/tests/tst_hub_pause.qml`, `scripts/vm-app-check.sh`, `docs/specs/02-shell.md` (1.6). No log line, D-Bus answer or unit name changed, so no `vm-*`/`dell-*` check needed an update (grepped Freeze/Thaw/frozen: `vm-session-check.sh` talks to the service directly and with the shell stopped around its Freeze checks; its "sweep" check still holds because the belt only acts on games in `asked`). No test lost (`lost-tests.sh` empty).

