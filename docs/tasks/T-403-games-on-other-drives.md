# T-403 - Games on other drives: install to a drive, move between drives, a missing drive leaves its games "unavailable"

Status: todo · Phase: 5 · Depends: T-389, T-401 · Area: services (ruya-store, ruya-library, ruya-devices storage), shell (Storage, game page) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

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
