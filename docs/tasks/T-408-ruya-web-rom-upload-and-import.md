# T-408 - Ruya Web: ROM and BIOS upload, then import through the hub (identify, duplicates, archives)

Status: todo · Phase: 6 · Depends: T-406, T-304 · Area: services (the hub ruya-gamedata: import pipeline), services (ruya-web: uploads), web front end · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
The player drags ROMs (or a zip of them) and the BIOS files they own onto the page, sees each file go through upload, validation, identification and registration, and finds the games in the Library on the TV; duplicates and unknown files are shown, never silently added.

## Read first
- ADR-020 (ROM roots: shared read-only and per profile; `Identify`), ADR-028, ADR-029, T-304 (GameData1), T-232 (vetting pattern), the proposal §9 (upload vs import, states, archives, duplicates) and §11 (BIOS)

## Scope
1. Upload: resumable chunks into a staging area owned by the hub (size and free-space checks, cancel, retry); upload and import are separate stages with their own states.
2. Import in the hub: system detection from the hub's data file (not a list in the web code), content hash, duplicates by hash, archives with path, size and count limits and a preview of what will be imported; BIOS files checked against known hashes, placed where the hub says, never shipped by us.
3. Progress and history as jobs (ADR-026's record).

## Acceptance criteria
- [ ] Rust: archive traversal and bomb refusals, duplicate rules, BIOS hash check, staging cleanup after a failure or power cut (red without each).
- [ ] VM (this task): `vm-web-check.sh import`: a zip of two test ROMs and a bad archive; the good ones appear in `Library1`, the bad one is refused; `RUYA_BOOT_OK`.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
