# T-376 - The shell draws and plays nothing behind a full-screen app

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Shell.qml, Backdrop, WallpaperLayer, AmbientLoop) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
A game gets the GPU the shell does not need. On the Dell (0.0.58, lead-7, STK full-screen) the GPU was saturated (RC6 idle 3 %, clock at 1150 MHz): the game used about 96 % of the render engine and **the shell about 8.8 %**, because the L0 backdrop (full-screen gradient plus three alpha-blended circles, about 3.6 screen fills per frame) is drawn behind the opaque app every frame: `Shell.qml` (~line 552) bases `Backdrop.shown` on wallpaper and saver only, and T-293's `paused` stops the drift but keeps the item visible. The ambient bed's `pauseLoop()` (`MediaPlayer.pause()`) also leaves a silent 24 kHz PipeWire stream running (about 4 % CPU in QPulseAudioEngine and QFFmpeg::AudioRenderer, 95 wakeups/s each).

## Read first
- `docs/specs/02-shell.md` (power saving, layers L0-L3), `docs/specs/04-design-system.md` §2 (backdrop), §8; `shell/CLAUDE.md`
- `shell/qml/Shell.qml` (`l0`, `Backdrop`, `WallpaperLayer`, `heroArt`, `appLayer`, `focusedApp`, `appOpen`), `shell/qml/AmbientLoop.qml`, `shell/tests/tst_power_saving.qml`, `tst_motion.qml`, the ambient tests

## Scope
1. While an app is in front (`focusedApp !== null`, and while it is shown under the Guide overlay or system panel), L0 is not visible: the backdrop, the wallpaper layer and the hero art. Check that no Glass/MultiEffect samples `l0` in that state (the overlay draws over the app texture). Coming back to Home shows L0 again without a flash (Home's fade covers it).
2. The ambient bed **stops** (both voices; the audio output closes) instead of pausing while an app is in front, and starts again on return (`startLoop()`); the bed's position may restart.
3. The log line `ShaderEffect: Texture t7 is not assigned a valid texture provider` right after a game takes the focus: find the effect whose source went away and give it a valid source or disable it in that state.

## Out of scope
- Direct scanout of the app buffer (B-003), the compositor's GL composite cost.

## Acceptance criteria
- [ ] QML tests: `test_l0_is_hidden_behind_a_focused_app` (backdrop, wallpaper layer and hero art `visible === false` with an app focused, also with the Guide overlay open; visible again after the app closes), `test_ambient_bed_stops_under_an_app_and_restarts` (the players' `playbackState` is Stopped, not Paused), `test_no_effect_samples_a_hidden_layer` (the effect from Scope 3); each red when its fix is reverted.
- [ ] Screenshots: Home after closing an app (no flash, the backdrop is back); the Guide overlay over an app.
- [ ] VM (lead run): `vm-sounds-check.sh` (or `vm-session-check.sh display`) asserts that with the test app in front no running PipeWire output stream of `ruya-shell` exists (`pw-dump`); Outcome `Verified: host (vm pending: <check>)`. hw (lead, Dell): the shell's GPU share with STK in front (fdinfo `drm-engine-render`), before 8.8 %.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02` power saving (what stops behind an app).

## Outcome
_Filled in by the implementer._
