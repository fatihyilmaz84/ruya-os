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

### Disk space: one working VM disk, no stale images

Image builds and VM disks are big (an image is ~4.7 GB, a qcow2 ~2.6 GB), and the WSL disk file lives on **C:** (`%LOCALAPPDATA%\wsl\{…}\ext4.vhdx`). Before 2026-10-24 every build left the previous image behind (70 GB of untagged images after two days) and every task made its own `tNNN.qcow2` copy. Now:
- `scripts/build.sh` removes, after a successful build, the untagged images that build did not use (it keeps the layers it used, so the cache still works). `RUYA_KEEP_IMAGES=1` skips it.
- **Use `smoke-test.ps1 -Work`** whenever the VM must keep state across boots (profiles, drives, the drill). It boots `output\qcow2\work.qcow2`, made fresh from `disk.qcow2` after every `make-disk.sh` and reused otherwise; delete it to start over. Never make a per-task copy. `smoke-test.ps1` warns about any other `.qcow2` in `output\qcow2`.
- Plain `smoke-test.ps1` (no `-Work`) boots `disk.qcow2` on a snapshot and writes nothing.
- The `.vhdx` does not shrink by itself when files inside WSL are deleted. One-time owner step: `wsl --manage FedoraLinux-44 --set-sparse true` after `wsl --shutdown`, so freed space goes back to C:.

In the VM, the shell's own log is `journalctl -b _UID=$(id -u ruya-shell)`. pam_systemd moves the compositor into `session-N.scope`, so `journalctl -u ruya-compositor@tty1` shows only the unit's start.

## Update / rollback drill (Phase 0 items 6–7; passed 2026-10-22)

1. Boot the working disk: `.\scripts\smoke-test.ps1 -Work -Keep` (delete `output\qcow2\work.qcow2` first for a fresh one). `vm-reboot-check.ps1` needs `-Disk output\qcow2\work.qcow2` then.
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
6. **Clean up** in WSL: `podman rm -f registry; podman rmi localhost:5000/ruyaos:<ver>` for every tag you pushed (each pins a ~4.7 GB image that `build.sh` never removes, because it is tagged).

## Seeing and driving the VM (T-120)

`smoke-test.ps1` and `run-vm.ps1` open QEMU's human monitor on `127.0.0.1:4444` (local only), and three scripts use it or the guest:

| Script | Does |
|---|---|
| `.\scripts\vm-screenshot.ps1 <name>` | `screendump` through the monitor, converted to `output\vm-shots\<name>.png` (System.Drawing only). |
| `.\scripts\vm-keys.ps1 right right ret` / `-Text Owner` / `-Text 2468 kp_enter` | `sendkey` per key; the guest sees a USB keyboard, so the shell gets the keys a controller produces. Digits and letters via `-Text` (capitals use shift). `-DelayMs` (default 250) is the pause per key; use 1500-3000 before steps that animate or open a modal. |
| `scripts/vm-inject-key.py guide [--hold 3]` (run in the guest) | Presses a key a USB keyboard cannot send: `guide` is `KEY_HOMEPAGE`, what `ruya-inputd` emits for the controller's Guide button; also `menu`, `home`, `meta`. Creates a throw-away uinput device, so cage and the shell see a real key event, held keys auto-repeat. |
| `scripts/vm-profiles-check.sh [state\|introspect\|security\|create\|lifecycle]` (run in the guest; `lifecycle` renames and deletes the profile `create` made, T-118) | What `ruya-profiles` lists over the system bus, `profiles.toml` (mode, hashes cut off), the `ruya-p*` Unix users and homes. |

Typical session (a persistent copy, so profiles survive reboots; `Enter` on a PIN pad is `kp_enter`, since `ret` presses the focused key):

```powershell
.\scripts\smoke-test.ps1 -Work -Keep
.\scripts\vm-screenshot.ps1 wizard-welcome
.\scripts\vm-keys.ps1 ret -DelayMs 1500
scp -i $env:USERPROFILE\.ssh\ruyaos_dev -P 2222 scripts\vm-*.sh scripts\vm-inject-key.py root@127.0.0.1:/root/
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-profiles-check.sh state
```

**Pitfalls.** The shell is software-rendered and CPU-bound in the VM (about 94 % of a core), so the screen can lag the keys by several seconds and the shell's own timers run slowly (the PIN lock countdown, for instance). Wait before a screenshot and before judging "nothing happened"; take a second screenshot first. PowerShell 5.1 binds extra arguments to later positional parameters: `vm-keys.ps1` sets `PositionalBinding = $false` for that reason. On a keyboard the Guide is **Super** (T-124): `vm-keys.ps1 meta_l` opens and closes the overlay. `sendkey menu` does nothing in the shell (Menu is the context-menu key, not Guide) and `home` is not a Guide key; to send the controller's Guide use `vm-inject-key.py guide`.

## Audio in the VM (T-121)

