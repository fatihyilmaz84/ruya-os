# T-384 - Developers: run a Windows game on the console's GE-Proton (tier-C format, chapter, sample)

Status: todo · Phase: 5 · Depends: T-382 · Area: docs (developers), samples · Size: S · Owner: builder · Developer surface: public-format

## Goal
A developer or a launcher author (a Heroic-like app, a `.play` package) can use the console's GE-Proton from their own Flatpak, from one chapter and a sample, with no RuyaOS D-Bus call.

## Read first
- ADR-025 (developer surface), ADR-022 and `docs/developers/api-surface.md` (tier C; never-public list), the T-381 and T-382 Outcomes (extension name, branch, `runner.json`, umu entry)
- `docs/developers/` existing chapters and `samples/` layout; `scripts/lint-dev-docs.ps1`

## Scope
1. A chapter `docs/developers/windows-games.md`: the runner families (GE-Proton preinstalled; Wine, Wine-GE, UMU-Proton from the Store, T-385) and the shared `runner.json`; declare the extension in the manifest, read `runner.json`, start through umu, environment the platform sets (Wayland socket, pulse) and what a package must not set (`05` §6 env allow-list), the prefix location per profile, what is experimental.
2. A tier-C line in `api-surface.md` ("System runner: GE-Proton extension and `runner.json`", experimental) and the never-public reminder: no call runs a program outside the caller's sandbox.
3. A sample in `samples/` (a manifest that mounts the extension and runs a test `.exe`), checked by `lint-dev-docs.ps1` (manifest parses, extension name matches the image's).

## Out of scope
- A D-Bus API (ADR-025 says none), Steam (T-383).

## Acceptance criteria
- [ ] `lint-dev-docs.ps1` checks the sample (red when the extension name in the sample is changed).
- [ ] `ruya-api-reviewer` finds no blocking item; a `ruya-devdocs-auditor` run reports the chapter usable.
- [ ] VM (lead run): the sample runs on the image (`vm-runner-check.sh sample`).
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
