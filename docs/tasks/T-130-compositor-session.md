# T-130 — Compositor session: `ruya-shell` replaces cage as the compositor (ADR-002 A)

Status: done · Phase: 1 · Depends: T-150 · Area: shell, image · Size: M · Owner: lead

## Goal
The image boots straight into `ruya-shell` as the Wayland compositor on KMS (no cage), and the shell has a proper place for app windows: apps show fullscreen under the shell's overlay, Guide always reaches the shell, and every other key goes to the focused app. This is the product version of the T-123 spike; per-profile sockets and launching apps (`ruya-session`) come after it.

## Read first
- `docs/specs/00-overview.md` ADR-002 (accepted A, with the spike's product-path findings), ADR-003 (input routing; InputPlumber later), ADR-004 (per-profile sockets, later)
- `docs/tasks/T-123-compositor-spike.md` Outcome (what worked, the pitfalls: `surfaceDestroyed` handler context, llvmpipe needs shm clients, `input` is an altfiles group on bootc, ACL clean-up)
- `shell/spike/Compositor.qml`, `scripts/vm-compositor-spike.sh`, `image/rootfs/usr/lib/systemd/system/ruya-compositor{,-spike}@.service`
- `shell/qml/Shell.qml` (Guide handling, `systemPanel`, `focusCurrent`), `shell/qml/Main.qml`, `shell/src/main.cpp`
- `docs/specs/01-platform.md` §2.1 (startup chain), §8 (Phase 0 checklist the image must keep passing)

## Scope
1. **Host half: T-150** (split off by the lead, 2026-10-29): the app layer, the Shell's compositor API and the C++ `KeyRouter` exist and are tested on Windows. Wire the compositor to them; don't re-solve them here.
2. **Compositor part, Linux only.** The `WaylandCompositor` + xdg-shell wiring (from the spike, cleaned up) in a file or module built only when QtWaylandCompositor is found (CMake option, on in the image build). `Main.qml` stays the window for the Windows host and the tests; the Linux entry point uses the compositor. Keep `ruya-shell: ready` and `--windowed` behaviour on Windows unchanged.
3. **Session and devices (image).** `ruya-compositor@.service` runs `ruya-shell` on eglfs_kms instead of cage. Decide and record how the shell opens input devices: a permanent `uaccess` rule (the shell user then reads every input device; it is the session's only UI) or logind-based device opening; the spike's temporary rule shows the first works. Remove `cage` from `20-base.sh` only if nothing else needs it (keep it if a fallback session is wanted; say which). Retire `ruya-compositor-spike@.service`, the inert rule and `vm-compositor-spike.sh` (or keep the script as the test-client launcher; say which).
4. **A test client in the VM.** Keep a way to start a Wayland test client as `ruya-shell` (the spike's `KeyClient.qml` via `--load` is fine) so the VM check below can be repeated.

## Out of scope
- Launching apps from tiles, per-profile Wayland/PipeWire sockets, `ruya-session` (next task).
- Blur over app surfaces, gamescope nesting, Xwayland, HDR/VRR, display mode switching.
- InputPlumber (ADR-003, B-006); `ruya-inputd` keeps emitting keys.

## Acceptance criteria
- [x] T-150's host tests still pass with the compositor build option off (Windows) and the Linux build compiles with it on (image build).
- [x] VM, fresh disk of the new image: `RUYA_BOOT_OK` with no cage process (`pgrep cage` empty), the first-boot wizard drawn by `ruya-shell` on KMS (VM screenshot).
- [x] VM: the T-123 sequence passes on the default session (test client keys, Guide overlay over it, keys while open not delivered, keys back after close, client exit) — log and screenshots in the Outcome.
- [x] VM: the profile flows of T-120 still work (wizard creates the admin over the real bus; reboot; picker), spot-checked by keys and screenshots.
- [x] The update/rollback drill still passes (`docs/dev-setup.md`): the health check sees `ruya-shell: ready` from the compositor; greenboot's automatic rollback from a broken compositor still triggers.
- [x] `dev.ps1 test` ALL GREEN; `dev.ps1 shots` reviewed for any changed screen.

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
- Start-up order changes here (no cage; `ruya-devices` is a user unit that starts after the shell). Check the boot journal for the `QSoundEffect ... not supported` lines of T-121; if they appear, defer `Sfx` loading until `Audio` reports a default sink (the item was dropped from T-128's Inbox for this reason).

## Outcome
Verified: vm (`0.0.26-t130`, `0.0.27-t130`, QEMU/WHPX, software rendering) and host (`dev.ps1 test` ALL GREEN, 256 QML + 21 skipped; `dev.ps1 shots` ALL GREEN, 56, no screen changed). Done by the lead (Opus 5.5), 2026-11-02.

Built:
- **Compositor module** `shell/compositor/Compositor.qml` (QML module `RuyaCompositor`, built only with `-DRUYA_COMPOSITOR=ON`; the image build sets it and installs `qt6-qtwayland-devel` in the shell stage). A `WaylandCompositor` (socket `ruya-0`) whose `WaylandOutput` window is the ordinary `Main` (now exposing `shell`); each xdg toplevel becomes a `ShellSurfaceItem` sent fullscreen and handed to `Shell.addApp`, so T-150's app layer, focus rules and `KeyRouter` do the rest. `surfaceDestroyed` is connected from the compositor's scope (T-123 pitfall). With the option on, `main.cpp` loads it instead of `Main`; `--load`, `ruya-shell: ready`, and Windows behaviour are unchanged. Replaces `shell/spike/` (deleted).
- **KeyRouter** now takes the Guide keys while focus is on the app item **or any item inside it** (`appHasFocus()`: the window's `activeFocusItem` is the item or a descendant), so a surface item that holds focus in a child can never leak Guide to the app (LEAD-NOTES concern 1). New test `test_guide_taken_from_item_inside_app` (`tst_compositor_layers.qml`).
- **Session (image):** `ruya-compositor@.service` runs `ruya-shell` on `eglfs_kms` (same unit name, so greenboot, `vm-goto.ps1` and the enable line are unchanged). **Decision (lead): device access by a permanent `uaccess` rule**, `/usr/lib/udev/rules.d/70-ruya-input.rules`: logind gives the active seat session (the shell's) ACLs on `/dev/input/event*`, as for the DRM card; Qt has no logind `TakeDevice` path, and a session on another VT that becomes active takes access over (01 §2.1). **`cage` removed** from `20-base.sh`: nothing else used it; the fallback for a shell that cannot start is greenboot's rollback, not a second session. Retired `ruya-compositor-spike@.service` and the inert spike rule.
- **VM test app:** `scripts/vm-compositor-spike.sh` became `scripts/vm-app-check.sh` (`client`, `kill`, `log`, `state`), the client is `scripts/vm-key-client.qml` (copied in with scp, nothing test-only ships in the image).
- Docs: 00 ADR-002 (product path done), 01 §1.2 and §2.1 (startup chain, device decision, fallback) and §8 rows 3/6/7, 02 intro and §4.1, `shell/CLAUDE.md`, `shell/PATTERNS.md`, `docs/dev-setup.md` ("Test app in the VM", drill step 5).

VM verification (fresh `-Work` disk of `0.0.26-t130`; screenshots in `output/vm-shots/t130-*.png`, not committed):
- `RUYA_BOOT_OK 0.0.26-t130`; `rpm -q cage`: not installed; `pgrep -c cage` 0; one `ruya-shell` process; socket `/run/user/972/ruya-0`; 5 of 5 input devices carry a `ruya-shell` ACL; the wizard drawn by the shell on KMS (`t130-wizard`).
- Profiles (T-120 flow): `vm-goto.ps1 home` walked the wizard over the real bus (`ListProfiles`: p1 "Player One", admin, PIN) to Home (`t130-home`); after a reboot the picker shows Player One (`t130-picker-after-reboot`); PIN 1234 signed in (`ActiveProfile` p1).
- T-123 sequence on the default session (log of `vm-app-check.sh log`):
  ```
  19:45:37 ruya-compositor: app focus app: true
  19:45:46-47 test-client: key a count 1 / b 2 / c 3            (t130-client)
  19:46:00 ruya-compositor: app focus ... false                 Super: overlay over the client (t130-overlay)
           down x y: overlay focus moved to Power, nothing reached the client (t130-overlay-keys)
  19:46:11 ruya-compositor: app focus ... true                  Esc
  19:46:14-15 test-client: key d count 4 / e count 5            (t130-after-close)
  19:46:32 app focus false / 19:46:40 app focus true            controller Guide (KEY_HOMEPAGE, uinput) opened and closed it (t130-guide)
  19:46:45 test-client: key f count 6
  19:46:48 ruya-compositor: app gone                            the shell took screen and keys back: Up, Right moved to Games (t130-shell-keys-back)
  ```
  New since the spike: a **held** controller Guide (3 s) over the app opens the power choices (`t130-guide-hold`).
- Update/rollback drill (dev-setup): `bootc switch` to `0.0.27-t130` from a WSL registry → `RUYA_BOOT_OK 0.0.27-t130`, greenboot "health-check passed" (the health check saw `ruya-shell: ready` from the compositor); `bootc rollback` → `RUYA_BOOT_OK 0.0.26-t130`, passed. **Automatic rollback:** `0.0.28-broken` (drop-in `QT_QPA_PLATFORM=nonexistent`): 4 boots each logged the Qt platform error 5 times (the unit's `StartLimitBurst`), never got ready and failed the health check (`boot_counter=3` set); the 5th boot was GRUB's FALLBACK into `0.0.26-t130`, ready, health check passed.
- Boot with a sound card (`-Audio`): no `QSoundEffect ... not supported` lines; `ruya-devices` started 2 s before the shell's first frame; `ruya-devices`, `pipewire`, `wireplumber` active for `ruya-shell`. The `Sfx` deferral of the hint is not needed.
- `qemu-img check` on the fresh disk: no errors.

Deviations and notes:
- The test client renders in software (llvmpipe has no `EGL_WL_bind_wayland_display`); dmabuf clients, blur over a client surface (the overlay dims the client instead), VT switching, suspend/resume and DRM-master handover under eglfs remain unexplored (B-003 and later tasks). The FPS meter read 75 in the overlay over a running client at 1280x800, a VM number, not a KPI.
- Before sign-in an app gets no focus (`Shell.focusCurrent` returns while signed out) but is still drawn above the picker; apps are only started after sign-in (`ruya-session`, next task), and locking with an app open is that task's to define.
- `Compositor.qml` is not covered by qmllint or the Windows tests (no QtWaylandCompositor in the Windows kit); the image build compiles it with qmlcachegen, and the VM run above is its test.
- A Qt client without `app_id` shows as `app:` until it sets one; the test client reported `org.ruyaos.ruya-shell` (its application name).
- The first `make-disk.sh` failed with "Cannot allocate memory" writing to `output/` on D: (99 % full, 14 GB free); it passed after deleting the stale `work.qcow2`. Both host drives sit at 99 % (STATUS, owner decisions).
