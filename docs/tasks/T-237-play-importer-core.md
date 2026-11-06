# T-237 — Importer core: staging, unpack, verify, commit (trait + fake)

Status: todo · Phase: 7 · Depends: T-230, T-231, T-232 · Area: services · Size: M · Owner: builder

## Goal
The whole of `ruya-play`'s install pipeline (05 §7.3) as pure logic behind traits, tested on Windows with fakes: it inspects, unpacks into staging with every check, and hands a verified tree to a `Commit` trait. The real Flatpak commit and the systemd sandboxing come in T-238.

## Read first
- `docs/specs/05-play-packages.md` §4, §7.3, §9.1, §9.3
- `services/ruya-store` (pure core + `Flatpak` trait + fake, job table, untrusted-state-file parsing) and `services/ruya-session` (`ProfileDirectory` trait pattern)

## Scope
1. Crate `ruya-play` (core in `src/core/`, binary adapter later): job table (queued/running/finished, persisted like `ruya-store`'s `jobs` file, settled after a restart; never resumes), one install at a time, `Inspect(path)` that reads only data, `Install` that runs: check space -> unpack -> verify -> art vetting -> `Commit`.
2. **Unpacker** with the limits of 05 §9.1: names first, free-space check before the first write (needed size x 1.1), writes into a staging directory created exclusively (no following existing paths: `O_NOFOLLOW`/`openat`-style with `rustix`, as in `ruya-store`'s home deletion), streams with hashing, enforces declared sizes, recreates links from `play.files`, sets modes (0644/0755), removes staging on any error or cancel, progress callbacks that never decrease.
3. `Commit` trait (`commit(staged_dir, manifest, tier) -> Result`) with a fake that records calls; the Flatpak-backed one is T-238.
4. Trust integration: T-231's tier and ceilings decide `needs-developer-mode`, `needs-admin`, `uninstallable`; revocation checked before and after unpack.
5. Cancel mid-unpack removes everything; a power cut leaves only staging directories, which the service removes at start.
6. Everything configurable by paths (incoming, staging, state) so tests use temp dirs.

## Out of scope
- D-Bus, systemd units and sandboxing, Flatpak commit and signing (T-238), the launcher (T-239), update feeds (T-241).

## Acceptance criteria
- [ ] Every hostile fixture of T-230 fails the full install with the same error code and **leaves nothing** in staging or the target (`tests/hostile_install.rs`, a directory-snapshot assertion).
- [ ] Space: a package larger than free space is refused before anything is written (test with a fake free-space function, asserting zero writes).
- [ ] Symlink planted in the staging directory by a concurrent actor (test creates it between two steps) does not make the unpacker write outside staging (`tests/toctou.rs`).
- [ ] Cancel at five points (before unpack, mid-file, after last file, during art, during commit) all end with nothing left and the right status (`tests/cancel.rs`).
- [ ] Restart: a job left running becomes `failed`/`interrupted` once and stays so (`tests/jobs.rs`).
- [ ] Modes: a file listed 755 is executable after unpack, nothing has setuid/setgid/sticky regardless of source attributes (Unix-only test, skipped with a named reason on Windows and run in the VM queue).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- Spec 05 §7.3 as built.

## Hints
- Make the unpacker take a directory file descriptor (or a rooted path type) and never build paths by string concatenation with package names.

## Outcome
_Filled in by the implementer._
