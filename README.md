# RuyaOS

An immutable, Fedora-bootc-based console OS for living-room PCs. It boots straight into a controller-first, cinematic Qt Quick shell for apps, media and games.

**Status:** Phase 0 (foundation). Not usable yet.

| Path | What |
|---|---|
| `docs/specs/` | The specs. Start with [00-overview](docs/specs/00-overview.md) |
| `docs/REVIEW.md` | Review of the original research docs (archived in `docs/archive/`) |
| `docs/dev-setup.md` | Windows host setup, build/boot/update drills |
| `image/` | bootc Containerfile and the rootfs overlay (systemd units, PAM, greenboot checks) |
| `shell/` | `ruya-shell`: Qt 6 / QML console UI |
| `services/` | Rust services (`ruya-inputd` so far) |
| `scripts/` | build, disk image, VM, smoke test |
| `tests/shell/` | Host-side shell check (PySide6, runs on Windows) |

Quick start (Linux / Podman Machine):

```bash
scripts/build.sh && scripts/make-disk.sh qcow2 && scripts/run-vm.sh
```
