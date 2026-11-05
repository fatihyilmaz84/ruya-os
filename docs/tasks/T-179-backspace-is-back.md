# T-179 — Backspace is Back on pages and dialogs

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
