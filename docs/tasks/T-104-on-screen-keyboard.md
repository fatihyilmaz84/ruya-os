# T-104 — On-screen keyboard for controller text entry

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: M

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
- [ ] Typing "Ada 2" with only arrows + Accept, then Done, emits `accepted("Ada 2")` (test `tst_textentry.qml::test_dpad_typing`).
- [ ] Back deletes, then cancels when empty: `cancelled()` is emitted exactly once (test `test_back_semantics`).
- [ ] Shift makes the next letter uppercase, then turns itself off (test `test_shift_one_shot`).
- [ ] `maxLength` is enforced from both the grid and the physical keyboard (test `test_max_length`).
- [ ] `mask: true` shows dots, but `accepted` carries the real text (test `test_mask`).
- [ ] Down from any key in the top row lands on the geometrically nearest key below (test `test_vertical_navigation_nearest`).
- [ ] The modal swallows all keys: the underlying page's focus item is unchanged after the keyboard closes (test `test_modal_and_focus_restore`).
- [ ] Screenshot `9-text-entry.png`: the keyboard fits at 1280×720 inside the safe area, with the focus ring visible.

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
_Filled in by the implementer._
