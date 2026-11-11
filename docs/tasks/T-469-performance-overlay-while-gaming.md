# T-469 — Performance overlay while gaming, switched on from the Hub

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

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
_Filled in by the implementer._
