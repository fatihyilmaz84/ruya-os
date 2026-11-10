# T-307 — Library and the emulator frontend use the hub (ROM roots, game identity, art matching)

Status: todo · Phase: 5 · Depends: T-302, T-304 · Area: services, shell · Size: M · Owner: builder · Developer surface: none

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** T-259 is not a dependency (scope 4 already covers its absence); T-259 now follows this task. Run after T-401 where both redefine the Library's game record. Archives from USB or a local folder are hostile input (caps, no path traversal), tested here unless T-304 owns the import pipeline.

## Goal
The Library lists the player's retro games from the hub's ROM roots (profile, shared console folder, and USB drives the player explicitly added), identified by a stable game id and matched to art, and launching one starts the right installed emulator with the ROM, using the paths the hub names. Part of epic T-302 and the first-party emulator frontend (T-259).

## Read first
- T-302, T-304 (roots, `Identify`), T-259 (frontend: its own scan becomes a client of the hub), 03 Library, `ruya-library`, 05 (no emulators/ROMs shipped), root `CLAUDE.md` invariants (nothing auto-runs from removable media)

## Scope
1. A ROM scanner in the library service (or the hub, decide in the Outcome): walks the roots with limits (depth, count, time), reads only names and sizes, hashes lazily on demand, never executes or opens a file as code; USB roots are scanned only after the player chooses "Add games from this drive".
2. **Drives:** a game record keeps its drive UUID; when the drive is absent the game stays listed, greyed, with "Insert <drive name>" (Play is disabled with that reason), and it returns when the drive is mounted again; "Copy to this console" for a game from a drive (progress, free-space check, cancellable); a drive removed during a scan stops the scan cleanly. FAT/exFAT/NTFS names are matched case-insensitively.
2b. Game records: `game_id`, title (from name cleaning, then DAT/art match when available), system, file, art path; stored per profile; a rescan merges without losing play stats.
3. Launch: emulator choice per system (the player's pick or the only installed one), command from the emulator's metadata (`x-ruya-emulator` AppStream keys: systems, launch template) — document the keys; the app gets the ROM through the sandbox path from T-303.
4. T-259's own scanning is replaced by hub calls (coordinate: if T-259 is not merged, add the hub client there).

## Out of scope
- Downloading art or ROMs, DAT file shipping (hook only), scraping websites, BIOS handling.

## Acceptance criteria
- [ ] Tests with a fake filesystem tree: system detection by folder and extension, limits, cleaning of names, merge on rescan, hostile names (path separators, control characters, huge files), USB roots require the explicit action.
- [ ] VM (lead run): a sample "emulator" Flatpak declares the keys; Play launches it with the ROM path.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