`smoke-test.ps1 -Audio` adds an Intel HDA sound card. `-AudioBackend dsound` (default) plays on the host's default output; `-AudioBackend wav` records everything the guest plays to `output\vm-audio.wav` (written as the VM runs, complete after it powers off), so a check needs no ears:

```powershell
.\scripts\smoke-test.ps1 -Work -Keep -Audio -AudioBackend wav
.\scripts\vm-keys.ps1 ret -DelayMs 2000; .\scripts\vm-keys.ps1 right left esc ret -DelayMs 1500
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-audio-check.sh   # copy it with scp first
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1 systemctl poweroff
python scripts\vm-audio-bursts.py                                                             # one burst per cue
```

`scripts/vm-audio-check.sh` (guest) shows the sound card, the `ruya-shell` user's PipeWire, WirePlumber and pipewire-pulse (pam_systemd gives the compositor session a user manager), `wpctl status` with the sink and the shell's stream, and the shell's audio log lines. `scripts/vm-audio-bursts.py` (host) lists the sounds in the recording (QEMU leaves the wav header sizes at zero, so `wave` cannot open it). The image has `pipewire-utils` since T-128 (`pw-dump`, which `ruya-devices` reads). `scripts/vm-devices-check.sh` (guest, run as root in a VM booted with `-Audio`, copy it with scp first) checks the `ruya-devices` user unit, the bus name owner, `ListSinks`, that a `MasterVolume`/`Muted` write reaches `wpctl`, and that another user is refused; `vm-devices-check.sh security` prints `systemd-analyze --user security`.

## Compositor spike (T-123)

The image ships `ruya-shell` as a Wayland compositor (`shell/spike/Compositor.qml`, loaded with `ruya-shell --load`), off by default. In a booted VM (`smoke-test.ps1 -Keep`, then `scp scripts/vm-compositor-spike.sh scripts/vm-inject-key.py root@127.0.0.1:/root/`):

```powershell
ssh ... root@127.0.0.1 bash /root/vm-compositor-spike.sh start    # cage stops; the spike compositor owns ruya-0
ssh ... root@127.0.0.1 bash /root/vm-compositor-spike.sh client   # the key-logging test client, fullscreen
.\scripts\vm-keys.ps1 a b c; .\scripts\vm-keys.ps1 meta_l          # keys reach the client; Super opens the overlay over it
ssh ... root@127.0.0.1 bash /root/vm-compositor-spike.sh log      # what the compositor and the client saw
ssh ... root@127.0.0.1 bash /root/vm-compositor-spike.sh stop     # back to cage
```

`lupdate`, `qmllint` and the Qt Quick tests never see `shell/spike/` (it is not in the `RuyaShell` module; the Windows Qt kit has no QtWaylandCompositor). A fresh disk copy has new SSH host keys: use `-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes`, or `ssh` waits for a host-key prompt that never shows.

## Power-policy check (T-107)

After any change to the polkit rule or to how `image/rootfs` is installed, boot the disk (`.\scripts\smoke-test.ps1 -Keep`) and run, from the repo root:

```bash
scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-power-check.sh root@127.0.0.1:/root/
ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-power-check.sh --power-off
```

It prints `pkcheck` verdicts for the six `login1` actions for the `ruya-shell` process (all must be `exit 0`) and for an ordinary user (none may be), logind's `CanPowerOff` for both, what the shell's Power backend read at start-up, the modes of what the image ships (nothing group- or world-writable), and, with `--power-off`, a refused `PowerOff` as the ordinary user followed by the real one as `ruya-shell` (QEMU exits). Without `--power-off` the VM stays up.

## Shell-only iteration

**Use `scripts\dev.ps1` for everything below.** It wraps these commands with the right flags and PATH:

