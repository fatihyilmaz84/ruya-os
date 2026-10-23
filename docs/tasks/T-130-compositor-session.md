# T-130 — Compositor session: `ruya-shell` replaces cage as the compositor (ADR-002 A)

Status: todo · Phase: 1 · Depends: T-123 · Area: shell, image · Size: M · Owner: lead

## Goal
The image boots straight into `ruya-shell` as the Wayland compositor on KMS (no cage), and the shell has a proper place for app windows: apps show fullscreen under the shell's overlay, Guide always reaches the shell, and every other key goes to the focused app. This is the product version of the T-123 spike; per-profile sockets and launching apps (`ruya-session`) come after it.

## Read first
- `docs/specs/00-overview.md` ADR-002 (accepted A, with the spike's product-path findings), ADR-003 (input routing; InputPlumber later), ADR-004 (per-profile sockets, later)
- `docs/tasks/T-123-compositor-spike.md` Outcome (what worked, the pitfalls: `surfaceDestroyed` handler context, llvmpipe needs shm clients, `input` is an altfiles group on bootc, ACL clean-up)
- `shell/spike/Compositor.qml`, `scripts/vm-compositor-spike.sh`, `image/rootfs/usr/lib/systemd/system/ruya-compositor{,-spike}@.service`
- `shell/qml/Shell.qml` (Guide handling, `systemPanel`, `focusCurrent`), `shell/qml/Main.qml`, `shell/src/main.cpp`
- `docs/specs/01-platform.md` §2.1 (startup chain), §8 (Phase 0 checklist the image must keep passing)

## Scope
1. **Layers inside the shell, testable on Windows.** `Shell` gets an app layer between its home/pages and its overlay layers (toasts, modals, Guide overlay, volume OSD stay above apps). The Shell exposes what a compositor needs: where to put an app item, which app item is focused, and "the overlay closed, give focus back". No QtWayland import in the `RuyaShell` module (the Windows kit has no QtWaylandCompositor).
2. **Key routing in C++.** A small `KeyRouter` (or an event filter on the window) decides per key event: Guide keys (`Shell.isGuideKey`, including modifier-only Super and the Guide hold for the power choices) and the volume keys always go to the shell; everything else goes to the focused app item when one has focus. Remove the QML `Keys` hack of the spike.
3. **Compositor part, Linux only.** The `WaylandCompositor` + xdg-shell wiring (from the spike, cleaned up) in a file or module built only when QtWaylandCompositor is found (CMake option, on in the image build). `Main.qml` stays the window for the Windows host and the tests; the Linux entry point uses the compositor. Keep `ruya-shell: ready` and `--windowed` behaviour on Windows unchanged.
4. **Session and devices (image).** `ruya-compositor@.service` runs `ruya-shell` on eglfs_kms instead of cage. Decide and record how the shell opens input devices: a permanent `uaccess` rule (the shell user then reads every input device; it is the session's only UI) or logind-based device opening; the spike's temporary rule shows the first works. Remove `cage` from `20-base.sh` only if nothing else needs it (keep it if a fallback session is wanted; say which). Retire `ruya-compositor-spike@.service`, the inert rule and `vm-compositor-spike.sh` (or keep the script as the test-client launcher; say which).
5. **A test client in the VM.** Keep a way to start a Wayland test client as `ruya-shell` (the spike's `KeyClient.qml` via `--load` is fine) so the VM check below can be repeated.

## Out of scope
- Launching apps from tiles, per-profile Wayland/PipeWire sockets, `ruya-session` (next task).
- Blur over app surfaces, gamescope nesting, Xwayland, HDR/VRR, display mode switching.
- InputPlumber (ADR-003, B-006); `ruya-inputd` keeps emitting keys.

## Acceptance criteria
- [ ] Host tests (`tst_compositor_layers.qml` or similar, with a stand-in app item that records keys): with an app item focused, arrows and letters reach the item; Guide opens the overlay and nothing reaches the item while it is open; closing it returns focus to the item; a held Guide opens the power choices; the volume keys reach `Audio`; removing the app item gives focus back to the home tiles.
- [ ] VM, fresh disk of the new image: `RUYA_BOOT_OK` with no cage process (`pgrep cage` empty), the first-boot wizard drawn by `ruya-shell` on KMS (VM screenshot).
- [ ] VM: the T-123 sequence passes on the default session (test client keys, Guide overlay over it, keys while open not delivered, keys back after close, client exit) — log and screenshots in the Outcome.
- [ ] VM: the profile flows of T-120 still work (wizard creates the admin over the real bus; reboot; picker), spot-checked by keys and screenshots.
- [ ] The update/rollback drill still passes (`docs/dev-setup.md`): the health check sees `ruya-shell: ready` from the compositor; greenboot's automatic rollback from a broken compositor still triggers.
- [ ] `dev.ps1 test` ALL GREEN; `dev.ps1 shots` reviewed for any changed screen.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
# WSL: scripts/build.sh, make-disk.sh qcow2; then
.\scripts\smoke-test.ps1
```
Plus the VM checks above and the update/rollback drill.

## Docs to update
- `docs/specs/01-platform.md` §2.1 (startup chain without cage), §1 package table (the compositor row); `docs/specs/02-shell.md` (layers, key routing); `docs/specs/00-overview.md` ADR-002 (product path done, performance still open); `shell/CLAUDE.md` (where app items live, the key router, the Linux-only compositor part); `docs/dev-setup.md` (VM test client); STATUS B-003.

## Hints
- In the VM, clients must render in software (`QT_QUICK_BACKEND=software`): llvmpipe has no `EGL_WL_bind_wayland_display`.
- Connect a surface item's `surfaceDestroyed` from the compositor's scope, not as a handler inside the delegate (T-123: the handler ran with a dead context).
- `input` is an altfiles group on bootc, so `usermod -aG input` does nothing; logind does not remove an ACL when a device loses its `uaccess` tag.
- A fresh disk copy has new SSH host keys: use the batch SSH options in `docs/dev-setup.md`.
- Split the work into a host-tested commit (layers, key router) and an image commit if that keeps each reviewable.
- Start-up order changes here (no cage; `ruya-devices` is a user unit that starts after the shell). Check the boot journal for the `QSoundEffect ... not supported` lines of T-121; if they appear, defer `Sfx` loading until `Audio` reports a default sink (the item was dropped from T-128's Inbox for this reason).

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
