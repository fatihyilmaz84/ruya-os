# T-143 — Design tokens v2: spacing, radius, sizes, and the Badge component

Status: todo · Phase: 2 · Depends: T-142 · Area: shell · Size: M

## Goal
Spacing, corner radii and the standard control sizes come from tokens, and the small pills scattered through the shell (PIN badge, "mock services" flag) become one `Badge` component, ready for the Store's source badges (T-111).

## Read first
- `docs/specs/04-design-system.md` §3.3, §4, §5 (Badge row), §8
- `shell/qml/Theme.qml`, `shell/qml/ProfileCard.qml`, `shell/qml/Shell.qml` (the mock-services label), `shell/qml/controls/SettingControl.qml`

## Scope
1. Add to `Theme.qml` the spacing (`spaceXxs` … `spaceXxxl`), radius (`radiusS`, `radiusM`, `radiusL`) and size tokens (`rowHeight`, `buttonHeight`, `tileWidth`, `tileHeight`, `avatarSize`, `focusRingWidth`, `focusRingOffset`) with the values in §3.3.
2. Replace literal `spacing`, margins, `radius` (except `height / 2` pills) and the listed control sizes in `shell/qml` with tokens. A literal that matches no token: use the nearest token if the screenshot stays right, otherwise keep it with `// token-ok: <reason>` and list it in the Outcome.
3. `qml/Badge.qml` (`text`, `kind`: `neutral | success | info | warning`): `typeMicro`, caps, pill, fill = the kind's colour at 18 % (new tokens `badgeFillAlpha`), text in that colour; neutral = `glassBorder` outline and `textDim`. Use it for the PIN badge and the mock-services flag.

## Out of scope
- A lint for spacing literals (too many legitimate numbers; revisit after this lands). Hint bar (proposed, not planned). Toast and OSD redesign.

## Acceptance criteria
- [ ] `tst_theme.qml::test_space_shape` asserts the token values.
- [ ] `tst_badge.qml`: each kind has the expected colour and `Accessible.name` equal to its text.
- [ ] Screenshots of every screen reviewed against `04` §8; differences from before are listed in the Outcome (expected: small spacing shifts only).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §3.3 and the Badge row: built; `shell/PATTERNS.md` component list (Badge).

## Hints
- The store's source badges (Official / Community / Dev) map to `success` / `info` / `warning`.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
