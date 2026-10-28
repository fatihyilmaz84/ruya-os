# T-144 — Design review pass: text contrast over the backdrop, accessible names

Status: todo · Phase: 2 · Depends: T-143 · Area: shell · Size: M

## Goal
No text in the shell falls below 4.5:1 against what it actually sits on, and every focusable item has an accessible name, so the Orca spike (`02-shell.md` §7) starts from a clean base.

## Read first
- `docs/specs/04-design-system.md` §3.1 (the `textDim` rule), §7
- `shell/qml/ProfileCard.qml`, `shell/qml/ProfilePicker.qml`, `shell/qml/Shell.qml` (home header and shelf)

## Scope
1. Find every `Theme.textDim` that sits on glass or directly on the backdrop (not on `background`, `panel`, `glassOpaque` or a scrim) and switch it to `Theme.text` (for de-emphasis use weight or size, not a dimmer colour). Known case: unfocused profile names on the picker.
2. Apply the type weights of `04` §3.2 at every `Theme.type*` call site (`font.weight: Theme.weightDemiBold` for Title, Headline and Micro; Light for Hero and Display; Regular is the default). T-142 added the tokens but no call site uses them (lead review, 2026-10-28).
3. Set `Accessible.role` and `Accessible.name` on every focusable item: tiles, profile cards, setting rows (label plus value), category items, dialog buttons, PIN keys, keyboard keys, overlay actions.

## Out of scope
- Screen-reader output itself (the Orca spike), high-contrast theme, text scale.

## Acceptance criteria
- [ ] `tst_accessibility.qml`: walks the focus chain of home, the picker, Settings (each pane) and the Guide overlay with the controller keys and asserts a non-empty `Accessible.name` on every focused item.
- [ ] Screenshots: the picker and home show no `textDim` text over the backdrop (reviewed; named in the Outcome).
- [ ] Weights: `lint-tokens.ps1` fails on a `Text` block that uses `Theme.typeTitle`, `typeHeadline`, `typeMicro`, `typeHero` or `typeDisplay` without a `font.weight` (self-check fixture in `dev.ps1`, like the font-size rule); the migrated tree passes; title and toast screenshots reviewed.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §7: drop "Not done anywhere yet".

## Hints
- In QML tests, `item.Accessible.name` is readable as an attached property.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
