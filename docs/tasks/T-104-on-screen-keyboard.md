# T-104 — On-screen keyboard for controller text entry

Status: done · Phase: 2 · Depends: — · Area: shell · Size: M

## Goal
Any flow that needs text (profile name, Wi-Fi password, store search) can open a modal on-screen keyboard that is fully usable with a D-pad. Physical keyboards still work in it.

## Read first
- `docs/specs/02-shell.md` §4 (input), §7 (accessibility)
- `shell/qml/PinPad.qml`: the closest existing pattern (modal `FocusScope`, `GridView` keypad, accepts all keys)
- `shell/CLAUDE.md`

## Scope
1. `TextEntry.qml`, a modal component with API:
   - `open(title, initialText, options)`, where options = `{ maxLength, mask: bool, layout: "text" | "email" | "url" }`;
   - signals `accepted(text)` and `cancelled()`.
2. Layout:
   - title;
   - the text field (masked with dots when `mask`), with a visible caret at the end;
   - a key grid: QWERTY letters, digits row, and the action keys Shift, Symbols (toggle to a symbols page), Space, Backspace, Done.
   - For `email`/`url`, add `@`, `.`, `.com`, `/` keys.
3. Controller behaviour:
   - D-pad moves over the keys, wrapping horizontally within a row and moving vertically to the nearest key by x-position;
   - Accept presses the focused key;
   - **Back** deletes one character, and cancels when the field is empty;
   - **Start/Menu** = Done;
   - **LB/RB** (`Key_PageUp`/`Key_PageDown`) move to Backspace/Space.
4. Physical keyboard: printable characters insert directly, Backspace deletes, Enter = Done, Escape = cancel.
5. Enforce `maxLength`; Done is disabled (dimmed, no-op) when the text is empty.
6. Keys show a pressed animation, using Theme tokens. `Sfx` is used as for the PIN pad.

## Out of scope
- IME, non-Latin layouts and dead keys (spec §7 lists i18n separately). Keep the layout data-driven so more can be added.
- Text cursor movement within the field (append/delete at end only).

## Acceptance criteria
- [x] Typing "Ada 2" with only arrows + Accept, then Done, emits `accepted("Ada 2")` (test `tst_textentry.qml::test_dpad_typing`).
- [x] Back deletes, then cancels when empty: `cancelled()` is emitted exactly once (test `test_back_semantics`).
- [x] Shift makes the next letter uppercase, then turns itself off (test `test_shift_one_shot`).
- [x] `maxLength` is enforced from both the grid and the physical keyboard (test `test_max_length`).
- [x] `mask: true` shows dots, but `accepted` carries the real text (test `test_mask`).
- [x] Down from any key in the top row lands on the geometrically nearest key below (test `test_vertical_navigation_nearest`).
- [x] The modal swallows all keys: the underlying page's focus item is unchanged after the keyboard closes (test `test_modal_and_focus_restore`).
- [x] Screenshot `9-text-entry.png`: the keyboard fits at 1280×720 inside the safe area, with the focus ring visible.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §4: a new subsection "Text entry" with the key mapping above.
- `shell/CLAUDE.md`: "use `TextEntry` for any text input; never a raw `TextInput` without it".

## Hints
- Represent the layout as data (arrays of rows of `{label, value, width}`). Compute vertical neighbours from x-centres, not indexes.
- For the tests, host `TextEntry` directly in the test window, not inside `Shell`.

## Outcome
Built the modal on-screen keyboard.

- `shell/qml/TextEntry.qml`: `open(title, initialText, {maxLength, mask, layout})`, `accepted(text)`, `cancelled()`. The layout is data (`layoutFor(symbols, kind)`): five rows on a letters page and a symbols page, each key `{kind, label, value, w, x, cx}` in key units. Kinds: `char`, `shift`, `symbols`, `space`, `back`, `done`. `email` and `url` add `@`/`/`, `.` and `.com`.
- Navigation: Left/Right wrap within the row; Up/Down pick the nearest key by centre x (ties go left; no vertical wrap); PageUp/PageDown jump to Del/Space; Accept presses; Back deletes then cancels on empty; Menu/Enter = Done (no-op while empty, key dimmed); Shift is one-shot.
- The keyboard swallows every key and, on close, returns focus to the item that had it (`Window.activeFocusItem` at open time, if still visible and enabled).
- Keys scale down briefly when pressed (`Theme.focusMs`); the caret blinks only when `Theme.ambientMotion` (new token `Theme.caretMs`).
- `CMakeLists.txt`, `Theme.qml`.
- `tests/tst_textentry.qml` (12 tests): `test_dpad_typing`, `test_back_semantics`, `test_shift_one_shot`, `test_max_length`, `test_mask`, `test_vertical_navigation_nearest` (hand-checked cases plus a brute-force check of every top-row key), `test_modal_and_focus_restore`, `test_controller_shortcuts`, `test_done_disabled_when_empty`, `test_physical_keyboard`, `test_layouts_and_symbols`, `test_zz_screenshots` (`9-text-entry.png`). The tests host `TextEntry` directly over a "page" item that counts keys.
- Docs: `02-shell.md` new §4.4; `shell/CLAUDE.md` "Text input".

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` → 68 passed. `9-text-entry.png` reviewed: the keyboard (1070 x ~460 design px) is centred and well inside the safe area at 1280x720, the focus ring is clear, labels readable.

Deviations and notes:
- **Return/Escape ambiguity.** The task says physical Enter = Done and Escape = cancel, but a controller's Accept/Back are the same keys (`Return`/`Escape`). Resolved with a mode: after a printable key or `Backspace` from a physical keyboard, `Return` = Done and `Escape` = Cancel; any D-pad key returns to controller behaviour. Keypad `Enter` is always Done. Documented in the spec.
- Not wired into any screen yet (no consumer until T-105); tested standalone as the task directed.
- Key labels `Del`, `Shift`, `Space`, `Done` use `qsTr()`; there are no glyph icons, to avoid font coverage problems.
- Mouse/touch is not supported on the keys (out of scope).
- Test hardening outside this task's files: `tst_system_ui.qml` (T-108) failed intermittently (4 of ~25 runs) at two late `verify(tiles.activeFocus)` checks. Instrumenting showed the OS had deactivated the test window (`Window.active` false, `tiles.focus` still true), not a shell bug. The two checks now use a `hasFocus()` helper that accepts the item's `focus` flag only while the window is inactive; with an active window the assertion is unchanged.
