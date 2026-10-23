# T-123 — Compositor spike in the VM: shell as QtWaylandCompositor with an overlay over a client app (ADR-002)

Status: todo · Phase: 1 · Depends: — · Area: shell, image · Size: M · Owner: lead

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
- [ ] In the VM, a VM screenshot shows the client app fullscreen with the shell's Guide overlay over it (`vm-screenshot.ps1`, path in the Outcome).
- [ ] Keys sent while the overlay is closed reach the client; while open they don't; after closing they do again (evidence: screenshots or the client's log, in the Outcome).
- [ ] The normal cage image still boots with `RUYA_BOOT_OK` (the spike does not change the default session).
- [ ] ADR-002 in `00-overview.md` is updated with the functional result and a recommendation; it stays *Open* for the owner (or *Proposed*) until performance is measured on hardware.

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
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
