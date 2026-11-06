# T-235 — Design step: components for the package page and the install flow

Status: todo · Phase: 7 · Depends: T-228 · Area: shell, docs · Size: M · Owner: lead

## Goal
`04-design-system.md` gets the components T-236 needs, designed and built once, so the UI task does not improvise (PLANNING.md quality bar). Lead task: it changes the design system.

## Read first
- `docs/specs/04-design-system.md` §3 to §8 (tokens, components, focus, copy), `docs/specs/05-play-packages.md` §5, §8, §9.2, §12
- `shell/qml/` existing `AppDetailPage.qml`, `ArtCard.qml`, `AppArt.qml`, permissions list, `StorePage.qml`

## Scope
Design (canvas boards in 04 style), spec text and a first build of:
1. **Trust badge** (`Official`, `Signed by <name>`, `Unverified`, `Changed since signed`, `Removed for safety`): wording per 05 §0 (honest), colours from existing tokens only; warning/error use the existing semantic colours.
2. **Permission row** with a risk marker (reuse the Store's), and the "reasons" line.
3. **Screenshot gallery** (focusable strip, full-screen view) and **trailer player** control set (play/pause/seek by controller; the hint bar shows the buttons).
4. **Signer block** (name, fingerprint grouped in four-character blocks, first-seen date, key state) readable at 10 feet.
5. **Install flow screens**: source list, confirm sheet (art, size, permissions, trust, update-check opt-in), progress (phases: Checking, Copying, Preparing), result (success, each failure status with a fixable sentence).
6. Copy for every status of the `Play1` contract, in English and Turkish, in the style of 04 §7.

## Out of scope
- Wiring to the service (T-236), the Home hero and preview loop (T-242).

## Acceptance criteria
- [ ] `04` §5 lists each new component with its tokens; `Theme.qml` and the spec change together; `lint-tokens.ps1` passes.
- [ ] Each component has a test of its geometry and focus behaviour with the sizes a real caller sets (`tst_playcomponents.qml`); the gallery and trailer are reachable and leavable by controller only.
- [ ] Contrast of badge text on glass meets 04 §7 (computed in the test, not by eye) for every state.
- [ ] Screenshots of each component in English and Turkish reviewed against 04 §8 (`dev.ps1 shots`).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Outcome
_Filled in by the implementer._
