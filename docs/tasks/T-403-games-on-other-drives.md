# T-403 - Games on other drives: install to a drive, move between drives, a missing drive leaves its games "unavailable"

Status: todo · Phase: 5 · Depends: T-389, T-401 · Area: services (ruya-store, ruya-library, ruya-devices storage), shell (Storage, game page) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** **Owner decision 2026-11-10: games may be installed on a removable drive.** Read by the lead as the variant that keeps the invariant "nothing auto-runs from removable media" (the owner may relax it): (1) a drive becomes a games drive only by an admin action on the console (PIN), which records its volume id; no other removable volume is ever mounted executable (`01` 3.6 keeps `nosuid,nodev,noexec` for them; a games drive is `nosuid,nodev`); (2) nothing on the drive starts by being plugged in; (3) when a games drive comes back, each installation on it is verified against what the console recorded at install or last update (Flatpak commit and checksum, or the mechanism T-388/T-389 name) before its first start, and a game that does not match is shown as "needs repair", never run; a drive first seen on another console is adopted through the same admin action and verified against the Store, not trusted; (4) tests for: a foreign drive is not executable, a changed game is refused, an unchanged one starts. This task amends `01` 3.6 and ADR-028 in the same commit, is "VM (this task)" (mount options are image risk) and `Complexity: complex`. Also: the known-volumes registry is `Devices1.Storage`'s (T-302), moves are jobs in T-388's record, and the task is split per service before dispatch.

## Goal
The player can install a game to a second internal or USB drive and move it back and forth; drives are known by their volume id, so a drive mounted elsewhere keeps its games, and an unplugged drive greys its games out instead of losing them. Saves stay on the console (owner, ADR-020).

## Read first
- ADR-028, ADR-026 (moves are jobs in the Downloads/jobs model), `docs/specs/03-services-and-apps.md` (Storage: T-196, T-331; Flatpak installations), T-221 (app management), the proposal §4.3 and §21.1 (storage locations, relocation)

## Scope
1. Storage locations by volume id (udisks UUID) with a purpose ("games"); a Flatpak installation per games drive (`flatpak --installation`), set up the first time the player picks the drive.
2. Install to a chosen location; Move: copy to staging on the target, verify, switch the record, delete the source only after success; refused while the game runs; an interrupted move resumes or rolls back after a reboot.
3. Library and game page show "unavailable" for a game on a missing drive; Play explains which drive to plug in.

## Acceptance criteria
- [ ] Rust: the move state machine with a power cut at every step (fake fs), volume-id resolution across mount paths (red without each).
- [ ] VM (this task): `vm-storage-check.ps1` gets `move`: install the test app to a second virtual disk, move it back, detach the disk (game unavailable), reattach (available); `RUYA_BOOT_OK`.
- [ ] Screenshots (Storage, game page unavailable) reviewed; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
