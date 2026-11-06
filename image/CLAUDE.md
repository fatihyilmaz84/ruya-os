# image/ — rules for the bootc OS image

**Build and boot-test every change here** (setup and commands in `docs/dev-setup.md`):

1. In WSL (`wsl -d FedoraLinux-44 -u root`, repo at `/mnt/d/dev/RuyaOS`): `scripts/build.sh <version>`. It must pass `bootc container lint --fatal-warnings`. Then `scripts/make-disk.sh qcow2`.
2. On Windows: `.\scripts\smoke-test.ps1`. It must print `RUYA_BOOT_OK <version>`. When the VM must keep state across boots, use `-Work` (one shared `work.qcow2`); **never copy the disk per task** (`dev-setup.md` "Disk space"). For anything touching updates, boot health or greenboot, also run the update/rollback drill from `dev-setup.md`.
3. To debug a VM:
   - run `smoke-test.ps1 -Keep`, then `ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1`;
   - `output\serial.log` holds the full boot console;
   - the shell's log is `journalctl -b _UID=$(id -u ruya-shell)`.
   Put multi-line diagnostics in a script file and `scp` it over; inline quoting through PowerShell → ssh breaks `$?`, `|` and quotes.

Builds take 3–30 minutes (the NVIDIA step is cached unless `image/build/` or earlier layers change); run them in the background.

## Layout

- `Containerfile`: a multi-stage build. Shell and services are built in Fedora containers, then copied onto `quay.io/fedora/fedora-bootc`.
- `build/NN-*.sh`: ordered build steps, bind-mounted (not shipped): repos → base packages → codecs → NVIDIA → slim (`50`) → services (`96`) → initramfs → branding → guard (`98`) → cleanup. Add steps by number; keep each idempotent and `set -euo pipefail`.
- `rootfs/`: files installed into the image by a `cp --no-preserve=mode` in the Containerfile (not `COPY`: a Windows checkout is all 0777, and a directory a layer introduces keeps that mode on the deployed disk). Files end up 0644, directories 0755; make a script executable with a `chmod 0755` in the same `RUN`. The build fails if anything from `rootfs/` is group- or world-writable. **Prefer `/usr` over `/etc`** (`/usr/lib/systemd/system`, `/usr/lib/sysusers.d`, `/usr/lib/tmpfiles.d`, `/usr/share/dbus-1/system.d`). `/etc` is persistent and 3-way-merged on update. Never put files in `/var`; create them with `tmpfiles.d`.
- `bib/`: bootc-image-builder config. `config.toml` is git-ignored because it holds dev credentials.

## Rules

- **Never ship private keys or credentials.** The NVIDIA step deletes the akmods private key and asserts that it's gone; keep that assertion.
- **Keep the image small (T-195).** Every package group has a reason in `docs/image-packages.md`; a new package or enabled unit needs a row there. `98-guard.sh` fails the build on a banned package (desktop environments, printing, `sssd`, `samba` (except the four libs ffmpeg needs), `qemu-user`, `firewalld`, `cockpit`, ...) and on any enabled unit that is not in `build/enabled-units.txt`. Removals go in `50-slim.sh` only, which refuses a transaction that contains a protected package (`bootc`, `systemd`, `NetworkManager`, `flatpak`, ...) or one nobody asked for; units that stay installed but are off go in `rootfs/usr/lib/systemd/system-preset/45-ruyaos.preset`. Test a change to these scripts in seconds with `podman run --rm -v $PWD/image/build:/b:ro localhost/ruyaos:dev bash /b/50-slim.sh` before a full build.
- Package choices follow ADR-009 (ship all codecs and drivers). Never add `pulseaudio` or `jack-audio-connection-kit` (they conflict with PipeWire), a desktop environment, or a display manager.
- Shell scripts:
  - stay LF (`.gitattributes`);
  - need the exec bit in git (`git update-index --chmod=+x path`);
  - must pass `bash -n` (run it on every script you touch);
  - must not contain Windows-mangled backslashes. Write them with the Write/Edit tools.
- A new service or unit has to be enabled in the Containerfile's `systemctl enable` line (see `services/CLAUDE.md`).
- Keep `RUN bootc container lint` as the last instruction.
- Fast checks before a full build:
  - `bash -n` on scripts;
  - `podman run --rm localhost/ruyaos:dev systemd-analyze verify <unit>` against the last built image, for units.
  The full build plus smoke test above is the real check. CI (`.github/workflows/ci.yml`, job `image`) repeats it on GitHub under KVM on every push and pull request (mapping in `docs/dev-setup.md`, "Local checks and CI").
- **Known VM quirks**, so you don't chase them:
  - WHPX hangs on guest reset, so QEMU runs with `-no-reboot` and `vm-reboot-check.ps1` cold-starts it;
  - use `127.0.0.1`, not `localhost`, for SSH;
  - the VM reaches a WSL registry only through WSL's IP;
  - software rendering is expected, and the VM has no sound card unless you boot with `smoke-test.ps1 -Audio` (`dev-setup.md`, "Audio in the VM"); the three `QSoundEffect: playback of this format is not supported` lines at the first shell start are a benign race with WirePlumber.
  - a polkit rule in `/etc/polkit-1/rules.d` does not shadow the one in `/usr/share/...` (both load), and a copied rule needs the right SELinux label: for experiments bind-mount a rule over the original and `chcon --reference` it, then restart polkit;
  - a call over `systemd-run`/`systemctl --machine=<user>@.host` hands its stderr to PID 1, and SELinux lets PID 1 write a pipe of the *calling shell* but not one made by a service, nor a file in `/root`: the call then fails with "Connection reset by peer" or hangs. A service gives it a file in its `RuntimeDirectory` (T-162); in a script use `2>&1 | cat`;
  - `make-disk.sh` can fail with "Cannot allocate memory" when `dev.ps1 test` or another heavy build runs at the same time (WSL has 8 GB): run image builds alone.
