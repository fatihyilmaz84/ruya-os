# T-143 — Design tokens v2: spacing, radius, sizes, and the Badge component

Status: done · Phase: 2 · Depends: T-142 · Area: shell · Size: M

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
Verified: host (`dev.ps1 test` ALL GREEN, 178 QML; `shots` ALL GREEN, picker, home, Settings, power confirm reviewed).

Built: spacing, radius and size tokens, `badgeFillAlpha` and `Theme.badgeFill()` in `Theme.qml`; `qml/Badge.qml` (in CMake) used for the PIN badge and the "mock services" flag; `tst_theme::test_space_shape`, `tst_badge.qml`. About 70 literals in 19 QML files became tokens (spacing, margins, radii, focus-ring width/offset, row/button/tile/avatar sizes).

Nearest-token shifts (design px): spacing 10 -> 8, 14/18/20 -> 16, 22/28/30 -> 24, 32/40 -> 36, 60/80 -> 64, 90/120 -> 96; radius 16 -> 12 (keys), 20 -> 18 (toast, text entry field); dialog buttons 84 -> `buttonHeight` 76. Neutral badge has a `background` fill (spec: outline only) because on the avatar ring a transparent one was unreadable. The "mock services" flag is now a warning Badge (caps, pill). Setup's `topMargin: 200` became 2 x `spaceXxxl` (192). Left as literals: `1` hairline borders (`Math.max(1, u)`, no token), the Setup keycap/`SettingsPage` swatch sizes and other widths that match no token.
