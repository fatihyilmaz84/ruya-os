# T-416 - The `ruya` developer CLI: SDK discovery and app validation with JSON output and an error catalogue

Status: todo · Phase: 7 · Depends: T-351, T-350 · Area: new `tools/ruya` (Rust), docs/developers, scripts (lint-dev-docs uses it) · Size: M · Owner: builder · Complexity: complex · Developer surface: public-format

## Goal
A developer or an AI agent runs `ruya sdk inspect <module> --format json` and `ruya app validate --format json` and gets exact, stable answers: which APIs exist at which level and stability, which permissions they need, and what is wrong with their app and how to fix it.

## Read first
- ADR-031, ADR-022, `docs/developers/api-surface.md`, `docs/developers/appstream-metadata.md`, `permissions-and-sandbox.md`, `scripts/lint-dev-docs.ps1`, T-351 (API level), T-350, T-233 (`ruya-pack`: becomes `ruya pack` later)

## Scope
1. `ruya sdk list|inspect|permissions|versions` generated at build time from the XML stability tags, the API level and the permission table (no hand-written copy).
2. `ruya app validate [--level basic|compatible|verified]`: AppStream (`x-ruya-*` keys, OARS, controller support), the Flatpak manifest (finish-args against the permission table, the Platform extension), the API level; the checks that need a running app say "not run" here (T-418 runs them).
3. JSON on every command (status, results, errors with code, file, fix hint, doc link), stable exit codes, an error catalogue in `docs/developers/errors.md` generated from the code.
4. `lint-dev-docs.ps1` calls `ruya app validate` on `samples/`.

## Acceptance criteria
- [ ] Rust tests: each validator on good and bad fixtures; JSON schema of the output is stable (snapshot test); an unknown check is "not run", never "pass".
- [ ] `ruya-api-reviewer` finds no blocking item; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
