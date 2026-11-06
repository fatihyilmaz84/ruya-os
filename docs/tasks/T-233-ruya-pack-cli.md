# T-233 — `ruya-pack`: the developer's command-line tool

Status: todo · Phase: 7 · Depends: T-230, T-231, T-232 · Area: services (tools) · Size: M · Owner: builder

## Goal
A developer on Windows, Linux or macOS can create, validate, build, sign and inspect a `.play` package with one tool, and what the tool accepts is what the console accepts (it links the same crates).

## Read first
- `docs/specs/05-play-packages.md` §13 (commands), §4, §9.2, §6.2 (resolution rules for the dry run)
- T-230, T-231, T-232 Outcomes; a small existing CLI or the `ruya-store` binary entry point for layout

## Scope
1. Binary crate `ruya-pack` (MIT OR Apache-2.0) in the services workspace; `clap`-style subcommands: `init`, `validate`, `build`, `sign`, `keygen`, `inspect`. (`run` is a later task; do not add it.)
2. `init`: skeleton `play.json` with comments in a `README`, folders, a placeholder icon that fails validation until replaced.
3. `validate`: every off-device rule (T-230, T-232), the licence duty of bundled components (SPDX id plus licence text under `licences/` plus a `source_url` for copyleft types), permission vocabulary, a dry run of runner resolution against a list of "system runner versions" given on the command line (`--system-wine 10.2`), output as text and `--json`; exit codes 0/1/2 (ok / problems / usage). Messages say how to fix.
4. `build`: writes `play.files` (sorted, hashed, links and executable bits recorded from the source directory), refuses real symlinks in a source folder unless `--links-as-data` converts relative in-tree ones, builds a **deterministic** zip (sorted, fixed timestamps, stored by default, `--deflate`), and runs `validate` on the result.
5. `sign`/`keygen`: via T-231; key from a file or the `RUYA_PACK_KEY` environment variable, never as a command-line argument (it would leak into shell history).
6. `inspect`: prints what the console will show (name, signer and tier, permissions in the plain words of 05 §8, size, runner and resolution outcome, art status).

## Out of scope
- `run` on a console, uploading to a store, key management beyond a key file, a GUI.

## Acceptance criteria
- [ ] Round trip (test): `init` -> fill -> `build` -> `validate` -> `sign` -> `inspect` on a generated fixture; the console-side verifier from T-230/T-231 accepts the output (`tests/roundtrip.rs`).
- [ ] Determinism: building the same directory twice gives byte-identical zips (`tests/build.rs::deterministic`).
- [ ] A directory with a real symlink, a path with `..`, a case collision and a missing licence for a bundled Wine each fail `validate` with the right message (`tests/validate.rs`).
- [ ] Runner dry run: `source: newest` with bundled 9.20 and `--system-wine 10.2` resolves to system; with 9.0 resolves to bundled; `max_major` fences correctly (`tests/resolve.rs`).
- [ ] The private key never appears in any output or error (test greps captured output).
- [ ] Builds on Windows (`dev.ps1 rust`) and its test suite is part of `dev.ps1 test`; `ALL GREEN`.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- Spec 05 §13; `docs/dev-setup.md` (how to build and run it on the host); the guide chapter is T-243.

## Hints
- Runner resolution is one pure function shared with the launcher (T-239): put it in the format crate, test it there, and call it from both.

## Outcome
_Filled in by the implementer._
