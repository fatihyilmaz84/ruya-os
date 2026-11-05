# T-179 — Backspace is Back on pages and dialogs

Status: done · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
On a keyboard, `Backspace` does what the spec says: it is Back (B), like `Esc`. The 0.0.40 try-out found that pages ignore it. Where a field takes text (`TextEntry`, `PinPad`), Backspace keeps deleting.

## Read first
- `docs/specs/02-shell.md` §4.2 (the key table: Back is `Esc / Backspace`) and the text-entry paragraph below it
- `shell/PATTERNS.md` (Back is handled by `Page`); the ten places that test `Qt.Key_Escape || Qt.Key_Back`: `Page.qml`, `SectionNav.qml`, `SettingsPane.qml`, `StorePage.qml`, `AppDetailPage.qml`, `PowerConfirm.qml`, `Setup.qml`, `PinPad.qml`, `TextEntry.qml`, `Shell.qml` (grep `Key_Escape`)

## Scope
1. One definition of "is a Back key" (a small helper next to where the Guide keys are classified, e.g. `Shell.isBackKey(key)`, or a singleton function) that every one of those places uses, instead of repeating `Escape || Back`. Backspace is Back everywhere except inside a text field (`TextEntry`, `PinPad`, the OSK), which keep their own handling.
2. A key the user holds must not skip several pages: Back on a pressed key acts on the press, not on auto-repeat (`event.isAutoRepeat`), for Backspace only if the existing Escape path already does so; keep the existing behaviour for Escape.
3. Update `dev-setup.md` "Trying it in a window" (it says pages ignore Backspace) and the spec text if it needs it.

## Out of scope
- Key repeat design (B-006), controller mapping, any change to Esc / Back behaviour.

## Acceptance criteria
- [ ] Backspace goes back one level from: a Settings pane to its list, a Settings list to Home, the Store detail page to the Store, a modal (`PowerConfirm`) to its caller, and a nested page (tests in `tst_pages.qml`/`tst_settings.qml`/`tst_store_ui.qml`; assert focus after each).
- [ ] Backspace in a `TextEntry` and in the `PinPad` still deletes one character and does not go back (`tst_textentry.qml`, `tst_lockout.qml`).
- [ ] No `Qt.Key_Escape || ... Qt.Key_Back` pair remains outside the helper (a grep in the Outcome).
- [ ] Revert check: the new tests fail without the helper.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md`; `shell/PATTERNS.md` (one line: use the helper).

## Hints
- `TextEntry.qml:451` and `PinPad.qml:292` show how text handling distinguishes controller Esc from keyboard typing.

## Outcome
Verified: host (`.\scripts\dev.ps1 test` ALL GREEN, offscreen Qt Quick tests; no image, no VM, no screenshots: no visual change).

**Built.** A new singleton `shell/qml/BackKey.qml` (registered as a singleton in `shell/CMakeLists.txt`) is the one definition of "is a Back key":
- `BackKey.isBack(key)`: `Key_Escape` or `Key_Back`. Used by the text fields (`TextEntry`, `PinPad`), where Backspace keeps deleting.
- `BackKey.isBackOrBackspace(key)`: the above plus `Key_Backspace`. Used by `Page`, `SectionNav`, `SettingsPane`, `StorePage` (leaving a search), `AppDetailPage` (uninstall confirm), `PowerConfirm`, `Setup`, and `Shell` (Home, the Guide overlay and its power choices).

I chose a QML singleton over `Shell.isBackKey` because `Page` and the other components have no `Shell` in scope. `TextEntry` now tests Back before its key `switch` (its `case Escape/Back` pair is gone); `SettingsPane` handles Back and Left in its `default` branch. Behaviour for Esc / Back is unchanged.

**Auto-repeat (Scope 2).** The existing Escape paths never looked at `event.isAutoRepeat` (only the Guide overlay ignores repeats of the Guide key, as before), so by the task's rule Backspace does not either; no auto-repeat filter was added. A held Backspace therefore repeats Back exactly like a held Esc does. Key-repeat design is B-006 (out of scope).

**Grep for the criterion** (`Key_Escape \|\| .*Key_Back|Key_Back.*Key_Escape` in `shell/`, build dirs excluded): the only hit is `BackKey.qml` itself. `Key_Back` appears elsewhere in `shell/qml` only in comments.

**Tests added** (each a Backspace twin of an Esc test, focus asserted after each step):
- `tst_settings.qml::test_backspace_is_back`: pane -> list -> Home, nav pill focused.
- `tst_pages.qml::test_backspace_walks_the_stack`: nested page -> Settings pane row (same row focused) -> list -> Home; Backspace on Home does nothing.
- `tst_store_ui.qml::test_backspace_is_back` (detail -> Store on the same card, search -> rows, Store -> Home) and `test_backspace_closes_the_uninstall_dialog`.
- `tst_power.qml::test_backspace_is_back`: the `PowerConfirm` dialog closes (row focused, page stays), then the page.
- `tst_setup.qml::test_backspace_goes_back_a_step`.
- Guards that Backspace still only deletes: `tst_textentry.qml::test_backspace_deletes_and_never_goes_back` (also on an empty field, no cancel, no key leaks to the page) and `tst_lockout.qml::test_backspace_deletes_a_digit_and_never_cancels` (PIN pad).

**Revert checks (run, then restored).** (1) `isBackOrBackspace` without the Backspace term: 6 new tests fail (Pages, Power, Settings, Setup, StoreUi x2). (2) `isBack` with a Backspace term (what a text field would see if the helper were shared): the 3 TextEntry tests fail (the new one, `test_max_length`, `test_physical_keyboard`). The PIN pad guard in `tst_lockout.qml` does not fail under (2), because `PinPad` checks `Key_Backspace` before it asks `isBack`; it pins the behaviour, not the helper split.

**Docs.** `docs/dev-setup.md` ("Trying it in a window": Backspace is B, the "pages ignore it" note is gone), `docs/specs/02-shell.md` (§4.2 note on `BackKey`, §4.4 row), `shell/PATTERNS.md` (use the helper).

**Deviations.** None. Follow-ups: none new (the OSK key grid is part of `TextEntry`, which keeps its own Backspace; nothing else needed).
