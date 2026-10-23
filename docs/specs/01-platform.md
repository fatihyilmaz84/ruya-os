# RuyaOS — Platform, Build & Release

Status: **Draft v1** · Parent: [00-overview](00-overview.md)

## 1. OS image

### 1.1 Base
- `FROM quay.io/fedora/fedora-bootc:<N>`, pinned to a Fedora major release. Track N and N+1 in CI so rebases happen deliberately.
- **One image for all hardware** (ADR-009): RPM Fusion codecs and the NVIDIA driver are always included. Build steps are ordered scripts in `image/build/NN-*.sh` (repos → base → codecs → NVIDIA → initramfs → cleanup), bind-mounted at build time so they aren't shipped.
- Every build runs `bootc container lint` and fails if it reports problems.

### 1.2 Package set (starting point; verify names against the target Fedora release)

| Area | Packages |
|---|---|
| Graphics | `mesa-dri-drivers`, `mesa-vulkan-drivers`, `linux-firmware` (already in base?) |
| Qt | `qt6-qtbase`, `qt6-qtdeclarative` (includes Quick Controls 2), `qt6-qtwayland`, `qt6-qtmultimedia`, `qt6-qtshadertools` (build only) |
| Compositor (Phase 0) | `cage` (verify it's in Fedora; otherwise build it) |
| Audio | `pipewire`, `pipewire-pulseaudio`, `pipewire-alsa`, `wireplumber`. **Not** `pulseaudio` or `jack-audio-connection-kit`, which conflict. |
| Network/BT | `NetworkManager`, `NetworkManager-wifi`, `bluez`, `iwlwifi-*` firmware |
| Storage | `udisks2`, `exfatprogs`, `ntfs-3g` (or kernel `ntfs3`) |
| Apps | `flatpak`, `xdg-desktop-portal` (+ a portal backend, see 03 §4.4) |
| Health | `greenboot`, `greenboot-default-health-checks` |
| Input | `inputplumber` (per ADR-003; may need a COPR or our own build) |
| Gaming | `gamescope` (Phase 5) |

The build excludes any desktop environment, display manager, `kdeconnect` and `pulseaudio`.

### 1.3 Filesystem semantics (what to rely on)
- `/usr`: read-only, comes from the image.
- `/etc`: **persistent and mutable**. On upgrade, bootc does a 3-way merge (image default, old image default, local edits). Ship defaults in `/usr/lib/…` and `/usr/etc` where possible, and keep local `/etc` edits to a minimum.
- `/var`: persistent, never touched by updates. `/home → /var/home`. Our state lives in `/var/lib/ruyaos/`.
- `/opt`: in Fedora bootc it points into `/var` by default. Don't install image content there. Use `/usr/lib/ruyaos/`.
- Default root filesystem is XFS on one partition (+ ESP + `/boot`). There is no separate data volume unless the installer creates one (§5).

## 2. Boot & session

### 2.1 Startup chain
`systemd` → `graphical.target` → `ruya-compositor@tty1.service` (implemented in `image/rootfs/usr/lib/systemd/system/`). This unit has `User=ruya-shell`, `PAMName=ruya-shell` (dedicated PAM stack: auth denied, account + session only), `TTYPath=/dev/tty1`, `StandardInput=tty`, and `Conflicts=getty@tty1`. It gets a logind session on seat0 with DRM and input access. The Rust services are ordinary system services with `Before=ruya-compositor.service`.

- No display manager and no greeter. Profile selection happens inside the shell.
- `Restart=always` with `StartLimitBurst` on the compositor. After N fast failures, start `ruya-safe-mode.service`: a minimal QML screen offering Restart, Roll back OS, or Factory reset.
- Plymouth boot splash with the RuyaOS theme. `quiet loglevel=3` on the kernel command line.
- VT switching is disabled in production builds and enabled in `dev` builds (§6).

### 2.2 Suspend / power
- Idle → dim → suspend (s2idle/S3) after configurable timeouts. Apps keep running across suspend.
- Wake sources: power button, USB controller/keyboard (`/sys/.../power/wakeup`), Bluetooth (adapter-dependent, best effort).
- The Guide button held for 2 s opens the power menu.

### 2.3 Drivers & Secure Boot
- Fedora kernel and shim are signed, so Secure Boot works out of the box on AMD/Intel. NVIDIA systems need the MOK step below.
- NVIDIA modules are built during the image build (akmods, `image/build/40-nvidia.sh`) and signed. The public cert ships at `/usr/share/ruyaos/secureboot/akmods-nvidia.der`. Today the key is ephemeral per build; Phase 6 moves it to a stable **project MOK key** held in CI secrets. First boot runs `mokutil` enrollment, which requires a one-time UEFI MOK screen. This is documented in the installer UX. The approach follows Universal Blue's.
- Out-of-tree controller drivers (`xone` for the Xbox wireless dongle, `xpadneo`) are handled the same way. They're optional, and the in-kernel `xpad` and `hid-playstation` cover wired Xbox and DualSense.

## 3. Security baseline
1. SELinux enforcing. We write custom policy modules for our services when needed.
2. Rust services run with systemd hardening (`ProtectSystem=strict`, `NoNewPrivileges`, `DynamicUser` where possible).
3. Third-party code runs only in Flatpak sandboxes, as the profile's user, never as root.
4. **Full-disk encryption (Phase 6):** LUKS2 with TPM2 auto-unlock (`systemd-cryptenroll --tpm2-pcrs=7`) as an installer option that's on by default when a TPM2 is present. Without it, profile PINs only protect against casual access.
5. Image signature enforcement via `/etc/containers/policy.json` (`sigstoreSigned` for our registry).
6. No auto-run from removable media, ever.
7. Debug features (SSH, VT switching, shell journal over network) exist only in `dev` channel images.

## 4. Updates & rollback (ADR-006)
- Images are pushed to an OCI registry (e.g. `ghcr.io/<org>/ruyaos:<channel>`), signed with **cosign** keyless or a project key.
- `ruya-update` checks daily (or on demand) with `bootc upgrade --check`. Then it downloads with `bootc upgrade`, stages, notifies, and reboots when idle or when the user accepts.
- **Automatic rollback:** greenboot runs required health checks on boot (compositor starts, `ruya-*` services are active, the shell reports "home rendered" over D-Bus within 60 s). After 3 failed boots, greenboot rolls back with `bootc rollback` and records the event, which the shell displays.
- Manual rollback is available in Settings → System (admin only) and in the GRUB menu (hold Shift/Esc).
- Channel switching uses `bootc switch ghcr.io/<org>/ruyaos:<channel>`.
- Use chunked images (`rpm-ostree compose build-chunked-oci` or an equivalent rechunker) to keep update downloads small. Measure the delta size per release.
- App (Flatpak) updates are independent of OS updates and never need a reboot.

## 5. Installer, first boot, recovery

### 5.1 Installer
- Phase 0–5: `bootc-image-builder` outputs (`qcow2`, `raw`, `anaconda-iso`) with a kickstart that does an unattended install to the largest disk. No user creation in Anaconda.
- Phase 6: a **controller-driven installer**. A live ISO boots the RuyaOS shell in "installer mode", where you pick a disk, encryption on or off, confirm, and the installer runs `bootc install to-disk`. This replaces the keyboard/mouse Anaconda UI.

### 5.2 First-boot setup (OOBE), run by the shell
Language/region → controller pairing (if no wired pad) → network → time zone → create the admin profile + PIN → optional extra profiles → updates check → home.

**Built so far (T-106, `shell/qml/Setup.qml`)**, shown instead of the profile picker whenever the profiles service reports no profile: welcome → **language** (English/Türkçe; stored in `DeviceSettings.language`, translation itself is T-109) → **network** (placeholder text only) → **create the admin** (name via the on-screen keyboard, PIN entered twice, `CreateProfile` with no admin credentials) → done → profile picker. Not built yet: controller pairing, time zone, region, extra profiles, update check. Setup does not sign the new admin in; they pick their profile and enter the PIN like any later boot.

### 5.3 Factory reset
Because `/etc` and `/var` persist, reset is explicit. It removes `/var/home/*`, `/var/lib/ruyaos`, `/var/lib/flatpak` (optionally keeping system apps), and local `/etc` diffs (restored from `/usr/etc`), then deletes profile users and reboots into OOBE. It requires the admin PIN and a confirmation hold. **Open:** whether to implement this as a fresh `bootc install` re-deploy from the currently booted image, which is cleaner. Spike in Phase 6.

### 5.4 Recovery
- GRUB menu: previous deployment (rollback).
- Safe mode (§2.1).
- The USB installer has a "Repair" option that re-deploys the image while keeping `/var` (`bootc install to-existing-root`).

## 6. Development workflow

### 6.1 Hosts
Developers edit on **Windows** (VS Code). Builds and VMs need Linux. Supported setups, in order of preference:

| Setup | Builds | VM tests | GPU/KPI tests |
|---|---|---|---|
| **A. Windows + dedicated test mini-PC** (recommended) | Podman Machine | QEMU (WHPX) for smoke tests | Real hardware over SSH, flashing via USB or `bootc switch` |
| B. Windows + Hyper-V Fedora VM (nested virtualization on) | Podman inside the VM | QEMU/KVM inside the VM | ✗ |
| C. Podman Machine only (WSL2 backend, rootful, ≥ 6 GB RAM) | ✓ | Limited (needs nested KVM in WSL2) | ✗ |

QEMU on Windows has no KVM (WHPX only), and virgl/GL acceleration there is limited. The shell will fall back to llvmpipe. That's fine for functional tests and **invalid for performance numbers.** GPU KPIs are measured only on real hardware.

### 6.2 Commands (to be scripted in `scripts/`)
```bash
# inside Podman Machine / Linux VM
podman build -t localhost/ruyaos:dev -f image/Containerfile .
podman run --rm localhost/ruyaos:dev bootc container lint

# disk image for QEMU (never `bootc install to-disk /dev/vda` inside the build VM — that is the VM's own disk)
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./output:/output -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 --rootfs xfs --local localhost/ruyaos:dev
```
For quick iteration on a running test box: push to a local registry, then run `bootc switch --transport registry <host>:5000/ruyaos:dev` and reboot. During shell-only work, run the shell nested on the dev machine (Linux VM with a desktop) to avoid reflashing.

### 6.3 Repository layout (proposed)
```
image/        Containerfiles, rootfs overlays, kickstart, bib config.toml
shell/        Qt/QML compositor + shell (CMake)
services/     Rust workspace (ruya-session, -profiles, -store, -devices, -update)
api/dbus/     D-Bus interface XML (contract)
scripts/      build, run-vm, flash, lint
tests/        VM smoke tests, QML tests, KPI harness
docs/         specs, ADRs, archive
```

## 7. Testing & CI

### 7.1 CI pipeline (GitHub Actions or GitLab, Linux runners with KVM)
1. Lint: `cargo clippy`, `cargo fmt --check`, `qmllint`, `clang-format`, shellcheck.
2. Unit tests: `cargo test`, Qt Quick Test for QML components.
3. Image build, `bootc container lint`, SBOM (`syft`), vulnerability scan (`grype`), licence scan.
4. bootc-image-builder → qcow2 → QEMU boot test. Over the serial console, assert that the greenboot checks pass and that `org.ruyaos.Shell1.Ready` is true. Screenshot via QMP.
5. Update test: boot image N, `bootc switch` to N+1, reboot, assert. Then inject a failing health check and assert automatic rollback.
6. Sign and push on tags.

### 7.2 Test matrix
| Layer | How |
|---|---|
| Virtual | QEMU/KVM + virtio-gpu (virgl on Linux hosts). Functional only. |
| Hardware tiers | Low/mid/high reference boxes (00 §3). Weekly KPI runs. |
| Displays | Real TV over HDMI at 1080p and 4K; refresh switching; AVR passthrough (Phase 4) |
| Input | Xbox (wired, BT, dongle), DualSense/DS4 (USB, BT), generic XInput, keyboard, BT remote. Hot-plug and reconnect. |
| I/O | USB hot-plug (ext4/exFAT/NTFS/FAT32), Wi-Fi/Ethernet switch, headset/BT audio switch |
| Multi-user | Profile switch loops, PIN lockout, cross-profile access attempts |
| Soak | 24 h open/close app loop, media playback loop; watch RSS and VRAM |
| Update | Interrupted download, power loss during staging, failed health check |

## 8. Phase 0 checklist (exit criteria)

Legend: ✅ verified · 🟡 implemented, partly verified · ⬜ not started. Verified in QEMU/WHPX on 2026-10-22 unless noted.

| # | Item | Status | Where |
|---|---|---|---|
| 1 | `image/Containerfile` builds from `fedora-bootc:<N>`; `bootc container lint` clean | ✅ Fedora 44, 14 checks, `--fatal-warnings` | `image/Containerfile` |
| 2 | bootc-image-builder → qcow2 + anaconda-iso | ✅ qcow2 (40 GiB root) · ISO: see STATUS | `scripts/make-disk.sh`, `image/bib/disk.toml` |
| 3 | qcow2 boots in QEMU (UEFI, virtio); cage starts the QML shell fullscreen with animation + `MultiEffect` blur; no login prompt or desktop | ✅ `RUYA_BOOT_OK` about 4 s after the compositor starts (software rendering in the VM; blur only judged on host/GPU) | `ruya-compositor@.service`, `scripts/smoke-test.ps1` |
| 4 | Keyboard arrows move focus; a USB gamepad does the same | 🟡 keys ✅ on host; `ruya-inputd` runs in the VM; a gamepad needs hardware | `services/ruya-inputd` |
| 5 | A UI click plays through PipeWire | 🟡 the VM has no audio device (dummy sink); needs hardware or an `-audiodev` | `shell/sounds`, `SoundEffect` |
| 6 | Update N → N+1 and rollback, visible version change | ✅ 0.0.3 → 0.0.4 via `bootc switch` (about 2 min), `bootc rollback` → 0.0.3 | `docs/dev-setup.md` drill, `scripts/vm-reboot-check.ps1` |
| 7 | greenboot rolls back a broken image automatically | ✅ greenboot 0.16 (Rust) once its units are enabled: 4 failed boots, then GRUB fell back to the previous deployment | `/usr/lib/greenboot/check/required.d/`, `/etc/greenboot/greenboot.conf` |
| 8 | ISO installs on one real low-tier machine; frame time recorded | ⬜ needs hardware | — |
| 9 | `docs/dev-setup.md` reflects the setup actually used, including problems | ✅ setup, drill recipe and a 10-row problem log | `docs/dev-setup.md` |

CI (`.github/workflows/ci.yml`) covers 1–3 automatically on GitHub. It runs the token lint, Rust lint and tests, the shell build with qmllint and Qt Quick tests (Fedora container), the image build, the qcow2, and a headless QEMU boot that waits for `RUYA_BOOT_OK` on the serial port. The first three runs on `main` were green in every job.

Deferred out of Phase 0: safe-mode screen, VT-switch lockdown. (Plymouth is back in: the initramfs is now regenerated by `image/build/90-initramfs.sh`.)
