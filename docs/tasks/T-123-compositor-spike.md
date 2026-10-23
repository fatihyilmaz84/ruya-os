# T-123 — Compositor spike in the VM: shell as QtWaylandCompositor with an overlay over a client app (ADR-002)

Status: done · Phase: 1 · Depends: — · Area: shell, image · Size: M · Owner: lead

## Goal
Answer the *functional* half of ADR-002 in the QEMU VM: can `ruya-shell` be the Wayland compositor (option A), show a client app fullscreen, draw the Guide overlay over it, and give input back to the app when the overlay closes? Performance (≥ 55 FPS on the mid tier) stays for real hardware (B-002/B-003).

## Read first
- `docs/specs/00-overview.md` §5 ADR-002 (options, exit criterion), ADR-003 (input arbitration), ADR-008 (GPL-3.0, so option A has no licence friction)
- `docs/specs/01-platform.md` (session: `ruya-compositor@tty1.service` runs cage today)
- `docs/dev-setup.md` "Seeing and driving the VM" (`vm-screenshot.ps1`, `vm-keys.ps1`, `vm-inject-key.py`)
- `shell/qml/Shell.qml` (Guide overlay, `systemPanel`), `shell/src/main.cpp`

## Scope
1. A spike build of the shell that is a `QtWaylandCompositor` (QML `WaylandCompositor` + `XdgShell`/`WlShell`), started by a variant of the session unit instead of cage. Keep it behind a flag or a separate entry QML so the normal cage session keeps working.
2. Launch one Wayland client fullscreen as a surface under the shell UI (a Qt or GTK demo app, or `weston-simple-egl`, from the image or a Flatpak), and draw the Guide overlay (scrim + panel) above it when Guide is pressed.
3. Input: while the overlay is closed, keys go to the client; while it is open, to the shell; closing returns them to the client. Check with `vm-keys.ps1` and screenshots.
4. Write down what Fedora's Qt provides (QtWaylandCompositor package, version ≥ 6.8), what the image needs added, what breaks (cage-only assumptions, `wait-shell-ready`), and the effort to make it the product path.

## Out of scope
- Frame rates, gamescope nesting, Xwayland, InputPlumber routing (ADR-003), app switching UI.
- Making the compositor session the default boot path; that is a follow-up task if the spike says yes.

