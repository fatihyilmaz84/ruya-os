# T-186 — Accessible names: action-named buttons and the remaining flows

Status: todo · Phase: 2 · Depends: T-179 (both touch `PowerConfirm.qml`) · Area: shell · Size: S · Owner: builder

## Goal
A screen reader says "Restart now", not "Confirm". And `tst_accessibility` walks the flows it skipped: the first-boot wizard's create-name-and-PIN step and the profile add / manage flows, so every focusable control there has a name.

## Read first
- `docs/tasks/T-176-test-gate-hardening.md` and `T-144-contrast-and-accessible-names.md` Outcomes (what `tst_accessibility` does and the walk helper)
- `shell/tests/tst_accessibility.qml`; `shell/qml/PowerConfirm.qml`, `Setup.qml`, the profile add/manage components (`grep -l "Profile" shell/qml`)
- `04-design-system.md` (accessibility section)

## Scope
1. `PowerConfirm`: the two buttons' accessible names follow the action ("Restart now", "Shut down now", "Sign out"; Cancel stays "Cancel"); visible labels are unchanged unless they are also wrong. Strings via `qsTr()` and in the Turkish `.ts`.
2. Extend `tst_accessibility` to walk the wizard's create-name-and-PIN step and the profile add and manage flows with the existing walk helper (every focusable item has a non-empty accessible name and role).
3. Fix every unnamed control the walk finds, with `Accessible.name` from translated strings.

## Out of scope
- Real screen-reader (AT-SPI) testing on Linux, new components.

## Acceptance criteria
- [ ] `tst_accessibility.qml`: PowerConfirm names for restart / shut down / sign out differ from "Confirm" (fails on the old names).
- [ ] The walk covers the wizard step and both profile flows (the test names them) and finds no unnamed control.
- [ ] Turkish strings for every new name (`lint-translations.ps1` is part of `test`).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `04-design-system.md` accessibility paragraph only if the rule changed.

## Hints
- No screenshot change expected; if a visible label changes, run `shots` and read it.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
