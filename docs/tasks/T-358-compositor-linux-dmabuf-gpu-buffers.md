# T-358 — The compositor gives apps GPU buffers: linux-dmabuf-v1

Status: in-progress · Phase: 2 · Depends: T-164 · Area: image (a qtwayland plugin build stage), shell (compositor), scripts · Size: M · Owner: lead · Complexity: hard · Developer surface: none

## Goal
A game started from the shell renders on the GPU. Found on the Dell (T-355, 2026-11-09): SuperTuxKart through the shell (T-164) runs on llvmpipe at 560 % CPU and a low resolution, because the compositor offers clients no GPU device: Mesa 26.2 clients need `linux-dmabuf-v1` (`MESA-EGL: failed to get driver name for fd -1`), and the image's qt6-qtwayland 6.11.2 ships only the old `wayland-egl` server integration (loaded by the shell, but Mesa no longer advertises a device through it). The game's sandbox already has `/dev/dri`. Vulkan games need the same protocol.

## Decision (lead, 2026-11-09, inside ADR-002; owner agreed "take the lead")
Option A: build Qt's own `linux-dmabuf-unstable-v1` compositor client-buffer integration from the qtwayland source of the image's exact Qt version as an image build stage, install it beside Fedora's plugins and select it for the compositor. Rejected for now: our own linux-dmabuf implementation (much more code to maintain), gamescope on the display outside our compositor (changes ADR-002, loses the Guide overlay over games; owner-level).

## Scope
1. **Spike:** does qtwayland 6.11.2 contain the plugin, why does Fedora's build not ship it (spec, feature check, missing build dependency), and the smallest build that produces `libqt-wayland-compositor-linux-dmabuf-unstable-v1.so` against Fedora's Qt (same version, ABI-exact).
2. **Image:** a build stage in the Containerfile (or a small RPM) that compiles only that plugin; `ruya-compositor@.service` selects it (`QT_WAYLAND_CLIENT_BUFFER_INTEGRATION`, keep `wayland-egl` as the fallback if both can be listed); the image lint checks the plugin is present.
3. **Shell:** if the integration needs code in `Compositor.qml` (e.g. `useHardwareIntegrationExtension`), add it; the shell's own rendering must not change.
4. **Checks:** VM (this task): `RUYA_BOOT_OK`, `vm-session-check.sh display` and `check` still pass (software rendering in the VM; the client must still map); the plugin is loaded (journal). Dell (hw): STK's log names the Intel GPU (not llvmpipe), CPU load, resolution and frame feel recorded; the Guide overlay over the game still works.

## Out of scope
- Explicit sync, hardware planes/direct scanout, HDR, VRR, gamescope nesting (B-003 keeps those).

## Acceptance criteria
- [ ] The image contains the plugin built from the same qtwayland version as Fedora's Qt; the build is reproducible in `scripts/build.sh` (no network beyond the package mirrors and the source RPM).
- [ ] VM (this task): `RUYA_BOOT_OK`; `vm-session-check.sh display` ALL CHECKS PASSED; the compositor journal shows the dmabuf integration loaded.
- [ ] Dell (hw): STK reports the UHD 630 as its renderer through the shell; CPU load and frame feel recorded in the Outcome.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; `01` §2.1 and ADR-002/ADR-023 notes updated.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
