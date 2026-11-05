# T-186 — Accessible names: action-named buttons and the remaining flows

Status: in-progress · Phase: 2 · Depends: — (T-179 is merged) · Area: shell · Size: S · Owner: builder

## Goal
A screen reader says "Restart now", not "Confirm". And `tst_accessibility` walks the flows it skipped: the first-boot wizard's create-name-and-PIN step and the profile add / manage flows, so every focusable control there has a name.

## Read first
- `docs/tasks/T-176-test-gate-hardening.md` and `T-144-contrast-and-accessible-names.md` Outcomes (what `tst_accessibility` does and the walk helper)
- `shell/tests/tst_accessibility.qml`; `shell/qml/PowerConfirm.qml`, `Setup.qml`, the profile add/manage components (`grep -l "Profile" shell/qml`)
- `04-design-system.md` (accessibility section)

## Scope
1. `PowerConfirm`: the two buttons' accessible names follow the action ("Restart now", "Power off now", "Sign out"; Cancel stays "Cancel"); visible labels are unchanged unless they are also wrong. Strings via `qsTr()` and in the Turkish `.ts`.
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
Verified: host (`dev.ps1 test` ALL GREEN, offscreen; no visible label changed, so no `shots`).

Built:
- `PowerConfirm`: new `confirmName` (read-only, by action) is the Confirm button's `Accessible.name`: "Suspend now", "Restart now", "Power off now"; for `custom` the caller sets the new `customConfirmName` (`ProfileManageFlow`: "Delete Ada"; `SystemPane` rollback: "Roll back now"), falling back to "Confirm". Visible labels are unchanged. Cancel stays "Cancel". Turkish and English `.ts` entries added.
- `tst_accessibility`: `test_power_confirm_names_follow_the_action` (suspend, restart, power off; none may be "Confirm"); `test_power_confirm_buttons` now expects "Restart now"; `test_setup_wizard_create_step` (wizard name and PIN step: both rows, name keyboard, PIN pad, focus restored); `test_profiles_add_flow` (Add profile form rows, name keyboard, admin PIN pad) and `test_profiles_manage_flow` (profile row, Rename / Delete rows, rename keyboard, delete confirmation, PIN pad). Every focused item is checked for a non-empty name. The walk found no unnamed control besides the Confirm button.
- Revert test: temporarily putting `Accessible.name: qsTr("Confirm")` back made `test_power_confirm_buttons`, `test_power_confirm_names_follow_the_action` and `test_profiles_manage_flow` fail; restored.
- Docs: 04 section 7 and 02 (Power page) describe the names.

Deviations: the task lists "Sign out" among the names, but no confirmation for signing out exists ("Switch profile" in the Guide acts without one), so there is nothing to name; the `customConfirmName` hook covers any future custom confirmation. "Power off now" (not "Shut down now" as the task text) so the name contains the visible row label "Power off" (WCAG 2.5.3, lead decision). Checked the other names against their rows: "Suspend now" (row "Suspend"), "Restart now" ("Restart"), "Delete Ada" ("Delete Ada"), "Roll back now" ("Roll back to the previous version" contains "Roll back"). Turkish: "Şimdi askıya al" / "Şimdi yeniden başlat" / "Şimdi kapat" contain the row words "Askıya al", "Yeniden başlat", "Kapat". The Confirm button itself still shows the word "Confirm", which its name does not contain.

Files: shell/qml/PowerConfirm.qml, ProfileManageFlow.qml, SystemPane.qml, shell/tests/tst_accessibility.qml, shell/i18n/ruyashell_en.ts, ruyashell_tr.ts, docs/specs/02-shell.md, 04-design-system.md.
