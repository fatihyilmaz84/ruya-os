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

**Use `scripts\dev.ps1` for everything below.** It wraps these commands with the right flags and PATH:

| Command | Does |
|---|---|
| `.\scripts\dev.ps1 check` | Prerequisites present? |
| `.\scripts\dev.ps1 test` | Rust fmt, clippy (Windows + Linux target) and tests; shell build; qmllint (zero warnings); Qt Quick tests. **Must be ALL GREEN before any commit.** |
| `.\scripts\dev.ps1 shots` | Qt Quick tests plus screenshots into `output\shell-shots\` |
| `.\scripts\dev.ps1 run` | The shell in a window with mock services |
| `.\scripts\dev.ps1 rust` / `shell` | Half of `test` |

The raw commands follow, for reference.

**Native Windows build (preferred).** Uses Visual Studio 2026 (C++ workload) and Qt 6.10.3 for MSVC, installed without admin rights by aqtinstall:

```powershell
python -m pip install aqtinstall
aqt install-qt windows desktop 6.10.3 win64_msvc2022_64 -m qtmultimedia qtshadertools --outputdir D:\dev\Qt
cmake -S shell -B shell\build-win -G "Visual Studio 18 2026" -A x64 -DCMAKE_PREFIX_PATH=D:/dev/Qt/6.10.3/msvc2022_64
cmake --build shell\build-win --config Release
$env:PATH = "D:\dev\Qt\6.10.3\msvc2022_64\bin;$env:PATH"; shell\build-win\Release\ruya-shell.exe --windowed
```

Without `--windowed` the shell takes the whole screen; quit with Alt+F4.

**Mock services.** Off Linux, the shell uses in-memory stand-ins for the system services automatically. On Linux, pass `--mock-services`, or set `RUYA_SERVICES=mock`. The mock profiles are:
- Player One (admin, PIN `1234`)
- Ada (no PIN)
- Guest

An orange "mock services" tag in the corner shows when the mock is active. The mock implements `CreateProfile` and `SetPin` with the service's rules, so adding profiles and changing PINs works in Settings -> Profiles (state lives in memory until restart). Tests reset it with `Profiles.resetMockForTests("seeded" | "empty")` (mock only).

**Display flags (session-only, never saved).** `--reduced-motion` forces reduced motion; `--effects high|balanced|performance` forces the effects quality tier. They are for perf testing, e.g. `ruya-shell.exe --windowed --effects performance --reduced-motion`. The saved values (`DeviceSettings`: reduced motion, effects quality, overscan) live in `QSettings` (org `ruyaos`, app `shell`); set `RUYA_SETTINGS_EPHEMERAL=1` to keep them in memory only (the tests do).

**Tests.** Qt Quick Tests drive the whole shell with the keys a controller produces. `dev.ps1 test` runs them offscreen: no window appears, and a locked screen or other windows can't disturb them.

```powershell
$env:PATH = "D:\dev\Qt\6.10.3\msvc2022_64\bin;$env:PATH"
ctest --test-dir shell\build-win -C Release --output-on-failure
$env:RUYA_SHOTS_DIR = "$PWD\output\shell-shots"; shell\build-win\Release\tst_ruyashell.exe   # also saves screenshots
cmake --build shell\build-win --config Release --target all_qmllint
```

`dev.ps1 shots` runs the same tests in real GPU windows and saves screenshots. Keep the desktop unlocked and leave the windows alone while it runs. Offscreen is the software renderer, where `MultiEffect` draws nothing, so effects only show up in `shots`.

**Against the real profiles service (Linux):** in `--session` mode the service uses the session bus and creates no Unix users, so it runs fine without root.

```bash
RUYA_PROFILES_FILE=/tmp/profiles.toml cargo run --manifest-path services/Cargo.toml -p ruya-profiles -- --session &
# first profile: no admin credentials needed, must be an admin with a PIN
busctl --user call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 CreateProfile sssss "" "" Me admin 1234
RUYA_DBUS=session RUYA_SERVICES=dbus shell/build/ruya-shell --windowed
```

**On Linux:** you don't have to reflash for QML changes. On any Linux machine or VM with Qt ≥ 6.8 (`qt6-qtdeclarative-devel qt6-qtmultimedia-devel`):

```bash
cmake -S shell -B shell/build -G Ninja && cmake --build shell/build && shell/build/ruya-shell --mock-services
```

## Known limits on this host
- QEMU on Windows renders through software, so FPS numbers there mean nothing.
- Gamepad passthrough into QEMU on Windows is unreliable. Test controllers on hardware or a Linux host (`-device usb-host,...`).

## Problems hit
_Log problems here as they come up (Phase 0 exit item 9)._