| Command | Does |
|---|---|
| `.\scripts\dev.ps1 check` | Prerequisites present? |
| `.\scripts\dev.ps1 test` | Text lint (tracked text files are UTF-8 with no stray control characters or tabs); board lint (`docs/STATUS.md` and the task files agree, `scripts/lint-board.ps1`); Rust fmt, clippy (Windows + Linux target) and tests; shell build; token lint (no literal durations or colours outside `Theme.qml`); qmllint (zero warnings); Qt Quick tests. **Must be ALL GREEN before any commit.** |
| `.\scripts\dev.ps1 shots` | Qt Quick tests plus screenshots into `output\shell-shots\` (cleared first), and half-size copies in `output\shell-shots\review\` for reviewing at a quarter of the image tokens |
| `.\scripts\dev.ps1 run` | The shell in a window with mock services |
| `.\scripts\dev.ps1 rust` / `shell` | Half of `test` |
| `.\scripts\lint-tokens.ps1` | The token lint alone (also called by `dev.ps1 shell` and by CI). Exit 1 and a list of `file:line` on findings. |
| `.\scripts\lint-translations.ps1` | The translation lint alone (also called by `dev.ps1 shell` and by CI): fails on any `type="unfinished"` entry in `shell/i18n/*.ts`. `dev.ps1` passes `-LUpdateProject <build>\.lupdate\ruya-shell_lupdate_project.json`, which first refreshes temporary copies from the current sources (so a forgotten refresh and leftover `vanished`/`obsolete` entries fail too); CI checks the committed files only. Refresh the files with `cmake --build shell\build-win --config Release --target update_translations` (needs `lupdate`, in the Qt `bin`). |
| `.\scripts\lint-text.ps1` | The text lint alone (also called by `dev.ps1 test` and by CI). Checks the files `git ls-files` lists, so `git add` a new file before relying on it. Exit 1 and a list of `file:line` on findings. |
| `.\scripts\repro-first-build.ps1 [-Name X]` | Adds a scratch C++ QML type, runs `dev.ps1 shell` once, removes the type, rebuilds. Exit 0 means adding and removing a type works on the first run (T-116). Takes about 3 minutes; run it only if "X is not defined" ever comes back. |

### Local checks and CI

`.github/workflows/ci.yml` (workflow `ci`) runs on every push to `main`, every pull request and by hand (`workflow_dispatch`). It needs no secrets and has `contents: read` only; a newer push to the same ref cancels the run in progress.

| CI job | Runs | Local equivalent |
|---|---|---|
| `lint` | `pwsh scripts/lint-text.ps1`, `lint-board.ps1`, `lint-tokens.ps1`, `lint-translations.ps1` | the "text lint" and "board lint" steps of `dev.ps1 test` and the "token lint" and "translation lint" steps of `dev.ps1 shell` |
| `services` | `cargo fmt --check`, `clippy -D warnings`, `cargo test` (Ubuntu) | `dev.ps1 rust` |
| `shell` | build with Fedora's Qt (Fedora 44 container), `qmllint --max-warnings 0`, Qt Quick tests offscreen | `dev.ps1 shell` (Qt 6.10.3 on MSVC here; CI also proves that no API newer than Qt 6.8 crept in) |
| `image` | needs the three jobs above; `scripts/build.sh`, `make-disk.sh qcow2`, `smoke-test.sh` under KVM (about 20 minutes); uploads `serial.log` | the WSL build and `smoke-test.ps1` (image section above) |

The `image` job has no local equivalent in `dev.ps1 test`; run the WSL recipe for image changes.

**Reading a failed run.** Open the run from the Actions tab (or `https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs`, readable without login), find the red job and its first red step, and reproduce it locally with the equivalent above. For `image`, download the `serial-log` artifact: it is the full boot console, and `RUYA_BOOT_OK` / `RUYA_BOOT_FAIL` mark the verdict. A red `shell` job with a green local `test` usually means an API newer than Qt 6.8 or a difference between Fedora's and the MSVC build.

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

**Adding C++ QML types.** The Visual Studio generator puts "collect metatypes JSON" and "run `qmltyperegistrar`" in one MSBuild batch, and MSBuild decides what is stale before the batch runs. Without help, the first incremental build after adding, editing or removing a `QML_ELEMENT` header would reuse the old registration ("X is not defined", qmllint "Member not found", or a compile error for a removed type). `shell/CMakeLists.txt` therefore adds a target, `ruyashell_invalidate_stale_qmltypes` (script: `shell/cmake/InvalidateStaleQmlTypes.cmake`), that deletes the registrar outputs when `CMakeLists.txt` or a module header is newer than them. It is only added for Visual Studio generators. It costs well under a second per build.

**Mock services.** Off Linux, the shell uses in-memory stand-ins for the system services automatically. On Linux, pass `--mock-services`, or set `RUYA_SERVICES=mock`. The mock profiles are:
- Player One (admin, PIN `1234`)
- Ada (no PIN)
- Guest

To see the first-boot setup wizard (T-106), start the mock without profiles: `$env:RUYA_MOCK_PROFILES = "empty"; .\scripts\dev.ps1 run`. After you finish the wizard the shell shows the picker with your new profile. The mock forgets it when you close the window (PIN you chose, name you typed), so the next run starts at the wizard again. The chosen language is saved in `QSettings` (org `ruyaos`, app `shell`).

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

**On Linux:** you don't have to reflash for QML changes. On any Linux machine or VM with Qt ≥ 6.8 (`qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qttools-devel qt6-linguist`):

```bash
cmake -S shell -B shell/build -G Ninja && cmake --build shell/build && shell/build/ruya-shell --mock-services
```

## Known limits on this host
- QEMU on Windows renders through software (`MESA-EGL: failed to create dri2 screen` is expected), so FPS numbers there mean nothing.
- Gamepad passthrough into QEMU on Windows is unreliable. Test controllers on hardware or a Linux host (`-device usb-host,...`).
- `smoke-test.ps1` boots without a sound card unless asked (`-Audio`, see "Audio in the VM"). Without one the shell logs `QSoundEffect: playback of this format is not supported` once per cue and nothing plays. With one, the same three lines still appear at the first shell start of a session (a start-up race, benign: the cues play), but not when the shell restarts later.

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
