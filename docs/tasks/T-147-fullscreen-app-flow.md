# T-147 — Full-screen apps: launch splash, quick menu, return and close

Status: todo · Phase: 3 · Depends: T-130, T-138, T-146 · Area: shell · Size: M

## Goal
Pressing Play starts the game full screen with a short art-led launch; Guide brings up the quick menu over the running game; Home and Close work as on a console. Owner decision 2026-10-28 (ADR-012 amendment).

## Read first
- `docs/specs/02-shell.md` §1.5 (behaviour), §1.4 (power from the Guide)
- `docs/specs/04-design-system.md` §3.4 (`launchMs`), §3.6 (glass over an app), §5 (Quick menu, Launch splash), §5.1, §8; canvas boards "Quick menu over a full-screen game" and "Full-screen app launch, play, return"
- The T-130 Outcome (app layer, `KeyRouter`, stand-in app item for tests) and T-138 (`Session` singleton, mock)
- `shell/qml/Shell.qml` (Guide handling, `systemPanel`, `PowerConfirm`)

## Scope
1. **Launch:** Play / Accept on a card calls `Session.launch(appId, profile)`; the launch transition and `LaunchSplash.qml` run until the app layer reports the app's first window (on the host: the stand-in app item appears), then focus goes to the app. Input to the shell is locked meanwhile (Guide still works). Failure status or `AppExited` with `launch-failed` → error toast, splash closes, focus back to Play. 20 s without a window → "Still starting" + Close.
2. **Quick menu** (`QuickMenu.qml`, replaces the centred Guide card): over an app: header (art, title, running time), Resume (focus first), Home, Close game, Switch to (other running apps from `Session.running`), volume row, profile, Power (opens the existing power choices). Without an app: the same panel without the app part. `glassOpaque` on every tier until B-003 (04 §3.6).
3. **Home** from the quick menu: app stays running and loses focus; Home shows its card with a Running pill (from `Session.running`); Accept on it resumes the app. **Close game:** `Session.stop(instance)`; the card's pill goes away on `AppExited`.
4. While an app has focus, only the quick menu, volume OSD and toasts of kind `error`/`warning` are drawn; other toasts queue until the shell is in front (02-shell §1.5).
5. Tokens `launchMs` (0 under reduced motion; reduced motion makes each step a cut).

## Out of scope
- Blur over the app surface (B-003), screenshots of apps, suspending background apps, memory limits, unsaved-state confirm (needs an app protocol), gamescope.

## Acceptance criteria
- [ ] `tst_appflow.qml` (host, mock `Session`, stand-in app item): Play → splash visible → app item gets `activeFocus`; arrows reach the app item; Guide opens the quick menu with Resume focused and no key reaches the app; Back returns focus to the app.
- [ ] Home from the quick menu → Home with the card's Running pill focused; Accept resumes (focus on the app item) (test).
- [ ] Close game → `Session.stop` called, pill gone after `AppExited` (test); `crashy` mock app → error toast, focus back on Home (test).
- [ ] An info toast raised while the app has focus is shown only after returning to Home (test).
- [ ] Reduced motion: no animation runs during launch (test asserts durations 0 / no running animations).
- [ ] Screenshots: splash, quick menu over the stand-in app, quick menu without an app; reviewed against `04` §8 and the canvas boards.
- [ ] VM (after T-130/T-139 are in the image): launch the T-123 test client from a Home card, quick menu over it, Home and resume, close — screenshots in the Outcome; if `ruya-session` is not in the image yet, mark this criterion **unverified** and add an Inbox line.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
# VM: scripts/build.sh, make-disk.sh qcow2, smoke-test.ps1 (see docs/dev-setup.md)
```

## Docs to update
- `02-shell.md` §1 Overlay row, §1.4 (Guide now opens the quick menu), §1.5 (as built); `04` §5 statuses.

## Hints
- The power choices and `PowerConfirm` already work above the overlay: move them, don't rewrite them.
- Keep the quick menu's model keys-only (translations rule).

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
