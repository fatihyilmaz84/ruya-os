# T-430 - GlassShadow and AppArt masks: the T-387 layer-toggle class, and L0's memory behind an app

Status: todo · Phase: 2 · Depends: T-421 · Area: shell (GlassShadow, AppArt, L0) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
No other mask in the shell can go blank the way GlassSheet's did (T-387), and keeping the Home layer alive behind a game costs a known, acceptable amount of video memory.

## Read first
- `docs/tasks/T-387-*.md` (the mask-layer toggle under an unchanged `maskSource`; `test_zz_sheet_after_an_app`) and T-421's Outcome (fold its findings in first: it may already cover part of this)
- `shell/qml/GlassShadow.qml` (`box`, `cutout`), `shell/qml/AppArt.qml` (`imageMask`), the L0 layer hidden by opacity 0 (T-376, T-387), `docs/specs/04-design-system.md` §3.6

## Scope
1. Check `GlassShadow` (`box`/`cutout`) and `AppArt` (`imageMask`) for the same toggle; fix where it applies.
2. A `shots` pixel case like `test_zz_sheet_after_an_app` for each fixed mask (red without the fix on the host GPU).
3. Measure on the Dell the VRAM that L0's layers hold behind an app (opacity 0, not `visible: false`), with and without a game; if it is above about 64 MB on the UHD 630, propose and build a cheaper hold (release the layers after N seconds behind an app, keep the first frame on return).
4. A light thumbnail weakens the white focus ring: measure the ring's contrast over the lightest picker art; if under 3:1, file a `design:` Inbox line for the lead (T-282), do not change tokens.

## Out of scope
- Blur over a client surface (B-003).

## Acceptance criteria
- [ ] Each fix has a `shots` case red without it; or the Outcome shows (with a probe) that the class does not apply.
- [ ] hw (the builder may use the Dell): L0 VRAM behind an app measured and in the Outcome; the decision from item 3 stated.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §3.6 if L0's hold changes.

## Hints
- Evidence from T-421 (lead-9): the Dell logs "ShaderEffect: Texture t7 is not assigned a valid texture provider" on every app focus change, from GlassShadow's `layer.enabled: shadow.visible` on `box`/`cutout` with an unchanged `maskSource`.
- From the STATUS Inbox (T-387 reviews, lead-8), triaged by lead-9 on 2026-11-10. The Dell is a pure test machine (root `CLAUDE.md`).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
