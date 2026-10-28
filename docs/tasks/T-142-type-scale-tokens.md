# T-142 — Design tokens v2: type scale, motion gap, and a size lint

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: M

## Goal
Every text size in the shell comes from the seven-step type scale of the design system, so screens read as one family and later text scaling has one place to act. A lint keeps literal font sizes from coming back.

## Read first
- `docs/specs/04-design-system.md` §3.2 (type), §3.4 (motion), §8 (changing the system, review list)
- `shell/qml/Theme.qml`, `scripts/lint-tokens.ps1`
- `shell/CLAUDE.md` (QML rules)

## Scope
1. Add to `Theme.qml`: `typeHero` 96, `typeDisplay` 64, `typeTitle` 48, `typeHeadline` 34, `typeBody` 30, `typeCaption` 24, `typeMicro` 20 (design px, multiplied by `u` at the call site as today), the matching weights (`weightLight`, `weightRegular`, `weightDemiBold`), a `fontFamily` token (empty string = system default until T-145), `weightBold` for hero titles, and `overlayMs` 200 (0 under reduced motion).
2. Replace every `font.pixelSize: <number> * u` in `shell/qml` with the token the table in §3.2 maps it to (the "Replaces" column). Where a size changes (44 → 48, 26 → 24, 28 → 30, 32/36/38 → 34, 18 → 20), check the layout still fits.
3. Use `overlayMs` for the Guide overlay's open/close fade (today `pageMs`).
4. Extend `lint-tokens.ps1`: `font.pixelSize:` followed by a digit fails outside `Theme.qml` (the `token-ok` escape stays, for the FPS meter and similar debug text only).

## Out of scope
- Spacing, radius and size tokens (T-143); a bundled typeface (T-145); text scale setting (later).

## Acceptance criteria
- [ ] `tst_theme.qml::test_type_scale` asserts the seven values and `overlayMs` (0 under `--reduced-motion`).
- [ ] `lint-tokens.ps1` fails on a fixture QML line `font.pixelSize: 30 * u` and passes on the migrated tree (test: a lint self-check in `dev.ps1 test`, as the colour rule has).
- [ ] Screenshots: home, picker, Settings (each pane), Guide overlay, PIN pad, keyboard, toasts, OSD, setup steps reviewed against `04` §8; no text clipped in English, nor with the language set to Turkish (check one Settings pane and the setup wizard).
- [ ] `dev.ps1 test` ALL GREEN; no test changed except where an asserted size was a literal (say which in the Outcome).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §3.2 and §3.4: status from planned to built; `shell/CLAUDE.md` token bullet (drop "once T-142 lands" for font sizes).

## Hints
- `grep -rn "pixelSize" shell/qml` lists every call site (about 60).
- Keep the `* u` at the call site: `font.pixelSize: Theme.typeBody * root.u`.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
