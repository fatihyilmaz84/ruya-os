# RuyaOS

An immutable, Fedora-bootc-based console OS for living-room PCs. It boots straight into a controller-first, cinematic Qt Quick shell for apps, media and games. Free and open source ([LICENSE.md](LICENSE.md)).

**Status:** Phase 0–2. Not usable yet. Live progress is on the board in [docs/STATUS.md](docs/STATUS.md).

| Path | What |
|---|---|
| `docs/STATUS.md` | Progress board, blockers, session log |
| `docs/tasks/` | Work items with acceptance criteria |
| `docs/specs/` | The specs. Start with [00-overview](docs/specs/00-overview.md), which holds the decisions (ADRs) |
| `docs/dev-setup.md` | Host setup, build/run/test, update drills |
| `CLAUDE.md` | Rules for AI contributors (also read by humans) |
| `api/dbus/` | D-Bus contracts between the shell and services |
| `shell/` | `ruya-shell`: Qt 6 / QML console UI, with Qt Quick tests in `shell/tests/` |
| `services/` | Rust services: `ruya-inputd` (gamepad bridge), `ruya-profiles` (profiles/PINs) |
| `image/` | bootc Containerfile, build steps, rootfs overlay |
| `scripts/` | `dev.ps1` (Windows dev loop); build, disk image, VM and smoke test (Linux) |
| `docs/REVIEW.md`, `docs/archive/` | Review of the original research docs |

**Windows dev loop** (Qt 6.10.3 MSVC + VS 2026; setup in `docs/dev-setup.md`):

```powershell
.\scripts\dev.ps1 test    # everything that must pass before a commit
.\scripts\dev.ps1 run     # the shell in a window, with mock services
```

**Image** (Linux / Podman Machine):

```bash
scripts/build.sh && scripts/make-disk.sh qcow2 && scripts/run-vm.sh
```
