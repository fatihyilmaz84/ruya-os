# T-194 — Confirm dialogs: the button says the action, so the name matches

Status: done · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

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
Verified: host (`dev.ps1 test` ALL GREEN; the new Power screenshots read from a run with `QSG_RENDER_LOOP=basic`, see below). Nothing Linux-only changed.

**Built.**
1. `PowerConfirm`: the action button's visible text is `confirmName` ("Suspend now", "Restart now", "Power off now", the caller's `customConfirmName` such as "Delete Ada" / "Roll back now"; "Confirm" only for a custom dialog without a name), and `Accessible.name` is the same string. Cancel is unchanged. The Turkish strings are the T-186 ones (no new strings for this part).
2. Layout: Cancel stays a fixed 300 px pill; the action pill grows with its label (label plus `spaceL` on each side, never narrower than 300 px) up to 90 % of the window minus the card padding and Cancel, then the label elides on the right (the accessible name keeps the whole text). The card sizes from the row, so it never leaves the window. New object names `powerConfirmLabel` and `powerConfirmPanel` for the tests.
3. TextEntry cue. Chosen (smallest change that serves both audiences): the behaviour is untouched; `TextEntry` gets `backDeletes` (text in the field and not in physical-keyboard mode), `entryHints` (`B Delete` / `B Cancel`) and an `Accessible.description` ("Press Back to delete, Back on an empty field to cancel", or "Press Back to cancel" when Back would cancel at once). `Shell.hintList` returns `entryHints` when the focused item is a `TextEntry` (`activeItem as TextEntry`), before the generic modal `B Cancel`; this also covers the setup wizard's name keyboard without touching `Setup.qml` (T-203's lane). The hint used to say "B Cancel" even while Back deleted a letter.

**Tests (each fails when its change is undone; undone together in one run and then the width cap alone).** Undoing the label (`text: qsTr("Confirm")`) failed `Accessibility::test_power_confirm_names_follow_the_action`, `test_profiles_manage_flow`, `Power::test_button_label_is_the_action`, `test_button_label_is_translated`, `Update::test_rollback_asks_for_the_admin_pin`; undoing `backDeletes` failed `TextEntry::test_back_cue` and `Hints::test_text_entry_back_cue`; replacing the width cap by 99999 failed `Power::test_longest_names_fit_the_dialog` ("absurd name: a button is outside the card"). The geometry test runs at the real scale (u = 0.667 on the 1280x720 host), waits for the next layout frame (`tryVerify`; Row/Column lay out lazily) and covers "Roll back now", "Delete Wolfeschlegelsteinhausen Jr" (English, fits without eliding), "Şimdi önceki sürüme dön" and a long Turkish deletion label ("Wolfeschlegelsteinhausen Jr. profilini sil"), plus a 295-character name that must elide inside the card.

**Docs.** `04` §5 (dialog buttons) and §7 (accessible names, the keyboard's description and hint), `02` Power page paragraph and the hint-bar paragraph.

**Screenshots.** `tst_power.qml` `test_zz_screenshots` now also saves `13c-power-confirm-tr.png` (Turkish) and `13d-power-confirm-long-daylight.png` (a long deletion name under Daylight, with a detail line) and waits for the dialog to fade in and the theme to finish. Read at full size: the label sits inside the pill in English, Turkish and the long Daylight case; the danger fill with `Theme.text` reads on both themes (the contrast test already covers it). `13-power-confirm.png` used to capture the profile picker instead of the dialog (stale frame, seen in the Nov 4 shot as well); it now waits for the fade and shows the dialog.

**Environment note (unverified for the rest of `shots`).** On this desktop the default threaded render loop does not advance animations in real windows (the dialog's opacity stayed 0 after 1 s), so `dev.ps1 shots` fails 8 animation-dependent screenshot tests in other files (BatteryCluster, Glass, Glide x2, GlideSettings, Lockout, Settings scroll cue, Wallpaper), identically on three runs and none of them in code this task touches. With `QSG_RENDER_LOOP=basic` the Power screenshot test passes and the images are right; I ran only that function that way. Whether those 8 also fail on main was not checked.

Files: `shell/qml/PowerConfirm.qml`, `shell/qml/TextEntry.qml`, `shell/qml/Shell.qml`, `shell/i18n/ruyashell_en.ts`, `shell/i18n/ruyashell_tr.ts`, `shell/tests/tst_power.qml`, `tst_accessibility.qml`, `tst_hints.qml`, `tst_textentry.qml`, `tst_update.qml`, `docs/specs/02-shell.md`, `docs/specs/04-design-system.md`.

Deviation: none. Follow-ups (Inbox in the HANDOFF): `shots` render-loop stall on this desktop; `Setup.hints` still says "B Cancel" itself (it is shadowed by the keyboard's hints in practice).
