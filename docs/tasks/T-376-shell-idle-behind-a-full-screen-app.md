# T-376 - The shell draws and plays nothing behind a full-screen app

Status: done · Phase: 2 · Depends: — · Area: shell (Shell.qml, Backdrop, WallpaperLayer, AmbientLoop) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: vm (0.0.60, lead-8: `vm-session-check.sh display` ALL CHECKS PASSED; the check counts running streams, as the criterion says: 0.0.60 keeps one idle ruya-shell node) + hw pending (Dell look-at list)

UX notes: no new state; Back/focus unchanged (an app in front keeps the focus; closing it gives Home's Play button the focus, asserted). Screenshots read: `guide-over-app.png` (the panel over the app area, which is empty in the test, so just the scrim colour) and `home-after-app.png` (backdrop, hero art and glass pills all back). Not judged: a flash on real hardware, since offscreen/`shots` cannot show one frame; Home's own fade (`home.opacity`) covers L0 coming back as before.

What was built
1. `Shell.qml`: `l0.visible = !root.appOpen`, so the backdrop, the wallpaper layer and the hero art are all not visible (and draw nothing) while an app is in front, also under the Guide overlay. The status cluster (`statusGlass`) fades out with an app (`Theme.pageMs`, `easeSnap`, like the nav; round 2) and is not visible once settled: it is under the app layer anyway and its glass (`GlassPill` crop plus `LiquidGlass`'s live `ShaderEffectSource`) sampled `l0`. SectionNav already hides when an app is open. The Guide panel is opaque and the pickers' `GlassSheet`s only open from pages, so nothing else samples `l0` behind an app.
2. `AmbientLoop.qml`: `pauseLoop()` became `stopLoop()` (stops both players, the cross-fade, resets `current`/`blend`, counts `stopCount`). It runs whenever the bed has faded out (an app, the saver, the dark screen), so the PipeWire output closes in all those cases; `onPlayingChanged` already restarts a stopped player with `startLoop()`. The bed's position restarts from the loop start on return.
3. The log line `Texture t7 is not assigned a valid texture provider`: **not reproduced on the host**. The likely source is the status pill's glass (`LiquidGlass.blurred` / the pill crop) keeping a live source on L0 while it is behind an app; it is now hidden then. To be confirmed on the Dell: look for the line after a game takes the focus.

Tests (all in `shell/tests/tst_sound_ui.qml`): `test_l0_is_hidden_behind_a_focused_app`, `test_ambient_bed_stops_under_an_app_and_restarts` (players `StoppedState`, `stopCount`; in the offscreen dry run players have no file, so Stopped alone could not tell stop from pause, the counter does), `test_no_effect_samples_a_hidden_layer` (the pill that blurs `l0` and the nav are not visible behind an app once their fade has settled), and `test_zz_screenshots_app`.
Revert checks (`revert-check.ps1 -Test tst_sound_ui`): `l0.visible` back to `true` -> `test_l0_is_hidden...` and `test_no_effect...` red; `statusGlass` visible without `!appOpen` -> `test_no_effect...` red; `stopLoop()` call replaced by a pause -> `test_ambient_bed_stops...` red.

VM (lead run): `scripts/vm-session-check.sh display` now, with the test app's window in front, waits 4 s and asserts that `pw-dump` shows no `Stream/Output/Audio` node of `ruya-shell` (round 2: `pw-dump` is run as `ruya-shell` and parsed with `python3 -I`, no `jq`; a pw-dump or parse failure is a FAIL, never a skip). Not run here. hw (lead, Dell): the shell's GPU share with STK in front is still to be measured (before: 8.8 %).

Checks: `dev.ps1 test` ALL GREEN (1010 QML passed, 79 skipped, Rust green; re-run in round 2); `shots` ALL GREEN in round 1 (158 passed; main's three red shots were green on this run), not re-run in round 2 (no screenshot content changes: the pill is fully opaque when shown).

Files: shell/qml/Shell.qml, shell/qml/AmbientLoop.qml, shell/tests/tst_sound_ui.qml, scripts/vm-session-check.sh, docs/specs/02-shell.md (1.4a "Behind an app", 5.3 ambient bed).