## Acceptance criteria
- [x] In the VM, a VM screenshot shows the client app fullscreen with the shell's Guide overlay over it (`vm-screenshot.ps1`, path in the Outcome).
- [x] Keys sent while the overlay is closed reach the client; while open they don't; after closing they do again (evidence: screenshots or the client's log, in the Outcome).
- [x] The normal cage image still boots with `RUYA_BOOT_OK` (the spike does not change the default session).
- [x] ADR-002 in `00-overview.md` is updated with the functional result and a recommendation; it stays *Open* for the owner (or *Proposed*) until performance is measured on hardware.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\smoke-test.ps1
```
Plus the VM steps above.

## Docs to update
- `docs/specs/00-overview.md` ADR-002; `docs/specs/01-platform.md` if the session changes; STATUS blocker B-003 (functional part done, performance part left).

## Hints
- The VM renders in software (llvmpipe), so effects like `MultiEffect` blur may be slow but should still draw.
- `QT_QPA_PLATFORM=eglfs` or `linuxfb` for a compositor running directly on DRM/KMS without cage; check which works on QEMU's `virtio-gpu`/`std` VGA.
- Keep the spike code out of the tested shell module if it would slow `dev.ps1 test`; QtWaylandCompositor is not part of the Windows Qt kit's normal use.

## Outcome
Done by the lead (Opus 5.5), 2026-10-23. **The functional half of ADR-002 option A works in the VM.**

Built:
- `shell/spike/Compositor.qml` (about 100 lines): a `WaylandCompositor` (socket `ruya-0`) whose output window hosts the unchanged `Shell` as the bottom layer, an app layer with one `ShellSurfaceItem` per xdg toplevel (sent fullscreen), and an overlay layer to which the Shell's `systemPanel` is re-parented at start-up. The client item's `Keys` handler runs before the item forwards keys to its client and takes the Guide keys (`Shell.isGuideKey`: Super and `KEY_HOMEPAGE`) to open the overlay; when the overlay closes, focus (and so the keyboard) returns to the client; when the client goes away the shell gets the screen and focus back.
- `shell/spike/KeyClient.qml`: a stand-in app that shows and logs every key it gets.
- `ruya-shell --load <file.qml>` (`shell/src/main.cpp`): load a QML file from disk instead of the shell module; it can still `import RuyaShell`. The window found under a non-window root (the compositor) still prints `ruya-shell: ready`. `shell/spike/` is installed to `/usr/share/ruya-shell/spike` and is outside the `RuyaShell` module, so `qmllint`, `lupdate` and the tests never see it (the Windows Qt kit has no QtWaylandCompositor).
- Image: `ruya-compositor-spike@.service` (the session unit with `QT_QPA_PLATFORM=eglfs`, `eglfs_kms`, no `[Install]`, so never enabled) and an **inert** udev rule `/usr/share/ruyaos/spike/70-ruya-spike-input.rules`. `scripts/vm-compositor-spike.sh` (guest) swaps cage for the spike, installs that rule in `/run/udev/rules.d` only while the spike runs, starts or kills the client, prints the log, and on `stop` removes the rule and the ACLs it caused and restarts cage.
- `.containerignore` (repository root): the image build context no longer includes `shell/build*`, `services/target`, `output` and `.git`. Without it, a podman `COPY shell` failed on a temporary file of a Windows build running at the same time.

Verification:
- `dev.ps1 test` ALL GREEN (132 QML + 11 skipped, 23 Rust; the MSVC build compiles the `--load` path).
- Image `0.0.8-t123` built in WSL (lint clean), fresh disk: **`RUYA_BOOT_OK 0.0.8-t123`** with the default cage session; the spike unit is `static` and no spike udev rule is active.
- On that image, with only `vm-compositor-spike.sh`, `vm-keys.ps1` and `vm-inject-key.py`: client fullscreen (`output/vm-shots/t123-img-client.png`); `a b c` reached it (count 3); Super opened the Guide overlay over the still-animating client (`t123-img-overlay.png`); `down x y` moved the overlay's focus and did **not** reach the client; Esc closed it and `d e` reached the client (count 5, `t123-img-after-close.png`); the controller Guide (`KEY_HOMEPAGE` via uinput) opened (`t123-img-guide.png`) and closed it, then `f` reached the client (count 6); killing the client gave the shell back, and Right moved the picker focus (`t123-img-client-gone.png`); `stop` restored cage (`t123-img-back-to-cage.png`). Log excerpt (`vm-compositor-spike.sh log`):
  ```
  20:32:47.91 spike-client: key a count 1 ... key c count 3
  20:32:51.77 ruya-spike: Guide taken from the client / client focus false / overlay open
  20:33:01.73 ruya-spike: overlay closed / client focus true
  20:33:05.35 spike-client: key d count 4 ... key e count 5
  20:33:12.20 ruya-spike: Guide taken ... overlay open; 20:33:19.51 overlay closed
  20:33:23.28 spike-client: key f count 6
  20:33:25.99 ruya-spike: client gone
  ```
- ACLs: devices with a `ruya-shell` ACL went 0 (cage) → 3 (spike) → 0 (after `stop`).

What Fedora provides and what the product path needs (also in ADR-002):
- `qt6-qtwayland` 6.11.2 (already an image package) ships `QtWayland.Compositor`; nothing new to install. eglfs_kms works on `virtio-vga` with llvmpipe (Mesa 26.2); 67–75 FPS was shown by the overlay's meter at 1280×800, a VM number, not a KPI.
- **Input devices:** eglfs opens `/dev/input/event*` itself (no logind `TakeDevice`; cage uses libseat). On bootc, `input` is an altfiles group, so `usermod -aG input` silently does nothing; a `uaccess` udev rule works. The product needs a decision: that rule (the shell user reads every input device) or logind-based device opening. VT switching, suspend/resume and DRM-master handover under eglfs are unexplored.
- **Client buffers:** llvmpipe has no `EGL_WL_bind_wayland_display` (`qt.waylandcompositor.hardwareintegration` warning), so VM clients must render in software (shm). dmabuf from real GPUs is untested.
- **Shell structure:** re-parenting `systemPanel` from outside is a spike hack. The product needs an app layer and an overlay layer inside `Shell` (or `Main.qml`), and key routing in C++ (an event filter in front of the client item) so modifier-only keys and ADR-003 routing have one place. `wait-shell-ready`/greenboot only need the `ruya-shell: ready` line, which the compositor path already prints.
- Effort to make A the default session: one M task for the session (unit, device access, layers, C++ key routing, greenboot), then `ruya-session` with per-profile sockets (ADR-004/010) on top. Not done here (out of scope).

Deviations and notes:
- The Guide **hold** (2 s for the power choices) is not wired while a client has focus; the Shell's own hold logic runs only when the Shell has focus. Expected for the spike.
- A `ShellSurfaceItem` handler for `surfaceDestroyed` ran with a dead context ("compositor is null") and left the last frame on screen; connecting the signal from the compositor's scope fixed it. Neither `autoDestroy` nor `autoDestroyOnSurfaceDestruction` exists on Qt 6.11's `ShellSurfaceItem`.
- Fresh disk copies have new SSH host keys and `ssh` blocks on the prompt; the batch options are now in `dev-setup.md`.
- ADR-002 was left **Open** by this task: the performance half (≥ 55 FPS on the mid tier, blur over a game) needs hardware (B-003). Later the same day the owner accepted option A as the product direction, performance to be confirmed on hardware, option B as the fallback; the follow-up is T-130.

Follow-ups: making A the product session is an owner decision first (Open owner decisions in STATUS), then a task.
