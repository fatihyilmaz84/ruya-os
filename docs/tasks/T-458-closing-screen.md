# T-458 — "Closing" screen: closing a game shows that it is closing, not that it is running

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
_Filled in by the implementer._
