# T-194 — Confirm dialogs: the button says the action, so the name matches

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
Today a confirmation's button reads "Confirm" while its accessible name is "Restart now" (T-186). WCAG 2.5.3 wants the visible label inside the name, and a TV viewer reads "Restart now" faster than "Confirm" anyway. Decision (lead, 2026-11-05): **the visible label becomes the action**, the accessible name equals it, and the generic "Confirm" stays only as the fallback for a custom dialog without a name.

## Read first
- `docs/tasks/T-186-accessibility-walk-flows.md` Outcome; `shell/qml/PowerConfirm.qml` (`confirmName`, `customConfirmName`), its callers `ProfileManageFlow.qml`, `SystemPane.qml`
- `04-design-system.md` §5 (confirmation dialog) and §7 (accessible names), §8; `shell/PATTERNS.md` (modals)
- `shell/qml/TextEntry.qml` around the Back/Esc handling (see Scope 3)

## Scope
1. `PowerConfirm`'s confirm button text = `confirmName` ("Restart now", "Power off now", "Suspend now", "Delete Ada", "Roll back now"); `Accessible.name` the same text. Cancel stays "Cancel". Strings in the Turkish `.ts` (the T-186 translations are reused).
2. Check the dialog's layout with the longest English and Turkish names ("Roll back now" / "Şimdi önceki sürüme dön", "Delete <long name>"): the button grows or elides per the existing button rule in 04 §5; no overflow of the dialog.
3. TextEntry cancel hint (T-186 review): with text in the field, Esc deletes a letter and only cancels when empty. Give a screen-reader user and a sighted one the cue: keep the behaviour, but name the cancel path (an accessible description on the field: "Press Back to delete, Back on an empty field to cancel") and make sure the hint bar shows it (`B Delete` / `B Cancel`) if it doesn't already. Decide the smallest change; say what you chose.

## Out of scope
- New dialogs, changing which actions need a confirmation, key repeat (B-006).

## Acceptance criteria
- [ ] `tst_accessibility.qml`/`tst_power.qml`: for each action the visible button text equals its `Accessible.name` (fails on the old "Confirm" text).
- [ ] A geometry test at the real dialog size for the longest Turkish name (the button's text fits or elides inside the dialog).
- [ ] TextEntry: a test for the cue chosen in Scope 3.
- [ ] `dev.ps1 shots`: the power dialog (English and, if the tests have one, Turkish) read against `04` §8.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §5/§7; `02-shell.md` Power page paragraph.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
