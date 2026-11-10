# T-434 - Glass follow-ups: Performance-tier rows opaque, the picker's idle blur texture, the page blur's GPU cost

Status: in-progress · Phase: 2 · Depends: — · Area: shell (SettingControl, Backdrop, liquid pills), scripts (dell-glass-check) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
T-421's glass fix keeps its look at a lower GPU cost on the Dell, and the Performance tier follows 04 §3.6 ("glass without blur turns opaque") for the Settings rows too.

## Read first
- `docs/tasks/T-421-glass-has-no-blur-on-the-dell.md` (Outcome: the GPU table, `dell-glass-check.sh`), `docs/specs/04-design-system.md` §3.6, §3.8, principle 5
- `shell/qml/controls/SettingControl.qml`, `shell/qml/Backdrop.qml`, the liquid pill (`LiquidGlass`, `LiquidGate`), `scripts/dell-glass-check.sh`

## Scope
1. **Decided (lead, 2026-11-10):** on the Performance tier the Settings rows (`SettingControl.qml:52`, `Theme.glass` on every tier) use `glassOpaque`, like GlassPill and GlassSheet. Check every other translucent card for the same leak. Then reword the §3.6 sentence "never sits over a sharp blob edge" to match.
2. Backdrop: the blurred copy's live `ShaderEffectSource` is idle off pages (gate on `blurred || pageBlur.opacity > 0`), so the profile picker does not re-render it every frame.
3. The page blur's cost (Settings in active use is about 40 % GPU on the Dell, was 30 %): a smaller texture, or a baked copy while the blobs rest; keep the look (shots before and after).
4. Measure the liquid pills on the Dell (about 25 % GPU for 30 s after each input at Home) and write the number into 04 §3.8's "decide on the Dell" line; do not change the default.
5. `dell-glass-check.sh`: the step 3 comment is stale (the blobs rest after 30 s); add the picker and a Settings-in-use step.

## Out of scope
- New tokens; the Midnight contrast question (T-282).

## Acceptance criteria
- [ ] Item 1: a test that the rows use `glassOpaque` on Performance (red without the change).
- [ ] Item 2: a test that the live texture is off on the picker.
- [ ] hw (the builder may use the Dell): `dell-glass-check.sh` PASS with this branch's shell; GPU at Home still, Settings in use and the picker, before and after, in the Outcome.
- [ ] `dev.ps1 test` and `shots` ALL GREEN; changed shots reviewed (a Performance-tier Settings shot).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §3.6 and §3.8.

## Hints
- From the STATUS Inbox (T-421 and its reviews), planned by lead-9 on 2026-11-10. The Dell is a pure test machine (root `CLAUDE.md`); run a branch shell as T-421 did (its Outcome).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
