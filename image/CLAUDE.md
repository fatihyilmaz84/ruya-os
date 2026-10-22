# image/ — rules for the bootc OS image

**This machine cannot build or boot the image** (no Linux, no Podman). Every change here is unverified until it runs in CI or on Linux. Say so in STATUS and the task Outcome.

## Layout

- `Containerfile`: a multi-stage build. Shell and services are built in Fedora containers, then copied onto `quay.io/fedora/fedora-bootc`.
- `build/NN-*.sh`: ordered build steps, bind-mounted (not shipped): repos → base packages → codecs → NVIDIA → initramfs → cleanup. Add steps by number; keep each idempotent and `set -euo pipefail`.
- `rootfs/`: files copied into the image as they are. **Prefer `/usr` over `/etc`** (`/usr/lib/systemd/system`, `/usr/lib/sysusers.d`, `/usr/lib/tmpfiles.d`, `/usr/share/dbus-1/system.d`). `/etc` is persistent and 3-way-merged on update. Never put files in `/var`; create them with `tmpfiles.d`.
- `bib/`: bootc-image-builder config. `config.toml` is git-ignored because it holds dev credentials.

## Rules

- **Never ship private keys or credentials.** The NVIDIA step deletes the akmods private key and asserts that it's gone; keep that assertion.
- Package choices follow ADR-009 (ship all codecs and drivers). Never add `pulseaudio` or `jack-audio-connection-kit` (they conflict with PipeWire), a desktop environment, or a display manager.
- Shell scripts:
  - stay LF (`.gitattributes`);
  - need the exec bit in git (`git update-index --chmod=+x path`);
  - must pass `bash -n` (run it on every script you touch);
  - must not contain Windows-mangled backslashes. Write them with the Write/Edit tools.
- A new service or unit has to be enabled in the Containerfile's `systemctl enable` line (see `services/CLAUDE.md`).
- Keep `RUN bootc container lint` as the last instruction.
- Validation available here:
  - `bash -n` on scripts;
  - reading the Containerfile carefully;
  - `systemd-analyze verify` is **not** available.
  CI (`.github/workflows/ci.yml`) does the real build once the repo has a remote.
