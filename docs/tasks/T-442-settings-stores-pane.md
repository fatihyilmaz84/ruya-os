# T-442 - Settings > Stores: the list, Add a store (address, preview, PIN), turn off, remove

Status: todo · Phase: 3 · Depends: T-440 · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
An admin manages stores with a controller: sees the stores and their state, adds one by typing its address, reads what it is, confirms with the PIN, turns one off, removes one and chooses what happens to its apps. `docs/specs/10-stores.md` §2, §5, §8.

## Read first
- `docs/specs/10-stores.md` §2, §5, §7, §8
- `docs/specs/04-design-system.md`: Settings rows, the confirm dialogs, `TextEntry`, `PinPad`, toasts, copy rules (§3); tokens and components used: existing ones only; new ones allowed: none (a missing one is an Inbox line `design: needs ...`)
- `shell/PATTERNS.md` (a Settings pane, a settings row, a modal, text input); `shell/qml/NetworkPane.qml` (the newest pane with a list, states and a text flow), `PowerConfirm.qml` or `ModeConfirm.qml` (a confirm), `PinPad.qml` (collect mode)
- `shell/src/store/` after T-440 (`Store.stores`, preview/add/remove, the mock controls)

## Scope
1. A **Stores** entry in Settings (visible to every profile; changing anything is for admins: a Standard profile sees the list read-only, each row says who runs it).
2. **List:** one row per store: title, host, trust, state in words (§5), app count; built-in stores first. Flathub has an on/off switch; the official store has none.
3. **Add a store:** `TextEntry` for the address (hint text: "store.example.org"), then a busy state while `PreviewStore` runs (Back cancels and the late answer is dropped), then the confirm sheet with title, host, fingerprint in groups of four, app count and the §8 text; Confirm opens the PIN pad; success returns to the list with focus on the new row and a toast. Every status of §2's table has its own sentence (04 §3: what happened, what to do); the address stays in the field after an error.
4. **A third-party row's actions:** Turn off / Turn on; Remove, whose sheet offers "Keep its apps" (default focus) and "Remove its N apps too"; both ask for the PIN. `needs-attention` and `blocked` rows explain themselves and offer Remove only.
5. Translations (Turkish) for every string.

## Out of scope
- Badges, the install gate and "Everyone can install" (T-443). Adding from USB or the web.
- Any change to the service or the contract (extend it only if this task cannot be done cleanly, and say so).

## Acceptance criteria
- [ ] `tst_stores_pane.qml` against the mock: list order and state words; the add flow end to end with focus asserted after each step (entry, busy, sheet, PIN pad, back on the new row); Back at each step returns one step and never adds; a late preview after Back changes nothing; each refusal status shows its sentence and keeps the address; wrong PIN shows inline and stays on the pad; remove with both choices; a Standard profile cannot reach Add, Turn off or Remove.
- [ ] Screenshots (`dev.ps1 shots`, reviewed against 04 §8): the list with one store per state, the confirm sheet with a long title and host (no clipping, fingerprint readable at 10 ft), the remove sheet, one error.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; the Outcome has a `UX notes:` line.
- [ ] New QML files are in `shell/CMakeLists.txt`; strings use `qsTr()`; `lint-translations` green.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; revert checks named.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` (Settings list), `04-design-system.md` §5 only if a listed component gained a use worth naming, `10-stores.md` (built marks).

## Hints
- The fingerprint is long: show it in a monospace-free way the design system already has for addresses (see how `BluetoothPane` shows a device address with `TailText`); if nothing fits, an Inbox line, not a new component.
- The shell never fetches the address itself; only the service does.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
