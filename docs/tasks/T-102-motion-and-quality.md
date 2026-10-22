# T-102 — Reduced motion and effects quality tiers

Status: done · Phase: 1 · Depends: — · Area: shell · Size: M

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
- [x] With `DeviceSettings.reducedMotion = true`, `Theme.focusMs`, `Theme.pageMs` and `Theme.tintMs` are 0, and backdrop animations are not running (test `tst_motion.qml::test_reduced_motion`).
- [x] Setting `effectsQuality` to `"performance"` hides the shelf `MultiEffect`; `"balanced"` gives `blurMax` 32 (test `test_quality_tiers`).
- [x] Invalid `effectsQuality` and out-of-range `overscan` are ignored (test `test_invalid_values_rejected`).
- [x] Changing `overscan` moves the header (`brand.x` changes) (test `test_overscan_moves_header`).
- [x] Screenshot `6-performance-tier.png` shows home in the performance tier: readable, with no blur.
- [x] All existing tests pass.

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
Built the per-device display settings and made the shell follow them.

- `shell/src/settings/DeviceSettings.{h,cpp}`: `QML_ELEMENT QML_SINGLETON` with `reducedMotion`, `effectsQuality` (`high|balanced|performance`) and `overscan` (0.0 to 0.10). Persisted in `QSettings("ruyaos","shell")`; `RUYA_SETTINGS_EPHEMERAL=1` keeps values in memory (set in `tst_main.cpp`). Invalid values are rejected with a `qWarning` and leave the old value. Stored values that are invalid on load fall back to the defaults.
- `Theme.qml`: `focusMs`, `pageMs`, `tintMs` are 0 under reduced motion; `pageSlide` is 0 too (movement removed). New tokens: `blurMax` (64/32/0), `glassOpaque`, `ambientMotion`, `reducedMotion`. `safeArea` reads `DeviceSettings.overscan`.
- `Backdrop.qml`: blob animations `running: Theme.ambientMotion`; new `drifting` property (true while any blob animates) so tests can observe it.
- `Shell.qml`: shelf `MultiEffect` (`objectName: "shelfBlur"`) is hidden at `blurMax` 0 and the panel switches to `glassOpaque`. Added `objectName`s `backdrop` and `brand`.
- `main.cpp`: `--reduced-motion` and `--effects <tier>` set `RUYA_FORCE_REDUCED_MOTION` / `RUYA_FORCE_EFFECTS`; `DeviceSettings` holds them as session-only overrides that win over stored values and are never written. An invalid `--effects` value is ignored with a warning.
- `tests/tst_motion.qml`: `test_defaults`, `test_reduced_motion` (also drives open/close of a page with 0 durations), `test_quality_tiers`, `test_invalid_values_rejected`, `test_overscan_moves_header`, `test_zz_screenshots` (`6-performance-tier.png`).
- Docs: `02-shell.md` §3.2/§3.3, `dev-setup.md`.

Verification: `dev.ps1 test` → ALL GREEN (30 passed, 3 screenshot tests skipped without `RUYA_SHOTS_DIR`); `dev.ps1 shots` → 33 passed. `6-performance-tier.png` reviewed: no blur, opaque shelf, text and focus ring readable. Smoke-ran `ruya-shell.exe --windowed --effects performance --reduced-motion` and `--effects bogus`: both start and print `ruya-shell: ready` (the bogus-value warning goes to the debug channel, so it did not show on the console on Windows).

Deviations and notes:
- Reduced motion uses 0 everywhere, no 60 ms crossfades (the task allowed either).
- The PIN-pad shake and tile pulse (`Tile`, `PinPad`) use literal durations and are not tied to reduced motion. They are feedback animations; left alone to stay in scope. Worth folding into T-103 or a later pass if reduced motion should cover them.
- The screenshot test waits 500 ms after switching, because a sign-in fade started at the old duration is still running and shows a ghost of the picker otherwise. That is a test artifact, not a product bug.
- The first build after adding the singleton gave "DeviceSettings is not defined" in the tests; a second `dev.ps1 shell` run was green with no changes (stale registration in the incremental build). Not reproduced since.
