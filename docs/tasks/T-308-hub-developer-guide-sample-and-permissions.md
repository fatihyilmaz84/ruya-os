# T-308 — Hub developer guide, sample app, and per-app permissions for reading hub data

Status: todo · Phase: 5 · Depends: T-302, T-304, T-306, T-220, T-352, T-353 · Area: docs, services, shell · Size: M · Owner: builder · Developer surface: public-API

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** No enforcement of its own: the `hub-read-*` capabilities are rows in ruya-platform's permission table (T-352), asked and stored there.

## Goal
App and emulator authors can use the hub from a guide and a working sample, and the player decides which apps may read what other apps are playing and the Captures library. Part of epic T-302.

## Read first
- T-302 (open owner decisions: permission model), T-304/T-306 contracts, T-220 (privacy settings, per-app permissions), `docs/developers/` (chapters, README, `lint-dev-docs.ps1` rules: code blocks are checked), `permissions-and-sandbox.md`, `05-play-packages.md` §8 (permission vocabulary), T-249 (HIG)

## Scope
1. **Chapter** `docs/developers/game-data-hub.md`: the folders, system ids, `Paths`, `RomRoots`, `Report`, the finish-args, examples in C (SDL) and Python, a RetroArch/standalone-emulator integration recipe (config templates pointing at the hub paths), what the OS does for you (captures), what not to do.
2. **Sample** `samples/hub-sample/`: a tiny Flatpak app that lists ROM roots, writes a save to the named path, and reports now-playing; built and run by a `vm-hub-sample` check (lead run).
3. **Permissions:** hub data readers (other apps) need a permission (`hub-read-now-playing`, `hub-read-captures`; names decided with the closed vocabulary): enforced in the service by app id, asked on first use with a modal on the focused screen, listed and revocable in Settings > Privacy (T-220); default deny.
4. HIG line: apps should use the hub paths when present and fall back to XDG when not.

## Out of scope
- New hub methods, cloud/network sharing.

## Acceptance criteria
- [ ] `dev.ps1 docs` green (dev-docs lint runs the chapter's code blocks as written); Rust tests for the permission checks (default deny, grant, revoke, unknown app); `tst_*.qml` for the ask modal (focus, Back = deny) and the Settings rows; screenshots; UX note.
- [ ] VM (lead run): the sample works sandboxed; a second app is denied until granted.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): this is the chapter and sample task of the hub; use the T-353 harness for the mock and the conformance runner, and add `ruya-api-reviewer` to the review.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
