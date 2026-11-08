# T-306 — Now playing: apps report what is being played; the OS shows and shares it

Status: todo · Phase: 5 · Depends: T-302, T-304, T-247 · Area: api, services, shell · Size: M · Owner: builder

## Goal
An emulator (or any game) tells the OS, in one small call, what is running: which game, system, emulator and core, a summary of the settings, and a state ("playing", "menu", "paused"). The shell shows it on the Library game page and in the Activity page, the play ledger (T-247) keys time to the game id, and permitted apps can read it. Part of epic T-302.

## Read first
- T-302 (model: push first, optional pull), T-304 contract, T-303 Outcome (caller check), T-247 (`ruya-session` ledger, `Usage`, game page), `shell/src/library`, 02 Library/Home, `docs/developers/play-time.md`

## Scope
1. **Contract** (extend `Hub1`): `Report(a{sv})` with documented keys (`game_id`, `title`, `system`, `emulator`, `emulator_version`, `core`, `rom_path` (never shown raw), `state`, `settings` (a short string map: shader, scale, input profile; max 20 keys, 256 bytes each), `players`); rate limit (1 per second per app), size caps, only the caller's own app instance and profile; `NowPlaying() -> a{sv}` and signal `NowPlayingChanged` for the shell and permitted clients (permission checks are T-308; until then the shell only).
2. **Service:** keeps the latest report per running instance (dropped when `Session1` says the app stopped), validates and truncates, sanitises text (no markup), joins with the instance from `ruya-session`.
3. **Shell:** Library game page shows "System · Emulator (core) · settings summary"; Activity (T-247) rows get the game's title/system when reported; `Usage` keys time to `game_id` when present.
4. An optional pull interface is evaluated and written down (not built).

## Out of scope
- Permissions UI and third-party readers (T-308), achievements (T-246), network presence.

## Acceptance criteria
- [ ] Rust tests: key validation, caps and truncation, rate limit, hostile strings, instance end clears the record, other profile cannot read; mock/client tests; `tst_*.qml` for the game page lines (empty state when nothing reported).
- [ ] VM (lead run): the sample app reports; the record shows in `busctl`; dropped on stop.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN; `UX notes:` line.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
