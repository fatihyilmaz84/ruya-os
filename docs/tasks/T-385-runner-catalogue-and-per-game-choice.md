# T-385 - Windows runner catalogue in the Store and a per-game runner choice

Status: todo · Phase: 5 · Depends: T-382 · Area: services (ruya-store, ruya-library), shell (Store, game page), image (extension builds) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
Besides the preinstalled GE-Proton, the player can install other Windows runners from the Store (Wine stable and staging, Wine-GE, UMU-Proton, other open builds of ADR-025) and choose per game which runner and version it uses; a runner in use is never removed under a game.

## Read first
- ADR-025 (as updated by T-381), the T-381 and T-382 Outcomes (recipe, shared `runner.json` schema, which families are allowed)
- `docs/specs/05-play-packages.md` §6.2 (per-game override, "Try the bundled runner" safety net), `03` (Store, Library), `04` §5, §8
- T-244 (the Wine runner pack): this task absorbs it; close T-244 as merged into T-385 in the Outcome

## Scope
1. Extension builds for each family T-381 allowed, from pinned releases (one checked-in file of URL and SHA-256 per branch), using T-382's script.
2. Store: a "Compatibility" category listing installed and available runners with version and size; install, update, remove (remove refused while a game is set to it, with the reason).
3. Game page: Options > Compatibility: "Default (GE-Proton)", then every installed runner and branch; the choice is per profile and per game, kept by `ruya-library`; launch passes it to the run path. After a crash on a non-default runner the page offers "Back to default".
4. Contract first: extend the Store/Library XML (runner list, per-game choice), Rust service and tests, mock, D-Bus client.

## Out of scope
- Steam's tool list (T-383), the developer chapter (T-384), DXVK/VKD3D version pickers.

## Acceptance criteria
- [ ] Rust: per-game choice stored and read back per profile; removing a runner in use is refused (tests red without the change).
- [ ] QML: `tst_store` runner category, `tst_game_page` Compatibility choice and "Back to default" (focus asserted; Back leaves every new state).
- [ ] Screenshots (en, tr) of the category and the choice, reviewed; `UX notes:` line.
- [ ] VM (this task): `vm-runner-check.sh catalogue`: install Wine from the Store, set a test game to it, the test `.exe` runs on Wine, back to default runs on GE-Proton; `RUYA_BOOT_OK`.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Hints
- Large: split by the builder's first read if the extension builds and the UI do not fit one session (the builds first).

## Outcome
_Filled in by the implementer._
