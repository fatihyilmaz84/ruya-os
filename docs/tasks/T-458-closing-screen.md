# T-458 — "Closing" screen: closing a game shows that it is closing, not that it is running

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
After Close game the player sees "Closing <game>…" until the game has really ended, and the game's card never says Running while it is closing (owner, 2026-11-10: "it takes some time to close but it shows it as running"; PlayStation shows a closing state).

## Read first
- `02` §1.5 (launch splash, Close, the Running pill), §1.6 (Ruya Hub: Close game; T-457: Close thaws, then stops); `04` §5 (Launch splash, Art card, Badge); `03` (Session1: Stop, AppExited, the grace and kill)
- `shell/qml/LaunchSplash.qml`, `Shell.qml` (close path, `AppExited`), `QuickMenu.qml`, the Home Running pill and hero Play

## Scope
1. Close game (Hub) shows a closing screen: the launch splash reused in a closing mode (the app's art, "Closing <title>…" in place of the loading line, the same dots), over the game, focus held, every key taken except Guide (the Hub stays reachable).
2. It ends on `AppExited` for that instance (or on Stop answering that nothing runs): Home in front with the focus where Close left it (02 §1.5).
3. If the game has not ended after 5 s, Home comes back anyway and the game's card shows a **Closing** pill (Badge, neutral) instead of Running; the hero's Play and Accept on the card do nothing but a short toast "<title> is still closing." until `AppExited`.
4. If the service reports the app killed after its grace, no extra message; if it is still listed after the kill, a `warning` toast "<title> did not close. Restart the console if it keeps running." (an Inbox line for a Force close action if the owner wants one).
5. Reduced motion: no slide or scale, the text only.

## Out of scope
- Making apps close faster (the service's grace and kill stay); the Hub pause (T-457).

## Acceptance criteria
- [ ] Close shows the closing screen and it ends on AppExited, focus back on Home (test, mock with an exit delay)
- [ ] A slow exit: Home after 5 s, the card says Closing, Play gives the toast, the pill becomes nothing on AppExited (tests)
- [ ] An app still listed after the kill: the warning toast (test)
- [ ] UX: Back cannot strand the player on the closing screen; Guide still opens the Hub; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the closing screen and the Closing pill reviewed
- [ ] hw (lead run): close SuperTuxKart and ACBR on the Dell, the screen and pill seen

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.5 (Close), §1.6; `04` §5 (Launch splash closing mode, the Closing pill).

## Hints
- Planned by lead-10 on 2026-11-10 from the owner's request. The mock Session needs an exit delay to test the slow path. Reuse LaunchSplash; no new component unless the lead agrees (04 §8).

## Outcome
Verified: host (hw pending: close SuperTuxKart and ACBR on the Dell, the screen and the pill seen)

UX notes: states reached: the closing screen (the launch splash in its closing mode over Home), Home with the Closing pill and the hero reading "Closing...", the "is still closing" toast, the warning toast after a kill that did not work. Back, Accept and the arrows are taken on the closing screen and leave it nowhere (tested); it always ends (AppExited, Stop refusing or answering nothing runs, or the 5 s timer), so Back cannot strand the player. Guide opens the Hub over it, Back from the Hub returns to the screen (focus on the splash, tested), and when the Hub is open while the game ends the Hub keeps the focus. Focus: on the splash while it is up, then on the game's Recent card where Close left it (the Hub's open does not overwrite the saved Home focus while the closing screen is up). Doubted: the hero's primary button reads "Closing..." (new string, still styled as the primary, Accept toasts); the spec said only that Play does nothing but toast.

What was built:
- `LaunchSplash` has a `closing` mode: status line "Closing <title>...", dots on, no Close pill, no Back, no hints. `Shell` owns `closeState` (the screen), `closingInstances` (what Close asked to stop), `closeSplashMs` (5000) and `killCheckMs` (1000); `closeFrontGame` sets them before it calls Stop and goes Home. The screen ends on `AppExited` of that instance or on any `stopFinished` that is not "ok" (`unknown-instance` is "nothing runs"; the error toast for other failures stays). After 5 s it ends and the card stays Closing.
- Closing is shell state, not the service's `stopping` flag (the list is not refreshed after Stop): an instance leaves `closingInstances` when Session1's list no longer has it. `ArtCard.closing` (neutral Badge "Closing", wins over Running); `heroRunning` excludes it; `launchApp` refuses a closing game with the info toast "<title> is still closing." (Play, Accept on the card, the Games page and every other launch path share it).
- A "killed" exit of a closing instance starts a 1 s check; if the instance is still listed, a `warning` toast "<title> did not close. Restart the console if it keeps running." and the card says Running again; a kill that worked is silent.
- Mock Session: `mockStopDelay(ms)` and `mockStubbornStop(bool)` (reset by `mockReset`).
- Translations (Turkish and English) for the six new strings; specs `02` 1.5 and 1.6, `04` Launch splash and Art card.

Tests (tst_appflow, tst_artcard): the closing screen until AppExited with keys, Guide and focus; a slow exit (Home after the wait, Closing pill, Accept and hero Play toast, no resume or launch, the pill gone on AppExited); a game still listed after the kill (warning, Running again); reduced motion (nothing animates); the pill itself in tst_artcard. Screenshots `appflow-7-closing-screen.png` and `appflow-8-home-closing-pill.png` reviewed.
Revert checks (each makes its test fail, restored): the `launchApp` closing guard (slow exit), `closeSplashTimer.restart()` removed (slow exit), the killed branch of `closeEnded` (kill test), `rememberHomeFocus` not skipped while closing (focus test), `ArtCard.stateText` without Closing (tst_artcard and two tst_appflow tests).
Not tested: a "killed" exit that leaves no record (the silent path) and the `unknown-instance` Stop answer have no mock path; they are one-line branches (`closeEnded`, `stopRefused`).
Files: `shell/qml/{Shell,LaunchSplash,ArtCard}.qml`, `shell/src/session/{Session,MockSessionBackend}.{h,cpp}`, `shell/tests/{tst_appflow,tst_artcard}.qml`, `shell/i18n/*.ts`, `docs/specs/02-shell.md`, `docs/specs/04-design-system.md`.
Deviations: none. `dev.ps1 test` ALL GREEN (1177 passed, 98 skipped QML; Rust green), `lost-tests` none, `shots` run once, exit 0.

