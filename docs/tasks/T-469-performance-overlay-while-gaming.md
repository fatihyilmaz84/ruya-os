# T-469 — Performance overlay while gaming, switched on from the Hub

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
Owner, 2026-11-11: "the performance metrics are unusable since the game is frozen. Instead of showing them there, add a toggle to turn them on as an overlay while gaming. Put them in the top corners." The Hub's Performance panel (T-452) reads FPS, frame time, CPU, GPU and the rest while the Hub is open, but opening the Hub freezes the game (T-457), so every number shows a paused game. The numbers belong over the running game.

## Read first
- `02` §1.6 (the Hub, its Performance panel, T-452's Outcome), `04` §3 (tokens), §4 (focus), §5 (the Hub rows), §8 (new components)
- `shell/qml/QuickMenu.qml` (the Performance panel descriptors, the interval row), `shell/src/performance/Performance.cpp` (polling, `frameSource`, states), the compositor's app layer (`shell/compositor/`, `Shell.qml` app items)

## Scope
1. **The panel becomes a switch:** the Performance panel's reading rows go; it keeps two rows: a toggle "Performance overlay" (on/off) and the existing "Update every" interval row. The toggle is stored per profile and survives a restart.
2. **The overlay:** while it is on and a game is in front (not Home, not a shell page), the shell draws the metrics over the game in the **top corners**, inside the safe area: top left the frame numbers (FPS and frame time), top right the system numbers (CPU, GPU, RAM, VRAM, temperatures, power). Each value keeps T-452's states ("Not available on this console", "Measuring...", "(last reading)"), short enough for a corner.
3. **Never in the way:** the overlay takes no focus and no input, is not in the focus chain, and hides while the Hub, a toast stack in that corner, the launch or closing splash, or Home is shown; it comes back when the game is in front again. It updates at the chosen interval only while it is shown (no polling when hidden or off).
4. **Cheap:** plain text on a small opaque scrim, no blur, no shadow, no animation; it redraws only when a number changes. The cost is measured on the Dell (criterion below).
5. **Look:** the corner readout is a new component: write its `04` §5 row (and any token it needs, §8) in this task from existing tokens (text `Theme.text` on an opaque surface, 4.5:1; the type sizes of the Hub's reading rows); the lead approves it at review.

## Out of scope
- Tuning controls (07 §5.3), a graph or history, per-game overlay settings, a keyboard shortcut for the toggle (T-456's area).

## Acceptance criteria
- [ ] The Hub's Performance panel shows the toggle and the interval row, no readings; the toggle persists per profile (tests)
- [ ] Overlay on + a game in front: both corners show their metrics in every state (one test per state, mock); off, or Home, or the Hub open: nothing drawn and no polling (tests)
- [ ] The overlay never takes focus or a key press (test: the game's keys still reach it)
- [ ] `shots` of the overlay over a stand-in game, both corners, reviewed against `04` §8
- [ ] Dell (lead run): FPS of SuperTuxKart with the overlay on vs off, within 2 %; `Verified: host (hw pending: Dell FPS)`
- [ ] UX: `UX notes:` line; `dev.ps1 test` ALL GREEN

## Hints
- Planned by lead-11 from the owner's words. T-452 merged the panel; `Performance.cpp` already gates polling on the panel being open and marks held numbers unavailable: move that gate to "overlay shown". T-455 (Hub budgets) measures the Hub, not this overlay.

## Outcome
Verified: host (hw pending: Dell FPS of SuperTuxKart, overlay on vs off, within 2 %)

UX notes: states reached: the Hub's Performance panel is two rows (the Performance overlay toggle, Update every); Accept on the toggle flips On/Off and the focus stays on it (hint "A Toggle, B Back"); Back leaves the panel to the Hub on the Performance entry, Back again resumes the game, as before. Over a game with the switch on: both corners drawn; they hide (not fade) under the Hub, the launch and closing splash, Home and the saver, and come back when the game is in front; a toast (warning or error: the only kinds drawn over a game) hides the right block while the left stays. Focus never moves: the overlay is disabled and not focusable; the stand-in game keeps every key (Accept, Back, Left, Tab, a letter). What I doubted: (1) "per profile" has no existing store (DeviceSettings is per device), so the switch is a map of profile id to true inside DeviceSettings (`hub/performanceOverlay/<id>`); (2) the right block is up to seven lines of `typeCaption`, "VRAM: Not available on this console" is its longest line (about 40 characters, a third of the width at 1080p), which the lead should judge in the shots; (3) the toast stack hides only the right block, my reading of "a toast stack in that corner".

What was built:
- `DeviceSettings.performanceOverlayProfiles` / `performanceOverlay(profile)` / `setPerformanceOverlay(profile, on)`: per profile, off by default, stored under `hub/performanceOverlay/<profile id>`, only plain ids (`[A-Za-z0-9._-]{1,64}`) accepted.
- `PerformanceReadout.qml` (new, in `Shell.qml` at z 7): the two corner blocks, opaque `Theme.panel` scrim, `typeCaption` DemiBold `text`, no blur, shadow or animation; the words and states moved here from QuickMenu (labels now "CPU: 24 %", frames "60 FPS" and "17 ms, slowest 17 ms"). It holds the `PerformanceConsumer`, so the service is asked and frames counted only while it is shown; `Shell.qml` computes `shown` (switch for the signed-in profile, `appOpen` with a focused app, not the Hub, `launching`, `closingScreen`, `IdleClock.covered`) and `rightBlocked` (a toast).
- `QuickMenu.qml`: the Performance panel is `performance:overlay` (toggle) and `performance:interval`; the reading rows, their helpers and the panel's `PerformanceConsumer` are gone.
- Specs: `02` §1.6 Performance bullet rewritten, `04` §5 new row "Performance readout" (no new token), the Quick menu row's mention of readings corrected. Translations refreshed (tr entries for the six new strings).

Tests: new `tst_perf_overlay.qml` (19: persistence through `tst_main.cpp`'s `checkOverlayPersistence`, off, on in both corners and in the safe area, Home, Hub, splashes, toast, interval and consumers, every state, no focus/no key, screenshots). `tst_hub_performance.qml` now has 8 tests. **Moved or removed from `tst_hub_performance.qml` (their subject left the panel):** the reading-state tests (measured value, unsupported, measuring, frames measuring, no game in front, stale, 60 FPS, held numbers, first open after idle) are rewritten in `tst_perf_overlay.qml` against the overlay; `test_polling_starts_when_the_panel_opens...` and `test_the_frames_are_counted_only_while_the_panel_is_open` are replaced by `test_the_panel_has_the_switch_and_the_interval_and_no_readings` (the panel asks for nothing) and the overlay's Hub/Home/off tests; `test_the_readings_take_focus_but_accept_does_nothing` is gone (no reading rows). Revert checks (each undone, test fails, restored): `!systemPanel.open` in Shell.qml (the Hub test); `shown && !rightBlocked` (the toast test); `enabled: false` in PerformanceReadout (no-focus test); `setValue(key, true)` in DeviceSettings (the persistence test); the toggle writing to "p1" instead of the active profile (`test_the_switch_is_stored_for_the_profile`).

Deviations: info toasts wait in the queue while a game is in front (`Notifications.appInFront`), so the toast test and shot use a warning. The game-in-front test stand-ins set `launchState` / `closeState` directly for the splash states.

Round 2 (review): `docs/developers/fullscreen-and-lifecycle.md` now names the overlay; the stale focus sentence in `02` §1.6 is fixed; a deleted profile loses its overlay switch (`Shell.qml` clears it on `Profiles.deleteFinished` "ok"; test `test_a_deleted_profile_loses_its_switch`, revert check: removing the `setPerformanceOverlay(id, false)` line fails it); the 04 §5 row has the width rule and 04 §7 names the `text` on `panel` pair, which `tst_theme_contrast.qml` already measures ("text on panel").
