# T-280 — Close the dark gap between the boot splash and the shell's first frame

Status: todo · Phase: 2 · Depends: T-269 · Area: shell, image · Size: M · Owner: lead

## Goal
From the splash to the first shell frame the screen never goes black: the splash stays up, or the shell draws the same picture as its very first frame. T-269 measured a dark gap of 3.4 to 4.3 s in the VM (software rendering; less on real hardware) between Plymouth's exit and `ruya-shell: ready`. Follow-up of the owner's boot request (2026-11-07).

## Facts (T-269 Outcome)
- Qt eglfs needs Plymouth to have exited before it gets DRM master; `plymouth deactivate` instead of waiting for the exit made eglfs (unprivileged `ruya-shell`) fail every page flip with "Permission denied". `--retain-splash` does not keep the frame on virtio.
- Spec 01 §2.1 notes that Qt eglfs has no `TakeDevice` (logind/seatd) path.

## Scope
1. Measure the real gap on the Dell first (T-269 hardware pass), then pick the cheapest of: (a) the shell shows the splash picture (`bg.png` plus the wordmark, the same pixels as the Plymouth theme) as its first eglfs frame, before QML finishes loading (a minimal `QQuickWindow` background colour or a native first draw in `main.cpp`), so the black gap shrinks to the shell's own startup; (b) give the compositor DRM master through logind/seatd; (c) leave it if the Dell's gap is under about one second.
2. Whatever is chosen: no text, no cursor, no regression in the greenboot drill and in `RUYA_BOOT_OK`; the first-frame timing is logged (`ruya-shell: first frame at N ms`).

## Out of scope
- A new logo, boot animation, disk-encryption prompt (Phase 6).

## Acceptance criteria
- [ ] Boot shots (`scripts/vm-boot-shots.ps1`) show no black frame longer than 0.5 s between the splash and the shell in the VM, or the Dell numbers justify (c).
- [ ] VM (this task) `RUYA_BOOT_OK`, `check-boot-config.sh`, `vm-boot-check.sh`, the rollback drill still pass; `.\scripts\dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: …`._
