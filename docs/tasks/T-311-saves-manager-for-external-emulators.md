# T-311 — External emulators and apps integrate with the saves manager (register their save locations, open the manager, react to changes)

Status: todo · Phase: 5 · Depends: T-309, T-304, T-306, T-352 · Area: api, services, docs · Size: M · Owner: builder · Developer surface: public-API

## Goal
Any emulator or game, not only first-party ones, can tell the OS where its saves, states and configs are and how to label them, can open the saves manager at the right game from its own menu, and learns when the OS changed its files (a slot copied in, a delete, an import), so it can reload. Part of the saves manager (T-309) and the game data hub (T-302).

## Read first
- T-309 (catalog and operations), T-304 (`GameData1`: caller identity by uid, `Paths`), T-306 (now-playing: game id), 03 §4.5a (`x-ruya-save-paths`, `x-ruya-cache-paths`), `docs/developers/saves-and-data.md`, `permissions-and-sandbox.md`, T-249 (HIG), RetroArch's layout as the reference emulator (`saves/`, `states/` with `.state` and `.png` thumbnails, per-core subfolders)

## Scope
1. **Declare:** AppStream custom keys, validated by the Store at install and by the catalog at read time: `x-ruya-save-paths`, `x-ruya-state-paths`, `x-ruya-config-paths` (relative to `$XDG_DATA_HOME`/`$XDG_CONFIG_HOME`, globs allowed with `*` only, no `..`), `x-ruya-state-thumbnail` (pattern like `<name>.png`), `x-ruya-slot-pattern`. Unknown values ignored, hostile ones rejected with a log line.
2. **Register at run time (optional):** `GameData1.RegisterSaves(game_id, [{kind, path, label, slot, thumbnail}])` so an emulator that knows the ROM and the slot says it exactly (better than guessing from file names); the service checks the paths against the caller's own app data.
3. **Open the manager:** `GameData1.OpenSaves(game_id?)` asks the shell to show the saves page (T-310) filtered to the game; the emulator is put in the background first (it is `busy` for operations while running: the page offers "Close <app>"); documented for the emulator's own "Manage saves" menu item.
4. **Notify:** signal `SavesChanged(game_id, kinds)` delivered to the app that owns them while it runs (and on next start through a small `changed` marker in its data dir) so it can rescan; documented as best-effort.
5. **Guide + sample:** a chapter "Saves and the OS" in `docs/developers/` (declare, register, open, react, atomic writes, thumbnails) and the sample app does all four; a RetroArch recipe with the config lines (`savefile_directory`, `savestate_directory`, `screenshot_directory`) pointing at the hub's paths.

## Out of scope
- Patching emulators, format conversion, a save-sync protocol between devices.

## Acceptance criteria
- [ ] Rust tests: key parsing (valid/hostile globs, traversal, huge lists), registration checks (own app only, own profile, caps), the notify marker, `OpenSaves` ignored for unknown game ids.
- [ ] `dev.ps1 docs` green (the dev-docs lint checks the chapter's code); XML, mock and client agree.
- [ ] VM (lead run): the sample declares and registers; the catalog lists its slots with labels; `OpenSaves` reaches the shell.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): external emulators call it, so it follows the DoD of `api-surface.md`: stability tags, a paragraph, a sample, mock, conformance test (including a call for another app's saves).

## Note (lead-8, ADR-028)
The proposal's emulator adapters (`docs/archive/research/...`, §11) are rejected by ADR-028: an emulator tells the hub its save, state, memory-card and NAND locations and formats through this API; the OS never launches or configures emulators itself.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
