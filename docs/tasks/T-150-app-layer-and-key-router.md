# T-150 — App layer and key router in the shell (host half of T-130)

Status: done · Phase: 1 · Depends: T-123 · Area: shell · Size: M

## Goal
The shell has a proper place for app windows and decides in C++ which keys reach an app: apps sit under the shell's overlays, Guide and the volume keys always reach the shell, every other key goes to the focused app. All of it is tested on Windows with a stand-in app item; the Wayland compositor that fills the layer with real windows is T-130 (lead, image).

## Read first
- `docs/specs/00-overview.md` ADR-002 (accepted A) and ADR-003 (input routing); `docs/specs/02-shell.md` §1.5 (full-screen apps), §4 (focus, Guide)
- `docs/tasks/T-123-compositor-spike.md` Outcome and `shell/spike/Compositor.qml` (the QML `Keys` hack this replaces)
- `shell/qml/Shell.qml` (Guide handling, `isGuideKey`, Guide hold, `systemPanel`, `focusCurrent`), `shell/qml/Main.qml`, `shell/src/main.cpp`
- `shell/CLAUDE.md`, `shell/PATTERNS.md`

## Scope
1. **App layer.** `Shell` gets an app layer between home/pages and the overlay layers (toasts, modals, Guide overlay, volume OSD stay above it). Shell API for a compositor: add an app item to the layer, which app item is focused, and "the overlay closed, give focus back". When the last app item goes, focus returns to the home tiles. No QtWayland import anywhere in the `RuyaShell` module.
2. **Key router in C++.** A `KeyRouter` (an event filter on the window, registered for QML) decides per key event: Guide keys (including modifier-only Super and the Guide hold that opens the power choices) and the volume keys always go to the shell; everything else goes to the focused app item when an app item has focus. The Guide-key decision stays in one place (move `isGuideKey`'s rule to C++ and keep the QML name as a thin call, or the reverse; don't duplicate it).
3. A stand-in app item for tests (QML, in the test directory or a test-only file) that records the keys it receives.

## Out of scope
- `WaylandCompositor`, xdg-shell, the Linux entry point, the systemd unit, cage removal (T-130).
- Launching apps, the launch splash and quick menu (T-147), per-profile sockets.

## Acceptance criteria
- [ ] `tst_compositor_layers.qml` (with the stand-in app item): with an app item focused, arrows and letters reach it (`test_keys_reach_app`); Guide opens the overlay and nothing reaches the item while it is open (`test_guide_blocks_app`); closing the overlay returns focus to the item (`test_focus_back_after_overlay`); a held Guide opens the power choices (`test_guide_hold`); the volume keys reach `Audio` and not the item (`test_volume_keys`); removing the item gives focus back to the home tiles (`test_app_removed`).
- [ ] Toasts and the volume OSD draw above the app layer (test on `z` order or item parenting).
- [ ] Existing Guide, overlay and power tests pass unchanged; `dev.ps1 test` ALL GREEN; `dev.ps1 shots` ALL GREEN (no screen should change).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` (layers, key routing); `shell/CLAUDE.md` (where app items live, the key router; keep the file within its 7 KB budget: move detail to `PATTERNS.md`).

## Hints
- `shell/CLAUDE.md` sits at its size budget: if you add a rule, merge or move one.
- An event filter installed on the `QQuickWindow` sees key events before the focused item; re-sending to a specific item is `QCoreApplication::sendEvent(item, event)`.
- Keep `ruya-shell: ready` and `--windowed` behaviour unchanged.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN, 187 QML tests offscreen). `dev.ps1 shots` could not be judged here: on real windows 8 timer-based tests fail (Power Guide hold, toast queue, OSD hide, lockout, picker fade); the same 6 of them fail on the untouched baseline (stash check), so it is the desktop session, not this change. No screen was meant to change (the app layer is invisible with no app); screenshots not reviewed.

Built:
- `src/input/KeyRouter` (C++, `QML_ELEMENT`, instantiated in `Shell`): event filter on the window. While `appItem` has active focus it takes the Guide keys (press and release, incl. Super/Meta and auto-repeat flag) and emits `guidePressed/guideReleased`; everything else is untouched. `KeyRouter.isGuideKey` is now the single definition; `Shell.isGuideKey` is a thin call to it. Shell's Guide logic became `guideDown/guideUp`, shared by the router and the ordinary `Keys` handlers (overlay, pages, tiles behave exactly as before).
- `Shell`: `appLayer` (z 5, above home/pages, below toasts z 10, modals 15, overlay 20, OSD 30), `addApp/focusApp/removeApp`, `focusedApp`, `appOpen`; `focusCurrent()` prefers the focused app, so closing the overlay returns focus to it and removing the last app returns to the page or tiles. Home and pageHost are disabled while an app is open. Destroyed items are detected through a guard child per item.
- `tests/tst_compositor_layers.qml` with a stand-in app: all six named tests plus a z-order test.
- Docs: spec 02 §1.5/§4.1, `shell/PATTERNS.md`, `shell/CLAUDE.md` (stays about 7.2 KB, as before).

Deviations: "everything else goes to the focused app" is plain focus delivery, no `sendEvent` re-sending (a Wayland compositor surface item gets keys through focus anyway; T-130 can add forwarding if it needs it). Volume keys remain the existing application `Shortcut`s, which already win before any key event.
Pitfall found: a destroyed QML item must not be touched from JS (any use throws), and `var` properties copy JS objects, so records are matched by id.
