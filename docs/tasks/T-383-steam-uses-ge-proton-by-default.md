# T-383 - Steam uses GE-Proton by default once installed

Status: todo · Phase: 5 · Depends: T-381, T-382 · Area: services (ruya-store install hook), docs · Size: S · Owner: builder · Developer surface: internal

## Goal
A player who installs Steam from the Store finds GE-Proton as Steam's default compatibility tool, without opening Steam's settings; the player can still pick another one in Steam.

## Read first
- ADR-025 and the T-381 Outcome (question 6: how Steam's Flatpak finds compat tools and stores the default)
- `docs/specs/03-services-and-apps.md` (Steam row, Store install flow)

## Scope
1. Make GE-Proton visible to the Steam Flatpak (the matching `com.valvesoftware.Steam.CompatibilityTool.*` extension, or our extension under the name Steam looks for).
2. Set the default once, at Steam's first install for a profile, and never again (a player's later choice wins).
3. Spec 03's Steam row says so.

## Out of scope
- Per-game mappings, installing Steam itself by default (Steam stays a separate Store app).

## Acceptance criteria
- [ ] Rust unit tests for the config edit: sets the default on a fresh config, leaves a config with an existing default untouched, survives a malformed file (red without the change).
- [ ] VM (lead run): `vm-runner-check.sh steam` (Steam Flatpak installed, the default reads GE-Proton); Outcome `Verified: host (vm pending: vm-runner-check.sh steam)`.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
