# T-402 - Windows game saves: snapshot and restore the saves inside our runner prefixes and Steam's Proton prefixes

Status: todo · Phase: 5 · Depends: T-400, T-382, T-215 · Area: services (the save agent of T-400, the hub), shell (game page Saves) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
A Windows game's progress survives a broken or recreated prefix, a runner change (GE-Proton to Wine, T-385) and an uninstall: the OS snapshots the prefix's user folders after each session and puts them back into a new prefix on request.

## Read first
- ADR-028, the T-400 Outcome (agent, sources, sizes), ADR-025 and `05` §6 (prefix per game per profile), T-215 (backup rules), the proposal §8 (Proton, prefix recreation)

## Scope
1. After a session of a Windows game (Session1 knows when it ends) the agent snapshots `drive_c/users/<user>` minus caches (the exclusion list of T-400) into the profile's snapshot store, following ADR-028's rules (manifest, checksums, verified before good, retention, never the only valid one).
2. A new or recreated prefix offers "Restore saves from <date>" (safety snapshot first, staging, never while running); Steam Proton prefixes are read-only sources unless T-400 says writing back is safe.
3. Game page: a Saves row (last snapshot, Back up now, Restore...).

## Acceptance criteria
- [ ] Rust: exclusion rules, snapshot manifest and verification, restore into staging then swap, refusal while running, retention never deletes the last good one (red without each).
- [ ] VM (this task): `vm-saves-check.sh prefix`: a test `.exe` writes a save in a GE-Proton prefix, the prefix is deleted, a new one gets the save back; `RUYA_BOOT_OK`.
- [ ] `dev.ps1 test` ALL GREEN; screenshots of the Saves row reviewed.

## Outcome
_Filled in by the implementer._
