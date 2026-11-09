# T-309 — Saves manager, service: a catalog of saves per game and safe operations (copy, move, delete, export, import)

Status: todo · Phase: 5 · Depends: T-215, T-302, T-304 · Area: api, services · Size: M · Owner: lead · Developer surface: internal

## Goal
The OS knows, per profile, which save files, save states and configs belong to which game and app (kind, size, time, optional thumbnail and label), and can copy, move, delete, export and import them safely: never while the app runs, never losing data on a power cut, with undo for deletes. Backup of whole apps is T-215; this is the item-level layer (a single slot, a single game) that both the shell and external emulators use. Owner request, 2026-11-08: "a saves management tool, for managing save games (copy, delete, move, etc...), also for those external emulators since they can integrate those".

## Read first
- 03 §4.5a (save locations, `x-ruya-save-paths`), T-215 (data service as root, backups, keep-on-uninstall; reuse its home-walking code and manifest), T-302/T-304 (hub: `Paths(kind, game)`, game ids, drives), T-247 (ledger keys by game id), `docs/developers/saves-and-data.md`, root `CLAUDE.md` invariants (profile data private, PIN rules)

## Scope
1. **Catalog:** `Saves1.List(profile?, filter)` returns entries `{id, game_id, title, app_id, system?, kind (save|state|config), path_label, size, mtime, slot?, thumbnail?}`. Sources, in order: paths the hub names (`Paths`), the app's declared `x-ruya-save-paths`, then the convention (`saves/`, `states/` under `data/`); everything else of an app is one coarse entry "App data". Thumbnails: a sibling `.png` of a state when present (RetroArch style), never decoded in the service (the shell loads it), size-capped.
2. **Operations** (all atomic, journaled, resumable after a crash): `Copy(entries, target)`, `Move`, `Delete` (goes to a per-profile trash for 30 days, `Restore` from trash, `EmptyTrash`), `Export(entries, drive_uuid)` to `RuyaOS/Saves/<profile>/<game>/` with a manifest (game id, app, kind, checksums), `Import(manifest)` (verify, then place; conflict policy: keep both with a suffix, never overwrite silently). Targets: another game slot of the same app, another profile of the same app (admin or that profile's PIN, as T-215), a drive (UUID).
3. **Safety rules:** refuse (`busy`) while the owning app is running (`Session1.ListRunning`); refuse paths outside the profile's app data (traversal, symlinks); size and count limits; disk-space check before copy/export; write temporary + fsync + rename; `Delete` of the last copy of anything asks the shell to confirm (the service just reports `would_remove_last_copy`).
4. Pure Rust core with fakes (filesystem trait, clock, session trait), hardened unit and restrictive bus policy (shell and root; apps reach it only through the hub, T-311).

## Out of scope
- UI (T-310), emulator integration surface (T-311), converting between emulators' save formats, cloud sync.

## Acceptance criteria
- [ ] Rust tests: catalog from fixture trees (convention, declared paths, hub paths, hostile names), every operation including crash in the middle (journal replay), `busy` while running, trash restore/expiry, conflict suffixing, traversal and symlink refusals, drive export/import round trip with checksum failure rejected.
- [ ] XML, Rust, mock and D-Bus client agree. VM (lead run): `scripts/vm-saves-check.sh` with the sample app: list, copy, delete + restore, export to a stick and import, `systemd-analyze security`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- 03 (saves manager), `saves-and-data.md`, the XML.

## Note (lead-8, ADR-028)
Discovery sources and confidence come from ADR-028 and T-400 (app-declared through the hub, our runner prefixes, the known-locations file, manual), run as the profile user (T-400's agent), never as root; state per item: verified / high / probable / unverified; nothing is moved or deleted on an uncertain find. Save states and in-game saves are separate kinds; a state is never assumed compatible across cores or versions.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
