# T-304 — `Hub1`: contract, `ruya-hub` service, mock and client (ROM roots, paths, game identity, players)

Status: todo · Phase: 5 · Depends: T-302, T-303 · Area: api, services, shell · Size: M · Owner: builder

## Goal
A system service answers, per profile and for sandboxed callers, where ROMs live, where saves/states/config/captures go, what a file is (stable game id), and who is playing. Part of epic T-302.

## Read first
- T-302 (model), the T-303 Outcome (layout, sandbox reach, caller check), `services/CLAUDE.md`, `ruya-profiles` (reference), `ruya-library`, `api/dbus/*.xml`, ADR-017 (player slots; use T-264's contract if it exists, else a stub returning the session owner)

## Scope
1. **Contract first** (`api/dbus/org.ruyaos.Hub1.xml`): `ListSystems`, `RomRoots(system) -> [{path, drive_uuid?, label, removable, writable, present}]` (the profile's folder, the shared console folder, and every mounted drive's `RuyaOS/ROMs/<system>/`; a known drive that is not plugged in is listed with `present=false` so the Library can grey its games), `Paths(kind, game_id) -> path` (kinds `saves|states|config|screenshots|recordings|mods`, created on first use, mode 0700 per profile), `Identify(path) -> {game_id, system, title?}` (content hash with a size limit, optional offline DAT lookup behind a trait), `Players() -> [profile ids]`, signals `RomRootsChanged` (also on mount/unmount of a drive), `ListDrives()` with stable UUID identity; `Paths(kind, game)` honours the player's choice of storage for captures (console or a named drive) with a console fallback when the drive is absent (`status` tells the caller which). Status strings in the header.
2. **Service:** pure core with fakes (systems data from T-303, a filesystem trait, a clock); the caller's uid decides the profile (never a profile argument); an app may only see its own profile; unknown system/kind → status string, never a panic; path traversal and symlink escapes refused; hardened unit and restrictive bus policy like the other services (`systemd-analyze security` aim: OK).
3. **Shell:** D-Bus client and mock for the same surface, no UI.

## Out of scope
- Captures (T-305), now-playing (T-306), permissions UI (T-308), scanning ROM folders for the Library (T-307).

## Acceptance criteria
- [ ] Rust tests: systems data parse (valid/hostile), roots per profile, path creation and modes, traversal/symlink refusals, caller-uid isolation (profile A cannot read B), identify limits.
- [ ] XML, Rust, mock and client agree. VM (lead run): `scripts/vm-hub-check.sh` as the sample app user: roots, a path, `Identify` of a small test file, another user refused, `systemd-analyze security`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- the XML, 03 (game data hub), `docs/developers/saves-and-data.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
