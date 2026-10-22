# T-102 — Reduced motion and effects quality tiers

Status: todo · Phase: 1 · Depends: — · Area: shell · Size: M

## Goal
The shell honours two device settings from the spec. **Reduced motion** makes durations zero or near-zero and removes ambient movement. **Effects quality** (High/Balanced/Performance) scales the blur and backdrop animation, so low-end hardware stays smooth.

## Read first
- `docs/specs/02-shell.md` §3.2, §3.3, §7 (accessibility)
- `shell/qml/Theme.qml`, `Backdrop.qml`, `Shell.qml` (shelf `MultiEffect`)
- `shell/src/profiles/` (pattern for a C++ singleton)

## Scope
1. Add a C++ singleton `DeviceSettings` (`src/settings/`, `QML_ELEMENT QML_SINGLETON`) with:
   - `bool reducedMotion` (default false);
   - `string effectsQuality`: `"high" | "balanced" | "performance"`, default `"high"`;
   - `real overscan`: safe-area fraction 0.0–0.10, default 0.05.
   It persists with `QSettings` (organisation `ruyaos`, application `shell`). In tests, setting the env var `RUYA_SETTINGS_EPHEMERAL=1` keeps values in memory only. Invalid values are rejected and leave the old value.
   - These are **per device**, not per profile; per-profile settings come later via a service.
2. `Theme.qml`:
   - Durations become reduced-motion aware. `focusMs`, `pageMs` and `tintMs` evaluate to 0 when `DeviceSettings.reducedMotion`. Use 0 for movement; a crossfade may keep ≤ 60 ms if the spec says so.
   - Add `blurMax` per tier: high 64, balanced 32, performance 0.
   - `safeArea` reads `DeviceSettings.overscan`.
3. `Backdrop.qml`: the blob drift animations stop (`running: false`) with reduced motion or in `performance`.
4. Shell shelf: when `blurMax` is 0, the `MultiEffect` is disabled (`visible: false`) and the glass panel becomes more opaque (a token), so text stays readable.
5. `--reduced-motion` and `--effects <tier>` command-line flags in `main.cpp` override the settings for the session (useful for perf testing). Don't persist them.

## Out of scope
- The Settings UI to change these (T-103 builds the controls and wires them).
- Automatic tier detection from a GPU benchmark (later; needs real hardware).

## Acceptance criteria
- [ ] With `DeviceSettings.reducedMotion = true`, `Theme.focusMs`, `Theme.pageMs` and `Theme.tintMs` are 0, and backdrop animations are not running (test `tst_motion.qml::test_reduced_motion`).
- [ ] Setting `effectsQuality` to `"performance"` hides the shelf `MultiEffect`; `"balanced"` gives `blurMax` 32 (test `test_quality_tiers`).
- [ ] Invalid `effectsQuality` and out-of-range `overscan` are ignored (test `test_invalid_values_rejected`).
- [ ] Changing `overscan` moves the header (`brand.x` changes) (test `test_overscan_moves_header`).
- [ ] Screenshot `6-performance-tier.png` shows home in the performance tier: readable, with no blur.
- [ ] All existing tests pass.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
.\scripts\dev.ps1 build; shell\build-win\Release\ruya-shell.exe --windowed --effects performance --reduced-motion
```
(The last line is a manual look. Qt's bin must be on PATH, which `dev.ps1 run` sets up.)

## Docs to update
- `docs/specs/02-shell.md` §3.3: the actual token values per tier; note that auto-detection is still open.
- `docs/dev-setup.md`: document the new flags.

## Hints
- In tests, set `DeviceSettings` properties directly and restore defaults in `cleanup()`. `tst_main.cpp` should set `RUYA_SETTINGS_EPHEMERAL=1`.
- `Behavior { NumberAnimation { duration: 0 } }` still animates through one frame. If a test needs immediate values, use `tryCompare`.

## Outcome
_Filled in by the implementer._
