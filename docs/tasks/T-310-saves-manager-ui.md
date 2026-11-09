# T-310 — Saves manager UI: browse, copy, move, delete, export and import saves, from Settings and from a game's page

Status: todo · Phase: 5 · Depends: T-309 · Area: shell · Size: M · Owner: builder · Developer surface: none

## Goal
A player can see all saves and save states of a game (or of everything), with size, date and a thumbnail where there is one, and copy, move, delete, export to a USB drive or import from one, with a controller. Part of the saves manager (T-309).

## Read first
- T-309 contract (catalog, operations, `busy`, `would_remove_last_copy`), T-215 (Storage backup UI and the game page "Saves" row: this page is where that row leads), 04 §5 (rows, lists, dialogs, `GlassSheet`, `PowerConfirm` pattern), 02 Settings -> Storage, `shell/PATTERNS.md`, `shell/src/network` (newest backend with a pane)

## Scope
1. **Page** Settings -> Storage -> Saves (and the game page's Saves row opens the same page filtered to the game): a list grouped by game, then kind (Saves, States, Config); each row shows title, slot/label, size, date, a state thumbnail when present; Left/Right moves between filter chips (Saves / States / All); Y or Menu opens the actions for the focused row (a sheet: Copy to..., Move to..., Export to drive..., Delete), multi-select with a hold of A or a "Select" mode (decide with the UX reviewer).
2. **Flows:** target pickers (another slot, another profile of the same app with the PIN/admin flow of T-215, a drive from the list of mounted drives by name), progress and result toasts, conflict dialog (keep both / skip), delete confirmation naming the game and slot with "Undo for 30 days" and a Trash view (Restore, Empty trash); `busy` shows "Close <app> first" with a button that closes it; import from a drive lists exported saves and checks the manifest.
3. States: loading, empty ("No saves yet — they appear when you play"), failed, drive removed mid-operation (the operation stops, nothing half-written is shown).
4. Turkish strings, existing components only (a new component needs its 04 §5 row), late-reply guards (`RequestSequence`), focus asserted after every step, Back leaves every state.

## Out of scope
- Cloud, automatic sync, editing save contents, converting formats.

## Acceptance criteria
- [ ] `tst_saves.qml` with the mock backend: list/filter, each operation's flow and result, conflict, busy, delete + undo + trash restore, drive removed, empty/failed states, other profile's entries never shown; focus after each step; late replies dropped.
- [ ] Screenshots (list with thumbnails, action sheet, delete confirm, trash, empty) in Dreamglass and Daylight read against 04 §7/§8; UX: Back leaves every state; `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Note (lead-8, ADR-028)
A game page Saves section (last change, last backup, history, Back up now, Restore with the safety snapshot) is part of this screen; T-402 adds the Windows rows. A possible save location found by discovery is offered as "Ruya found a possible save location for this game" with Confirm / Ignore / Review, never applied silently.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
