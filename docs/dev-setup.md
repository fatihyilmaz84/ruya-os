# Developer setup (Windows host)

Matches setup **A** in [01-platform §6.1](specs/01-platform.md): edit on Windows, build in a Linux VM, test functionally in QEMU, and measure KPIs on real hardware.

## One-time setup

1. **Enable WSL2.** This needs an elevated PowerShell and a reboot:
   ```powershell
   wsl --install --no-distribution
   ```
2. **Install Podman Desktop** (≥ 1.10) from podman-desktop.io. Create a Podman Machine that is **rootful**, with **≥ 6 GB RAM** and ≥ 60 GB disk. bootc-image-builder needs rootful mode.
   ```powershell
   podman machine init --rootful --memory 8192 --disk-size 80 --cpus 6
   podman machine start
   ```
3. **Install QEMU for Windows** (qemu.weilnetz.de) to the default path `C:\Program Files\qemu`, and turn on the Windows feature *Windows Hypervisor Platform* so QEMU can use WHPX.
4. Optional but recommended: a spare **low-tier mini-PC** (Intel NUC class) for hardware checks. Flash it from `output/anaconda-iso/` with Fedora Media Writer or Rufus (DD mode).

## Build → disk → boot

Run the build steps inside the Podman Machine (`podman machine ssh`), from the repo, which is mounted at `/mnt/d/dev/RuyaOS` on the WSL backend:

```bash
scripts/build.sh                 # -> localhost/ruyaos:dev
scripts/make-disk.sh qcow2       # -> output/qcow2/disk.qcow2
scripts/make-disk.sh anaconda-iso
```

Then boot the qcow2 on Windows:

```powershell
.\scripts\run-vm.ps1
```

On a Linux host with KVM, use `scripts/run-vm.sh` instead. For a headless check, run `scripts/smoke-test.sh`. It prints `RUYA_BOOT_OK <version>` once the shell has presented a frame.

To log into the VM, copy `image/bib/config.toml.example` to `image/bib/config.toml`, fill in your SSH key, and rebuild the disk. Then connect with `ssh -p 2222 dev@localhost`. In the VM, `journalctl -u ruya-compositor@tty1` shows the shell log.

## Update / rollback drill (Phase 0 items 6–7)

1. `scripts/build.sh 0.0.1` → `make-disk.sh qcow2` → boot. The corner of the screen shows `0.0.1`.
2. `scripts/build.sh 0.0.2`, push it to a registry the VM can reach (e.g. `podman push localhost/ruyaos:dev 10.0.2.2:5000/ruyaos:dev --tls-verify=false` with a local `registry:2` container). In the VM: `sudo bootc switch --transport registry 10.0.2.2:5000/ruyaos:dev` (configure an insecure registry first), then reboot. The screen shows `0.0.2`.
3. `sudo bootc rollback && sudo reboot`. The screen shows `0.0.1`.
4. Greenboot: build an image whose shell fails to start (e.g. `ExecStart=/bin/false`), switch to it, and confirm the VM rolls itself back after 3 boots.

## Shell-only iteration

**Native Windows build (preferred).** Uses Visual Studio 2026 (C++ workload) and Qt 6.10.3 for MSVC, installed without admin rights by aqtinstall:

```powershell
python -m pip install aqtinstall
aqt install-qt windows desktop 6.10.3 win64_msvc2022_64 -m qtmultimedia qtshadertools --outputdir D:\dev\Qt
cmake -S shell -B shelluild-win -G "Visual Studio 18 2026" -A x64 -DCMAKE_PREFIX_PATH=D:/dev/Qt/6.10.3/msvc2022_64
cmake --build shelluild-win --config Release
$env:PATH = "D:\dev\Qt.10.3\msvc2022_64in;$env:PATH"; shelluild-win\Releaseuya-shell.exe --windowed
```

Without `--windowed` the shell takes the whole screen; quit with Alt+F4.

**On Windows, without Qt or a VM:** run the scripted shell check with PySide6. It opens a GPU window for about 10 s, drives navigation and the overlay, asserts the focus rules, and saves screenshots to `output/shell-shots/`.

```powershell
python -m pip install PySide6==6.8.1
python tests\shell\check_shell.py
```

Don't use `QT_QPA_PLATFORM=offscreen` for this. It silently switches to the software renderer, where `MultiEffect` draws nothing.

**On Linux:** you don't have to reflash for QML changes. On any Linux machine or VM with Qt ≥ 6.5 (`qt6-qtdeclarative-devel qt6-qtmultimedia-devel`):

```bash
cmake -S shell -B shell/build -G Ninja && cmake --build shell/build && shell/build/ruya-shell
```

## Known limits on this host
- QEMU on Windows renders through software, so FPS numbers there mean nothing.
- Gamepad passthrough into QEMU on Windows is unreliable. Test controllers on hardware or a Linux host (`-device usb-host,...`).

## Problems hit
_Log problems here as they come up (Phase 0 exit item 9)._
