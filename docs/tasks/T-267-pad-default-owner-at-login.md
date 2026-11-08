# T-267 — A pad remembers its owner: Guide on the profile picker highlights that profile

Status: todo · Phase: 2 · Depends: T-264, T-265 · Area: shell · Size: S · Owner: builder · Developer surface: none

## Goal
At the "Who's playing?" profile picker (the login screen), pressing Guide on a known pad highlights its default owner's profile, as on PlayStation. The PIN is still required for a protected profile. A first-ever pad has no default. Part of epic ADR-017 (T-263).

## Read first
- ADR-017 (any pad navigates the picker), T-264 contract (`default owner`), the picker (`shell/qml`, profiles), `shell/PATTERNS.md`

## Scope
1. The picker asks the registry which profile the pressing pad owns and moves focus there; unknown pad: focus unchanged.
2. Settings > Players (T-265) sets and clears a pad's default owner; the picker only reads it. Setting a default owner from the picker is out of scope.
3. A deleted profile clears the defaults that pointed to it.

## Out of scope
- Auto-login by pad (never: the PIN rule stays).

## Acceptance criteria
- [ ] `tst_login.qml` (or the picker tests): Guide from a pad with an owner focuses that profile; unknown pad does not; PIN still demanded; deleted profile leaves no stale default.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `02-shell.md` (picker).

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
