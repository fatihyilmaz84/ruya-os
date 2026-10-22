# Developer setup (Windows host)

Edit on Windows, build in a Fedora WSL distribution, boot in QEMU for Windows (WHPX), and measure KPIs on real hardware ([01-platform §6.1](specs/01-platform.md)). This is the setup actually in use since 2026-10-22.

## One-time setup (done on the main dev machine)

1. **WSL2** (admin + reboot): `wsl --install --no-distribution`.
2. **Fedora 44 WSL distribution** (no admin): `wsl --install FedoraLinux-44 --no-launch`. Use it as root (`wsl -d FedoraLinux-44 -u root`), then install the tools: `dnf -y install podman git qemu-img`. No Podman Desktop or Podman Machine is needed.
3. **QEMU for Windows** at `C:\Program Files\qemu`, with the *Windows Hypervisor Platform* feature on (WHPX acceleration, verified working).
4. **`%USERPROFILE%\.wslconfig`**: `memory=20GB` (the build uses a lot of memory). `nestedVirtualization=true` is also set but has no effect on this AMD host (`/dev/kvm` stays absent in WSL), so VMs run in Windows QEMU, not inside WSL.
5. **Dev VM access:**
   - an SSH key at `%USERPROFILE%\.ssh\ruyaos_dev` (`ssh-keygen -t ed25519 -N "" -f ...`);
   - `image/bib/config.toml` (git-ignored, copied from `config.toml.example`), which puts that key on `root` in test disks.
6. Optional but recommended: a spare **low-tier mini-PC** for hardware checks. Flash it from `output/anaconda-iso/` with Fedora Media Writer or Rufus (DD mode).

## Build → disk → boot

In WSL (`wsl -d FedoraLinux-44 -u root`; the repo is at `/mnt/d/dev/RuyaOS`):

```bash
cd /mnt/d/dev/RuyaOS
scripts/build.sh 0.0.5        # -> localhost/ruyaos:dev; first build ~30 min, later ~3-10 min (layer cache)
scripts/make-disk.sh qcow2    # -> output/qcow2/disk.qcow2, ~9 min, 40 GiB sparse root
```

The build runs `bootc container lint --fatal-warnings`: any lint warning fails it.

Then, on Windows:

```powershell
.\scripts\smoke-test.ps1                # headless boot; prints RUYA_BOOT_OK <version> when the shell has drawn a frame (~1 min)
.\scripts\smoke-test.ps1 -Keep          # same, but leave the VM running
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1   # use 127.0.0.1, not localhost (IPv6)
.\scripts\run-vm.ps1                    # with a window, to look at the shell (software rendering)
```

In the VM, the shell's own log is `journalctl -b _UID=$(id -u ruya-shell)`. pam_systemd moves the compositor into `session-N.scope`, so `journalctl -u ruya-compositor@tty1` shows only the unit's start.

## Update / rollback drill (Phase 0 items 6–7; passed 2026-10-22)

1. Put a persistent copy of the disk in place: `Copy-Item output\qcow2\disk.qcow2 output\qcow2\drill.qcow2`. Boot it with `.\scripts\smoke-test.ps1 -Disk output\qcow2\drill.qcow2 -Persistent -Keep`.
2. **Registry**, in WSL:
   ```bash
   podman run -d --name registry --network host docker.io/library/registry:2
   podman tag localhost/ruyaos:dev localhost:5000/ruyaos:<ver>
   podman push --tls-verify=false localhost:5000/ruyaos:<ver>
   ```
   **The VM must use WSL's IP, not 10.0.2.2.** WSL localhost forwarding doesn't work on this host. Get the IP with `wsl -d FedoraLinux-44 -- ip -4 addr show eth0`; it changes when WSL restarts. In the VM, mark that registry as insecure in `/etc/containers/registries.conf.d/50-ruyaos-dev.conf`:
   ```toml
   [[registry]]
   location = "<wsl-ip>:5000"
   insecure = true
   ```
3. **Update:** in the VM, `bootc switch <wsl-ip>:5000/ruyaos:<ver>` (about 2 minutes). Then `.\scripts\vm-reboot-check.ps1`, which reboots, waits for the shell, and prints the deployments and greenboot's verdict.
4. **Manual rollback:** `bootc rollback`, then `.\scripts\vm-reboot-check.ps1`.
5. **Automatic rollback (greenboot):** build an image whose compositor is `ExecStart=/bin/false`, `bootc switch` to it, and reboot. Every boot fails the shell health check and greenboot reboots; after 3 failed boots GRUB falls back to the previous deployment. Results are in `docs/STATUS.md`, session log 2026-10-22.

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
- QEMU on Windows renders through software (`MESA-EGL: failed to create dri2 screen` is expected), so FPS numbers there mean nothing.
- Gamepad passthrough into QEMU on Windows is unreliable. Test controllers on hardware or a Linux host (`-device usb-host,...`).
- The test VM has no audio device. The shell logs `QSoundEffect: playback of this format is not supported` against PipeWire's dummy output; UI sound is unverified in VMs.

## Problems hit (Phase 0 exit item 9)

| Problem | Cause | Fix / workaround |
|---|---|---|
| Shell never reported ready, though it was running | pam_systemd moves the compositor into `session-N.scope`; the check searched the unit's log | `wait-shell-ready` matches `_UID` of `ruya-shell` (also used by greenboot) |
| No automatic rollback at all | greenboot units are preset-disabled in Fedora | Enabled in the Containerfile; stock DNS check disabled (would roll back offline boots) |
| `bootc switch` failed to stage | default bib root (~10 GB) can't hold two 4.7 GB deployments | `image/bib/disk.toml`: 40 GiB minimum root; `bootc-generic-growpart` grows existing disks after `qemu-img resize` |
| VM couldn't reach the registry | WSL localhost forwarding doesn't work here; Podman port NAT is invisible to it anyway | Registry on `--network host`, VM uses WSL's IP |
| QEMU hangs at "reboot: Restarting system" (0% CPU) | WHPX reset bug | QEMU runs with `-no-reboot`; `vm-reboot-check.ps1` cold-starts it again |
| `Start-Process` split `C:\Program Files\...` | PS 5.1 doesn't quote array arguments | `smoke-test.ps1` quotes arguments that contain spaces |
| `ssh localhost` refused | `localhost` resolves to IPv6 first; QEMU listens on IPv4 only | Use `127.0.0.1` |
| Lint warnings: `/run` content, the `akmods` user, `/var` without tmpfiles | Build leftovers | `99-cleanup.sh`, `40-nvidia.sh` (`userdel`), `95-var-tmpfiles.sh` (generated entries) |
| `ruya-shell` not in `video`/`render` | Those groups live in `/usr/lib/group` on bootc; sysusers can't edit them | Not needed: logind grants seat0 device ACLs. Lines removed. |
| Quoting through PowerShell → `wsl`/`ssh` → shell mangles `$?`, `|`, quotes | Several layers of quoting | Put multi-step commands in script files (`output/*.sh`) and run them |
