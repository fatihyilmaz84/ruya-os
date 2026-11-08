# Developer setup (Windows host)

Edit on Windows, build in a Fedora WSL distribution, boot in QEMU for Windows (WHPX), and measure KPIs on real hardware ([01-platform §6.1](specs/01-platform.md)). This is the setup actually in use since 2026-10-22.

## One-time setup (done on the main dev machine)

1. **WSL2** (admin + reboot): `wsl --install --no-distribution`.
2. **Fedora 44 WSL distribution** (no admin): `wsl --install FedoraLinux-44 --no-launch`. Use it as root (`wsl -d FedoraLinux-44 -u root`), then install the tools: `dnf -y install podman git qemu-img`. No Podman Desktop or Podman Machine is needed.
3. **QEMU for Windows** at `C:\Program Files\qemu`, with the *Windows Hypervisor Platform* feature on (WHPX acceleration, verified working).
4. **`%USERPROFILE%\.wslconfig`**: `memory=8GB` and `nestedVirtualization=false`. (It was 20 GB with nested virtualization on until 2026-10-27, when WSL's `ext4` kept going read-only during builds; after lowering it and recreating the distro, builds ran clean. Nested virtualization has no effect on this AMD host anyway: `/dev/kvm` stays absent in WSL, so VMs run in Windows QEMU, not inside WSL.) If `dmesg` in WSL shows `ext4` errors, recreate the distro (`wsl --unregister FedoraLinux-44`, step 2 again; it holds only packages).
5. **Dev VM access:**
   - an SSH key at `%USERPROFILE%\.ssh\ruyaos_dev` (`ssh-keygen -t ed25519 -N "" -f ...`);
   - `image/bib/config.toml` (git-ignored, copied from `config.toml.example`), which puts that key on `root` in test disks. A git-ignored file is not in a fresh worktree: copy it from the main checkout first, or `make-disk.sh` stops with an error (`make-disk.sh --check-config` tests this without building; `RUYA_NO_DEV_KEY=1` builds a keyless disk on purpose, as CI does).
6. Optional but recommended: a spare **low-tier mini-PC** for hardware checks. Flash it from `output/bootiso/install.iso` ("Installer ISO" below) with Fedora Media Writer or Rufus (DD mode).

## Build → disk → boot

In WSL (`wsl -d FedoraLinux-44 -u root`; the repo is at `/mnt/d/dev/RuyaOS`):

```bash
cd /mnt/d/dev/RuyaOS
scripts/build.sh 0.0.5        # -> localhost/ruyaos:dev; first build ~30 min, later ~3-10 min (layer cache)
scripts/make-disk.sh qcow2    # -> output/qcow2/disk.qcow2, ~9 min, 40 GiB sparse root
```

The build runs `bootc container lint --fatal-warnings`: any lint warning fails it. Since T-195 it also runs `image/build/98-guard.sh`, which fails the build for a banned package (desktop environment, printing daemon, `sssd`, `samba`, `qemu-user`, ...) or an enabled unit that is not in `image/build/enabled-units.txt`, and prints `98-guard: <n> packages, /usr <n> MiB`. Any edit under `image/build/` rebuilds from the first `RUN` (the NVIDIA step, ~15 min); to try a change to `50-slim.sh`, `96-services.sh` or `98-guard.sh` first, run it in the last image: `podman run --rm -v $PWD/image/build:/b:ro localhost/ruyaos:dev bash /b/50-slim.sh` (a throw-away container; it prints the dnf transaction and refuses a protected package).

After a build, `scripts/check-image-manifest.sh` (in WSL, repo root, ~10 s) compares `dnf leaves` of `localhost/ruyaos:dev` with the packages named in `docs/image-packages.md` and fails for a leaf nobody gave a reason; add the row there when you add a package.

Then, on Windows:

```powershell
.\scripts\smoke-test.ps1                # headless boot; prints RUYA_BOOT_OK <version> when the shell has drawn a frame (~1 min)
.\scripts\smoke-test.ps1 -Keep          # same, but leave the VM running
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1   # use 127.0.0.1, not localhost (IPv6)
.\scripts\run-vm.ps1                    # with a window, to look at the shell (software rendering)
```

### Trying it in a window

`.\scripts\run-vm.ps1` opens the VM in a QEMU window (SDL) with sound. Start it only after `make-disk.sh` has finished: it boots `output\qcow2\disk.qcow2` itself, not a snapshot, so what you do there (the wizard's profile, settings) stays on that disk until the next `make-disk.sh`. Close the window to stop the VM. The real services run, no mocks. Expect it to be slow (software rendering, no GPU) and to start with the first-boot wizard on a fresh disk. Keys: arrows move, Enter = A, Esc or Backspace = B (in a text field Backspace deletes), Super = Guide (hold it for the power choices), PgUp/PgDn = LB/RB.

### Installer ISO (real hardware)

In WSL, after `build.sh`: `scripts/make-disk.sh anaconda-iso` writes `output/bootiso/install.iso` (about 3.3 GiB, ~3 min). Write it to a USB stick with Fedora Media Writer or Rufus (DD mode).
- **The install is fully automatic and erases every disk in the machine** (bootc-image-builder's kickstart: `clearpart --all`, autopart, xfs, reboot). Unplug any disk you want to keep.
- It carries the dev SSH key from `image/bib/config.toml` on `root`: **for test machines only**.
- The installed system tracks `localhost/ruyaos:dev`, so it does not update until you `bootc switch` it to a registry.
- Anaconda leaves `/etc/systemd/system/default.target` at `multi-user.target` (the image's own `graphical.target` is overridden). That is fine since 0.0.41: `ruya-compositor@.service` and `ruya-boot-marker.service` are `WantedBy=graphical.target multi-user.target`, so the installed system reaches the shell whichever default target it has (T-178; before that the install booted to text mode and greenboot rebooted it in a loop).
- The installed system's boot entries and `PRETTY_NAME` say `RuyaOS <version>` (`image/build/92-branding.sh`; `ID`, `VERSION_ID`, `ID_LIKE` stay Fedora's). The ISO's own boot menu is bootc-image-builder's and still says Fedora.

**Power saving timeouts (T-202).** `RUYA_IDLE_DIVISOR=60` in the shell's environment divides every power-saving time by 60 (10 minutes become 10 seconds: screen saver, display off, sleep and idle controllers), for the VM and the Dell; on the image set it as `Environment=RUYA_IDLE_DIVISOR=60` in a drop-in of the compositor unit (`systemctl edit ruya-compositor@tty1`) and restart it. `RUYA_SUSPEND_VERIFIED=1` makes the Sleep step available without `/usr/share/ruyaos/suspend-verified`. Every `ruya-shell: idle inhibit +/-<reason>` and `ruya-shell: display on/off` line is in the journal. `scripts/vm-power-saving-check.sh` is the lead's VM check; its `timeline` part wakes the display with a uinput key itself (copy `scripts/vm-inject-key.py` next to it) and checks that frames are produced again (CRTC active, dpms On, no page-flip error, a delivered vblank event counted through tracefs).

**VM check scripts on the host (T-296).** `scripts/lint-vm-checks.ps1` (part of `dev.ps1 test` and the CI lint job) runs `bash -n` on every `scripts/vm-*.sh`, requires the exec bit (`git ls-files -s`: 100755), parses every `vm-*.ps1`, runs `scripts/test-vm-checks.sh` (the parts of the checks that work on canned `busctl` output and fake tools: volume records read by key in any key order, a refused action is `pkcheck` exit 1, an error reply from `ListVolumes` is not "the volume left the list", cleanup after an early failure of `vm-sample-check.sh`) and, on Windows, requires `vm-iso-check.ps1` to refuse `output\qcow2\disk.qcow2` and `work.qcow2` as `-Disk`. `vm-storage-check.sh` and `vm-devices-check.sh` end early when sourced with `VM_CHECK_LIB_ONLY=1`, so the tests can call their helpers.

To test an ISO in QEMU: `.\scripts\vm-iso-check.ps1` (about 10 minutes; a lead-run check, not part of `dev.ps1 test`). It makes a blank 64 GiB `output\iso-test.qcow2`, boots QEMU with the ISO as a CD (as `smoke-test.ps1` does, without monitor or port forward) until the serial log shows `Install finished` (QEMU exits because of `-no-reboot`), then runs `smoke-test.ps1 -Disk ... -Persistent -Keep` on the installed disk and reads over SSH `systemctl get-default`, the version, the os-release name, the installed disk's boot entry titles (`/boot/loader/entries/*.conf`) and greenboot's state. It passes (`ISO CHECK PASSED`, exit 0) only when the first boot prints `RUYA_BOOT_OK` and greenboot's health check and `greenboot-success.target` are active. It deletes the test disk at the end, also on failure (`-KeepDisk` keeps it), and refuses to start while a QEMU is running or when `-Disk` (relative to the repository, or absolute) is not a file inside `output\` (T-193; the script deletes it).

### Disk space: one working VM disk, no stale images

Image builds and VM disks are big (an image is ~4.7 GB, a qcow2 ~2.6 GB), and the WSL disk file lives on **F:** (`F:\wsl\ext4.vhdx`, moved from C: on 2026-11-07 with `wsl --manage FedoraLinux-44 --move F:\wsl`, 18 minutes for 40 GB; F: is a USB drive, so builds there are slower than on the internal SSD: the first build after the move is measured in LEAD-NOTES; moving back is the same command). Before 2026-10-24 every build left the previous image behind (70 GB of untagged images after two days) and every task made its own `tNNN.qcow2` copy. Now:
- `scripts/build.sh` removes, after a successful build, the untagged images that build did not use (it keeps the layers it used, so the cache still works). `RUYA_KEEP_IMAGES=1` skips it.
- **Use `smoke-test.ps1 -Work`** whenever the VM must keep state across boots (profiles, drives, the drill). It boots `output\qcow2\work.qcow2`, made fresh from `disk.qcow2` after every `make-disk.sh` and reused otherwise; delete it to start over. Never make a per-task copy. `smoke-test.ps1` warns about any other `.qcow2` in `output\qcow2`.
- Plain `smoke-test.ps1` (no `-Work`) boots `disk.qcow2` on a snapshot and writes nothing.
- The `.vhdx` does not shrink by itself when files inside WSL are deleted. One-time owner step: `wsl --manage FedoraLinux-44 --set-sparse true` after `wsl --shutdown`, so freed space goes back to C:.

In the VM, the shell's own log is `journalctl -b _UID=$(id -u ruya-shell)`. pam_systemd moves the compositor into `session-N.scope`, so `journalctl -u ruya-compositor@tty1` shows only the unit's start.

### Adding an icon (T-157)

The shell's icons come from a subset of Material Symbols Rounded (`shell/fonts/`, 04 §3.7). To add one: look up its code point in the upstream `.codepoints` file, add `<name> <hex>` to `shell/fonts/icons.txt` and the same pair to the table in `shell/qml/Icon.qml`, then cut the fonts again in WSL (`python3-fonttools` installed; no other setup):

```bash
cd /mnt/d/dev/RuyaOS && scripts/subset-icons.sh
```

The script downloads the variable font from a pinned upstream commit into a temporary directory (SHA-256 checked), checks every `icons.txt` pair against upstream, and rewrites the two static cuts (outlined, filled) in `shell/fonts/`. It also installs `skia-pathops` into a throwaway virtual environment inside that directory with `pip install --require-hashes -r scripts/subset-icons-requirements.txt` (pinned version, SHA-256 of the manylinux wheels, no source builds; T-297), so it needs network, and merges the glyphs' overlapping contours (`--remove-overlaps`): without that the filled cut draws speckled on Windows. `scripts/check-font-coverage.py` fails when a cut still has coincident contours or overlapping ones of the same winding (T-297; its geometry self-test is `python -I scripts/check-font-coverage.py --self-test`, also part of `dev.ps1 test`). Lines of `icons.txt` that end in the word `ruya` (`pad_playstation`, `pad_xbox`, `pad_switch`, T-199) are our own controller silhouettes, not Material's: `scripts/subset-icons.sh` skips the upstream check for them (it only checks that the private-use code point is not Material's) and runs `scripts/add-pad-glyphs.py` on both cuts, which draws them (shapes and numbers are in that file, previewable by rendering the cut with any font viewer) and needs the same `skia-pathops` as `--remove-overlaps`. To change a silhouette, edit that script and re-run the cut. Commit the TTFs with the list. `scripts/lint-icons.ps1` (part of `dev.ps1 shell`) fails when the list and the table differ, and `scripts/check-font-coverage.py` fails when a code point of the list has no glyph in either cut (T-223: forgot to re-cut).

The typeface (Inter 4.1, OFL-1.1) is cut the same way: `scripts/fetch-inter.sh` in WSL (`python3-fonttools`, `unzip`) downloads the pinned release zip into a temporary directory, checks its SHA-256, extracts a fixed list of members and writes the three subset TTFs and `OFL-Inter.txt` to `shell/fonts/`.

The glass grain tile (`shell/assets/glass-grain.png`, 128x128, T-204) is made by `python -I scripts/make-grain.py` (standard library only, a fixed pseudo-random sequence, so the PNG is reproducible; `--check` says whether the committed file matches). There is no switch to turn the glass layers off one by one; to see a surface without them, set the tier: `ruya-shell.exe --windowed --effects performance` has no grain, no shadows, no glare or shimmer, `--reduced-motion` has no glare or shimmer.

The bundled wallpapers (`shell/assets/wallpapers/*.jpg` and `catalog.json`, T-208) are made by `python -I scripts/make-wallpapers.py` (needs Pillow and numpy; formulas and a seeded dither, no source images; the JPEG bytes depend on the libjpeg Pillow bundles). `catalog.json` carries each picture's `peak` and `floor` brightness, which the shell uses to veil a wallpaper until the theme's text stays legible (`04` §3.5). Wallpaper tests (`tst_wallpaper.qml`) use the mock USB stick: `Wallpapers.mockPrepareUsb()` writes a folder of made-up pictures into a temporary directory and the mock stick's mount point reads from it; the wallpaper library lives in a temporary directory while settings are ephemeral. On a real machine the copies are in `~/.local/share/ruya-shell/wallpapers` of the shell user (`RUYA_WALLPAPER_DIR` overrides it), with an `index.json`; `--windowed` development uses the same folder under your profile.

## Developer guide and the sample game (T-214)

`docs/developers/` is the guide for people who make games for RuyaOS; `samples/hello-game/` is the sample it describes (C, SDL 3, CC0). Two checks belong to it:

- `scripts/lint-dev-docs.ps1` (part of `dev.ps1 test`, and the CI lint job): every relative link and `#anchor` in `docs/developers/` resolves, every chapter is listed in the README and the README lists only chapters that exist, `python` blocks parse (`ast`), `sh`/`bash` blocks pass `bash -n` (Git's bash on Windows, never the WSL launcher), `xml` blocks are well-formed, `json` blocks parse, a `c` block whose first line is `/* sample: <path> */` is made of lines of that file in order (`...` is a gap), and every chapter ends with `## Sources` naming a date. `dev.ps1 test` also feeds the lint a clean fixture folder and eight broken ones (a dead link, a dead anchor, bad Python, bad shell, bad XML, bad JSON, an unlisted chapter, no Sources) and requires the right verdict for each. Needs `python` and `bash` on PATH (Git for Windows has bash; Python 3 must be on PATH).
- `scripts/vm-sample-check.sh` (guest, as root; a **lead run**, not part of `dev.ps1 test`): installs the sample from a local repository (the runtime `org.freedesktop.Platform//26.08` comes from Flathub, so the guest must be online), launches it for a profile through `Session1.Launch`, checks that it wrote `~/.var/app/org.ruyaos.HelloGame/data/saves/slot1.sav` (owned by the profile, home 0700), that `Stop` makes it save once more and exit within the 5 s grace with reason `quit`, that a second launch loads the save (`plays=2`), that a torn newest save falls back to the `.bak`, and that `Store1.Uninstall(delete_data=false)` keeps the save. The game runs with SDL's dummy video and audio drivers (a `flatpak override`, removed at the end) because profile apps have no Wayland socket yet (T-164). Build the repository in WSL as in `samples/hello-game/README.md`, `tar -C ~/hello-game -czf hello-repo.tgz repo`, then:

```powershell
scp -i $env:USERPROFILE\.ssh\ruyaos_dev -P 2222 hello-repo.tgz scripts\vm-sample-check.sh root@127.0.0.1:/root/
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-sample-check.sh
```

Building the sample needs `flatpak`, `flatpak-builder` and `appstream` in the WSL distribution (`dnf -y install flatpak flatpak-builder appstream`) and network for the runtime and SDK (about 1 GB, kept in the WSL user's Flatpak installation). Keep build and repository directories out of the repository (`samples/hello-game/.gitignore` covers `build-dir/`, `repo/`, `.flatpak-builder/`); `flatpak-builder` on `/mnt/d` is slow and its `rofiles-fuse` mount can be left busy by a failed build, so build in a copy under the WSL home.

## Sound themes and the generator (T-227)

The shell's UI sounds and ambient bed come from a sound theme (`docs/developers/sound-themes.md`, `02` §5.3). The bundled theme `shell/sounds/dreamglass/` and the example `samples/sound-theme-example/` are written by `scripts/make-sounds.py` (Python 3 with numpy; no other samples are used, so they are CC0):

```powershell
python -I scripts\make-sounds.py            # rewrite both from the numbers in the script
python -I scripts\make-sounds.py --verify   # deterministic? within the limits? seams smooth? files up to date?
.\scripts\lint-sound-themes.ps1             # --verify, then the shell's own checker over both themes and its fixtures
```

`dev.ps1 shell` (so `test`) runs `lint-sound-themes.ps1` after the build, because the checker is part of `ruya-shell` (`ruya-shell --check-sound-theme <folder>...`, `--check-sound-theme-fixtures`). A theme for the dev build: set `RUYA_SOUND_DIR` to a folder that holds your theme folders, and they are listed in Settings -> Audio -> Sound theme. `RUYA_SOUNDS_DIR` replaces the folder that holds the bundled theme (tests only); `RUYA_SOUNDS_DRY=1` gives the ambient players no file (the Qt Quick tests set it).

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
5. **Automatic rollback (greenboot):** build a broken image on top of the pushed one (T-130 used a two-line Containerfile `FROM <wsl-ip>:5000/ruyaos:<ver>` adding a drop-in `ruya-compositor@.service.d/50-broken.conf` with `Environment=QT_QPA_PLATFORM=nonexistent`), push it, `bootc switch` to it, and reboot. QEMU exits at each greenboot reboot (`-no-reboot`): cold-start it with `smoke-test.ps1 -Work -Keep` until a boot prints `RUYA_BOOT_OK` (each failed boot takes about 2 minutes). Every boot fails the shell health check and greenboot reboots; after 3 failed boots GRUB falls back to the previous deployment. Results are in `docs/STATUS.md`, session log 2026-10-22.
6. **Clean up** in WSL: `podman rm -f registry; podman rmi localhost:5000/ruyaos:<ver>` for every tag you pushed (each pins a ~4.7 GB image that `build.sh` never removes, because it is tagged).

## Seeing and driving the VM (T-120)

`smoke-test.ps1` and `run-vm.ps1` open QEMU's human monitor on `127.0.0.1:4444` (local only), and three scripts use it or the guest:

| Script | Does |
|---|---|
| `.\scripts\vm-screenshot.ps1 <name>` | `screendump` through the monitor, converted to `output\vm-shots\<name>.png` (System.Drawing only). |
| `.\scripts\vm-goto.ps1 <target>` | Past the wizard to a named page and a screenshot of it (T-141, below). |
| `.\scripts\vm-keys.ps1 right right ret` / `-Text Owner` / `-Text 2468 kp_enter` | `sendkey` per key; the guest sees a USB keyboard, so the shell gets the keys a controller produces. Digits and letters via `-Text` (capitals use shift). `-DelayMs` (default 250) is the pause per key; use 1500-3000 before steps that animate or open a modal. |
| `scripts/vm-devices-check.sh inputd` (run in the guest, as root) | Proves `ruya-inputd` releases a vanished pad's keys (T-337): creates virtual gamepads through `/dev/uinput`, destroys one that holds Down and A, and reads the key state of `RuyaOS Navigation` with `EVIOCGKEY`; then two pads share Down. Prints `UNVERIFIED` (and passes nothing) if root has no `/dev/uinput`. |
| `scripts/vm-inject-key.py guide [--hold 3]` (run in the guest) | Presses a key a USB keyboard cannot send: `guide` is `KEY_HOMEPAGE`, what `ruya-inputd` emits for the controller's Guide button; also `menu`, `home`, `meta`. Creates a throw-away uinput device, so cage and the shell see a real key event, held keys auto-repeat. |
| `.\scripts\vm-storage-check.ps1` (VM started with `smoke-test.ps1 -Keep`; drives `scripts/vm-storage-check.sh [baseline\|format\|gone\|watch\|plugged\|scan\|busy\|eject\|mformat\|mplugged\|meject\|security]` in the guest, T-174, T-184) | Hot-plugs a 64 MiB USB stick through the QEMU monitor (`drive_add` + `device_add usb-storage`): the guest formats it exFAT, the stick is detached and attached again while the service watches. Checks `ListVolumes`, `VolumeAdded` before `VolumesChanged`, the `nosuid,nodev,noexec` mount, that a program on the stick does not run, `free_bytes`, the polkit verdicts, then (T-331, step `scan`) the drive scan: it makes `RuyaOS/ROMs/snes/a.bin` (3 MiB), `RuyaOS-Backups/p/b.tar.zst` (1 MiB), a stray 1 MiB file, a `run.sh` that would `touch /tmp/scan-ran` and a tree 10 levels deep, runs `ScanVolume` and prints the `GetVolumeScan` numbers (`state`, `partial`, `used_bytes`, `other_bytes` and one `cat_<key>` line per category). It checks that `used_bytes` is within 5 % of `du`, that games and backups show their sizes and the parts add up, that `/tmp/scan-ran` does not exist, that the deep tree ends `partial`, that `VolumeScanChanged` was sent and that a second call answers from the cache; then `busy` and `ok` from `Eject`. Then (T-184) a second 96 MiB stick with a GPT and three partitions (two exFAT, one ext2 the service does not mount): all three listed with the same `drive`, the ext2 one `unknown` and unmounted, one `VolumeAdded` per partition, and `Eject` of one partition takes the whole drive. |
| `scripts/vm-profiles-check.sh [state\|introspect\|security\|create\|lifecycle]` (run in the guest; `lifecycle` renames and deletes the profile `create` made, T-118) | What `ruya-profiles` lists over the system bus, `profiles.toml` (mode, hashes cut off), the `ruya-p*` Unix users and homes. |

Typical session (a persistent copy, so profiles survive reboots; `Enter` on a PIN pad is `kp_enter`, since `ret` presses the focused key):

```powershell
.\scripts\smoke-test.ps1 -Work -Keep
.\scripts\vm-screenshot.ps1 wizard-welcome
.\scripts\vm-keys.ps1 ret -DelayMs 1500
scp -i $env:USERPROFILE\.ssh\ruyaos_dev -P 2222 scripts\vm-*.sh scripts\vm-inject-key.py root@127.0.0.1:/root/
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-profiles-check.sh state
```

**`vm-goto.ps1`** (T-141): after `smoke-test.ps1 -Work -Keep`, `.\scripts\vm-goto.ps1 settings-network` (about a minute) takes the VM to `home`, `store`, `settings-myprofile`, `settings-profiles` (Manage profiles, admins), `settings-network`, `settings-audio` or `settings-system` (the VM's profile is an admin, so Manage profiles is listed; T-315 moved the Settings keys down by one) and saves `output\vm-shots\<target>.png`. On an empty disk it walks the wizard with fixed answers: English, admin "Player One", PIN `1234`. If a profile exists it locks the session, restarts `ruya-compositor@tty1` so the shell starts at the picker, and signs in with PIN `1234` (a disk whose first profile has another PIN needs a fresh `-Work` disk). Keys are paced by `-SettleMs`, because the backdrop never stops moving and a still screen never comes; the wizard's result and the sign-in are checked over SSH (`busctl` on `Profiles1`). An unknown target or a VM that is not running fails within seconds; a check that shows nothing within `-StepTimeoutSec` (90) fails naming its step.

**Pitfalls.** The shell is software-rendered and CPU-bound in the VM (about 94 % of a core), so the screen can lag the keys by several seconds and the shell's own timers run slowly (the PIN lock countdown, for instance). Wait before a screenshot and before judging "nothing happened"; take a second screenshot first. PowerShell 5.1 binds extra arguments to later positional parameters: `vm-keys.ps1` sets `PositionalBinding = $false` for that reason. On a keyboard the Guide is **Super** (T-124): `vm-keys.ps1 meta_l` opens and closes the overlay. `sendkey menu` does nothing in the shell (Menu is the context-menu key, not Guide) and `home` is not a Guide key; to send the controller's Guide use `vm-inject-key.py guide`.

## Boot experience: splash, silent boot, boot menu (T-269)

The boot is silent and has no menu; spec `01-platform.md` §2.1 says how. To work on it:

- **See the menu.** Tap **Esc once** while the machine starts (a hidden 2 s window after the firmware; a second Esc leaves the menu for the `grub>` prompt, type `exit`). In the VM: `smoke-test.ps1 -Work -Keep`, then `.\scripts\vm-boot-shots.ps1 -Tag menu -Seconds 12 -Key esc -KeyFromMs 1300 -KeyCount 1` (OVMF treats an Esc before 1 s as "enter firmware setup"). After a boot that failed (greenboot has not seen the shell) the menu shows by itself for 5 s. Entries read "RuyaOS <version> (ostree:N)". Nothing helps a keyboard that the firmware has not started yet; with firmware fast boot on, hold the key from power-on or turn it off.
- **Watch the screen while it boots.** Start the VM, then at once `.\scripts\vm-boot-shots.ps1 -Tag cold -Seconds 60` (one monitor connection, a screendump every -IntervalMs, default 500, `output\boot-shots\<Tag>\<elapsed ms>.ppm`), then `python -I scripts\vm-boot-sheet.py cold 8 240` turns the dumps into PNGs and a contact sheet (`_sheet.png`) and prints when the screen changed. The first frames are the firmware's own (OVMF prints "BdsDxe" lines and the TianoCore logo; real firmware shows its logo), then the splash, a dark gap while the shell starts, then the shell. Any console text in between is a bug.
- **Check a booted VM:** `scripts/vm-boot-check.sh` over ssh (kernel arguments, theme, GRUB policy on the disk, no getty on tty1, the splash-to-shell timeline from the journal). **Check the image:** `scripts/check-boot-config.sh` in WSL (theme and plugin in the initramfs, kargs, GRUB policy files, units). **Check the sources:** `scripts/lint-boot.ps1` (part of `dev.ps1 test`).
- **Change the look.** The images are drawn by `python -I scripts/make-boot-assets.py` (Pillow) into `image/rootfs/usr/share/plymouth/themes/ruyaos/`; `ruyaos.script` places them. To try a change without a rebuild, in the VM stop the shell (`systemctl stop ruya-compositor@tty1`), bind-mount your theme directory over `/usr/share/plymouth/themes/ruyaos`, run `plymouthd --mode=boot --attach-to-session; plymouth show-splash` and take a screenshot; `plymouth quit` and `systemctl start ruya-compositor@tty1` bring the shell back. The initramfs copy only changes with an image build.
- **A disk made before this task** keeps its old `grub.cfg` (an update does not rewrite it): `ruya-grub-menu.service` writes `/boot/grub2/custom.cfg` on the first boot of the new image, and the hidden menu starts from the second boot. To test that path, boot an older `disk.qcow2` with `-Work`, `bootc switch` it to the new image (the drill above) and reboot twice.

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

Since T-132 the same script also checks the network part (NetworkManager active, `State` connected, `Primary` the ethernet link with an IPv4 address, `ListWifi`/`Scan` answer, unknown networks refused, another user refused; since T-180 also `pkcheck` as the service's own process: the four NetworkManager actions it needs are allowed, twelve others refused), and since T-133 the PipeWire events (`events` runs only those; `IDLE=60` adds a count of processes started while idle): a `wpctl set-volume` from outside shows in `MasterVolume` within a second, no `pw-dump` starts besides the one monitor, and the service recovers after `systemctl --user restart pipewire`. `vm-devices-check.sh state` prints `State` and `Primary`. Since T-161 `check` also covers the controller batteries (`upower` installed and active, `ListBatteries` answers an empty list, another user refused); `vm-devices-check.sh batteries` prints `ListBatteries`. Since T-196 `check` also has a storage part (`vm-devices-check.sh storage` runs only it): it prints `GetSystemUsage`, compares `total_bytes` and `free_bytes` with `stat -f /var` (within 1 %), waits for the background measurement of `apps_bytes` (up to 120 s), expects `data_bytes` to be -1 (the profile homes are 0700 users' directories the service cannot read; a number there passes too), checks that free + apps (+ data when known) + system add up to total and that `apps_bytes` is close to `du -sx /var/lib/flatpak`, that another user is refused, and then installs a signed 80 MB test app through `ruya-store` and expects `apps_bytes` to grow by more than 40 MB and `SystemUsageChanged` to be sent (`SKIP_APPS_GROWTH=1` leaves the install out; the test remote and app are removed at the end). Not run on the host: lead VM run (T-196). Since T-200 `check` ends its devices part with a thermal part and `vm-devices-check.sh thermal` runs only that (see "Fake a hot sensor"). Not run on the host: lead VM run (T-200). Since T-213 `check` also has a time part (`vm-devices-check.sh time` runs only it): `GetTimezone` matches `timedatectl`, `ListTimezones` has Europe/Istanbul and UTC, unknown and malformed names are `invalid`, another user is refused, root sets Asia/Tokyo and `timedatectl`, `/etc/localtime` and `date +%Z` follow, a zone set by `timedatectl` shows in `GetTimezone` within 5 s, the shell's own call is `forbidden` while profiles exist and nobody (or a standard profile) is signed in and `ok` for a signed-in admin or while no profile exists (the check signs nobody in: it asserts whichever state the VM is in and says which case it did not exercise), and `pkcheck` as the service's process allows `org.freedesktop.timedate1.set-timezone` (exit 0) and refuses `set-time`, `set-ntp` and `set-local-rtc` (exit 1: the rule answers NO, so no password prompt); the original zone is restored. Not run on the host: lead VM run (T-213). Since T-226 `check` also has a system information part (`vm-devices-check.sh system` runs only it): `GetInfo` against the guest's own `/proc`, `/sys` and tools (kernel, version, firmware and Secure Boot, uptime moving, CPU model/threads/cores with `lscpu`, memory and swap with `/proc/meminfo` (no swap: absent), the GPU's PCI id and driver, every internal disk of `lsblk`, the default route's interface and MAC, no Bluetooth chipset without an adapter), another user refused, and `Storage.SaveReport`'s refusals (unknown volume, unsafe names, no files, another user); with a removable volume mounted it writes the two files there and reads them back, without one it prints SKIP (attach a stick to QEMU: `-drive if=none,id=u,file=stick.img,format=raw -device usb-storage,drive=u`, e.g. a FAT image made with `mkfs.vfat`). Not run on the host: lead VM run (T-226). Against `ruya-devices --session`, `busctl --user call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.System GetInfo` answers the sample Dell; the shell's mock has three machines, `SystemDetails.mockProfile("dell"|"amd"|"nvidia")` (the tests and the screenshots use them). On the Dell, the page should match `lscpu`, `free -b`, `lspci -nn` and `lsblk` by eye. `cargo run -p ruya-sysinfo --example dump` (in WSL or any Linux; `CARGO_TARGET_DIR=/tmp/...` there) prints what the collector reads from the machine it runs on, `key = value` per line: the quickest check of the parsers against a real kernel. In the mock, `TimeZone.mockSetOutside(name)`, `mockSetNtp(bool)`, `mockSetCallerAllowed(bool)`, `mockFailNext()` and `mockReset()` play the service (the tests do); against `ruya-devices --session`, `busctl --user call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Time SetTimezone s Asia/Tokyo`. The Rust zone tests run on Windows (`time::tests`); `ruya-update`'s `the_system_clock_follows_a_zone_change_while_running` is Linux-only (set `TZ`, no zoneinfo files needed): run it in WSL with `cargo test --locked -p ruya-update schedule` from `services/` (use `CARGO_TARGET_DIR` under `/tmp`, not the worktree). **Link test** (T-132): `smoke-test.ps1` names the NIC `net0`; `set_link net0 off` / `set_link net0 on` in the QEMU monitor (`127.0.0.1:4444`, e.g. `vm-monitor`-style `echo set_link net0 off | ncat 127.0.0.1 4444`) unplugs and replugs the cable, and `vm-devices-check.sh state` (or Settings → Network, `vm-screenshot.ps1`) follows within a few seconds. `scripts/vm-network-probe.qml` (copy it to `/var/tmp`; the command is in its header) shows what the shell's own `Network` singleton reads over D-Bus. Probes use `console.warn`: the image filters `console.log`.

## Display: modes, capture, checks (T-198)
The service's mode list comes from `/sys/class/drm` and the EDID. `ruya-devices --display-list [dir]` prints what it would offer (no `dir`: this machine); `scripts/display-capture.sh [outdir]` (run on the machine with the TV or monitor) copies `status`, `modes` and `edid` of every connected connector into the layout of `/sys/class/drm`, and `--display-list <outdir>` or `RUYA_DRM_DIR=<outdir> ruya-devices --session` then reads that capture on the development host. `ruya-devices --session` serves two fake outputs on the session bus (state in `$TMP/ruya-devices-session`, or the parent of `RUYA_DEVICES_FILE`). The compositor's guard is `ruya-devices --display-guard [--state-dir dir]`; it records every compositor start in `display-starts` (the unit's start limit is 10 in 120 s, and `SetMode` answers `busy` from 8). In the shell's mock, `Display.mockUseScenario("tv4k"|"tv1080"|"monitor"|"none")`, `mockFailNext()`, `mockFailRevertNext()`, `mockFailKeepNext()`, `mockSetCrowded(bool)`, `mockSimulateFallback()` and `mockReset()` play the service (the tests do; `restartShell` only counts: `mockRestartCount()`, and plays the guard: a second start with a change waiting drops it), `Display.countdownTickMs` shortens the 15 s countdown and `Display.acceptGraceMs` the one-second grace for Accept. `scripts/vm-display-check.sh` (guest, as root; copy it with scp first; lead VM run): `check` verifies the unit (including the start limit), `ListOutputs` against `/sys/class/drm`, the contract's refusals, a `SetMode` and `Revert` that write and remove the marker and `kms.json` (named the way Qt names the screen), `Reset`, the guard on a scratch directory and that another user is refused; `switch` restarts the compositor to try a kept change, an unconfirmed one (it must fall back) and cleans up, and FAILS when the framebuffer does not follow the mode or when the restarts reach the unit's start limit. The Rust parts are `display::tests` and `edid::tests` (`dev.ps1 rust`); the shell parts are `tst_display.qml`.

## Fake a hot sensor (T-200)
No sensor is hot on demand, and `/sys` cannot be replaced. The thermal policy (`01` §2.4) is proven by the host tests (`dev.ps1 rust`: `thermal::tests`, `dev.ps1 test`: `tst_thermal.qml`); in the VM, `scripts/vm-devices-check.sh thermal` checks that `ListSensors` matches `/sys` (QEMU may expose no sensor: then the list is empty and `Level` is `normal`) and `thermal-fake` walks a made-up sensor through the levels over D-Bus. By hand, as root in the VM (the unit has a private `/tmp`, so the tree lives under `/var/lib`):

```sh
d=/var/lib/ruyaos-fakesys/class/hwmon/hwmon9; mkdir -p $d
echo coretemp > $d/name; echo 'Package id 0' > $d/temp1_label; echo 40000 > $d/temp1_input
echo 100000 > $d/temp1_crit; echo 1820 > $d/fan1_input; chmod -R a+rX /var/lib/ruyaos-fakesys
runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$(id -u ruya-shell) sh -c 'systemctl --user set-environment RUYA_THERMAL_SYSFS=/var/lib/ruyaos-fakesys; systemctl --user restart ruya-devices'
echo 92000 > $d/temp1_input     # hot after 10 s: the shell shows its toast and drops the effects
echo 97000 > $d/temp1_input     # critical (95 with crit 100): the notice, apps stop, power off after 60 s
echo 40000 > $d/temp1_input     # normal again (5 degrees of hysteresis below each threshold)
```

`systemctl --user unset-environment RUYA_THERMAL_SYSFS` and a restart of `ruya-devices` put the real sensors back. Thresholds can be changed for a try with `/etc/ruyaos/thermal.toml` (only the values to replace; see `/usr/lib/ruyaos/thermal.toml`). On the host, `ruya-devices --session` serves fixed fake sensors (processor 41, drive 38, fan 1820 rpm) on the session bus; the shell's mock has `Thermal.mockSet(id, class, value, level)` for the same.

## Store check (T-134)

`scripts/vm-store-check.sh` (guest, as root; copy it and `scripts/vm-store-probe.qml` with scp; boot with plain `smoke-test.ps1 -Keep`, no saved profile) builds a tiny GPG-signed Flatpak repository in the guest (one runtime, one app, no download), adds it through `AddRemote`, then drives `Search`, `Install`, `Uninstall` (with app data) over the system bus, watches the signals with `busctl monitor`, and lets the shell's own `Store` singleton (`ruya-shell --load vm-store-probe.qml`, offscreen) read the same service. Since T-140 the test app carries a 50 MB random payload (so the install shows an intermediate `JobProgress`), and the check also asserts that `flathub` is present and signed and `fedora` is absent. With the guest online, `flatpak update --appstream` runs in the background after start; a `Search` for `SuperTux` afterwards should return a named app. Since T-148 it also asserts that `Search` with `controller=gamepad` returns fewer apps than without, that `limit=1` returns one, and that an install sends `InstalledChanged` but no `CatalogChanged`. Since T-156 it asserts that `GetApp` returns `new_permissions` (empty for an app without an update). Since T-188 the restart-mid-install step also calls `ListJobs` after the restart (nothing queued or running; the cut-short install is `failed`/`interrupted`, or `ok` with the app installed if Flatpak finished it; `/var/lib/ruya-store/jobs` exists; the next job's number is higher than the old one's) and checks that the probe's `Store` applied the job table (`jobsReconciled`, logged by `vm-store-probe.qml`). `vm-store-check.sh security` prints `systemd-analyze security ruya-store`; `vm-store-check.sh clean` removes the test remote and app.

`scripts/vm-library-check.sh` (guest, as root; T-163; copy it with scp, boot with plain `smoke-test.ps1 -Keep`) checks `ruya-library` (`org.ruyaos.Library1`): the name is owned by the unprivileged `ruya-library` user, `ListItems` has every app of `flatpak list --system --app` and no Steam item, then it builds a tiny signed repository (a game with `Categories=Game;` and an app, no download), adds it through `Store1.AddRemote`, installs through `Store1` and checks that the item appears with `kind` game/app and that `ItemsChanged` fires (watched with `busctl monitor`), uninstalls and checks the same, that `Rescan` of an unchanged library sends nothing, and that `nobody` and the service account itself are refused. `check` cleans up after itself; `seed` leaves the two apps installed (for a `vm-screenshot.ps1 library-home` of the shell's Home, which lists them); `security` prints `systemd-analyze security ruya-library`; `clean` removes the test remote and apps. Since T-193 an exit trap does the same when `check` stops early (or `seed` fails) and stops the signal monitor.

## Play ledger check (T-247)

`scripts/vm-usage-check.sh` (guest, as root, a **lead run**; copy only the script; boot with plain `smoke-test.ps1 -Keep` and an **empty profile store**, it creates and deletes its own admin and two standard profiles) checks the play ledger of `ruya-session` (`Session1.ReportPresence`, `ListSessions`, `GetTotals`, `ClearHistory`) with a local Flatpak test app that sleeps, playing the shell's part over the bus as `ruya-shell` (`Profiles1.SwitchTo`, a `ReportPresence` every 5 s). It takes about three minutes of real waiting: the state directory is root-only 0700; a heartbeat file (0600, in a 0700 profile directory) exists after 36 s; the running session is listed with `open`; after `Stop` the session shows about 36 to 52 foreground seconds with reason `quit`, the ledger file is 0600 and the heartbeat file is gone; `GetTotals` has today's date and a row for it; with the zone set to Pacific/Kiritimati (UTC+14) `today` follows the zone (the "injectable day": the service reads the device zone for every second it counts); with the service killed (SIGKILL) while an app plays, the run comes back after the restart with reason `crashed` and the seconds of the last heartbeat; another profile gets `not-allowed` for the history and the totals, `ClearHistory` of another profile needs an admin (`wrong-pin` for a wrong PIN), the active profile clears its own (the ledger file is gone, `ListSessions` is empty); deleting a profile removes its usage directory within a minute; a caller other than `ruya-shell` is refused by the bus. `vm-usage-check.sh security` prints `systemd-analyze security ruya-session` (the unit gained `StateDirectory=ruya-session`: compare with 1.1 OK before it). The host tests of the same rules: `cargo test -p ruya-session` (`usage*.rs`).

## Session check (T-162)

`scripts/vm-session-check.sh` (guest, as root; copy it and `scripts/vm-session-probe.qml` with scp; boot with plain `smoke-test.ps1 -Keep`, no saved profile) checks `ruya-session` (`org.ruyaos.Session1`): the name is owned by root, a caller other than `ruya-shell` is refused by the bus policy, then it creates an admin and a standard profile through `Profiles1` (on an empty store; otherwise it uses the first profile), builds a tiny local Flatpak repository (a runtime made of the guest's own bash and sleep, an app that sleeps and one that exits 3; no download, no key), installs it and drives `Launch`/`Stop` as `ruya-shell`: `AppStarted`, `ListRunning` `running`, the process runs as `ruya-<id>` (never `ruya-shell` or root), the unit is active in the profile's manager, the manager lingers, no PipeWire or WirePlumber runs for the profile; the shell's own `Session` singleton (`vm-session-probe.qml`, offscreen) shows the app; `already-running`, `unknown-app`, `unknown-profile` (also for `root` and `ruya-shell`), `invalid`, `unknown-instance`; `Stop` gives `AppExited` `quit` and the app's process is really gone; the crasher gives `crashed` with code 3; a SIGKILL to the app's scope from outside gives `killed`. At the end the created standard profile is deleted while its manager lingers and an app runs (the user, the linger file and the processes must be gone). `vm-session-check.sh restart` (T-290) launches an app, runs `systemctl restart ruya-session`, and checks that `ListRunning` still lists it (the journal says `adopted`), a relaunch is `already-running`, `Stop` ends it with `quit`, a second restart plus a SIGKILL to the scope still gives an `AppExited`, then prints `systemd-analyze security ruya-session` and `ls -Z` of `/var/lib/ruya-session`; `vm-session-check.sh security` prints the same two; `clean` removes the test remote and apps. Not checked in the VM: the kill after the 5 s grace (a Flatpak sandbox dies at the SIGTERM of its scope, so no test app can ignore it; the core's tests cover it). Pitfall for scripts: a call over `systemctl/systemd-run --machine=` hands its stderr to PID 1, which SELinux lets write a pipe (`2>&1 | cat`) but not a log file in root's home (the call then hangs or fails with "Connection reset by peer").

## Update check (T-151)

`scripts/vm-update-check.sh` (guest, as root; boot with plain `smoke-test.ps1 -Keep`, no saved profile) drives `ruya-update` over the system bus: status record, `Check` against the dev registry (needs a newer image), `Download` (state `staged`, `bootc status` has a staged deployment), `Rollback`/`SetChannel` from `ruya-shell` without an admin profile are `forbidden`, `nobody` is refused by the bus policy. `vm-update-check.sh security` prints `systemd-analyze security ruya-update`. `vm-update-check.sh reboot` (after `check`, with an update staged; about 9 minutes) moves the guest clock to 03:10 tomorrow; the service counts the console as idle since its start, so within a minute `restart_at` is set (T-159, 120 s ahead). The script calls it off with a `ReportActivity` as `ruya-shell` (`restart_at` is 0 at once, nothing follows for 200 s), moves the clock 31 minutes on, sees the announcement again and waits: the service runs `systemctl reboot` and QEMU (which runs with `-no-reboot`) exits: that is the pass (T-154, T-159). Cold-start the disk again to see the new version.

Preparation (registry and insecure-registry setup as in the drill above): build the image, push it as `<wsl-ip>:5000/ruyaos:stable`, make the disk, boot, then in the guest `bootc switch <wsl-ip>:5000/ruyaos:stable` and reboot so the host tracks that tag. Build a second image with a higher version, push it as the same tag, and run the script: the check finds it. Restart from Settings -> System ("Restart to finish") or `systemctl reboot` and see `RUYA_BOOT_OK` with the new version (`vm-reboot-check.ps1`). Remove the tags afterwards (each pins about 4.7 GB in WSL).

## Test app in the VM (T-130)

`ruya-shell` is the compositor of the default session (on KMS through Qt eglfs, socket `/run/user/<uid>/ruya-0`). `scripts/vm-app-check.sh` (guest, as root) starts a key-logging Wayland test client (`scripts/vm-key-client.qml`) as `ruya-shell`, so the shell shows it fullscreen in its app layer. Sign in first (the wizard or `vm-goto.ps1 home`): before sign-in an app gets no focus. In a booted VM (`smoke-test.ps1 -Work -Keep`):

```powershell
scp ... scripts/vm-app-check.sh scripts/vm-key-client.qml scripts/vm-inject-key.py root@127.0.0.1:/root/
ssh ... root@127.0.0.1 bash /root/vm-app-check.sh state     # no cage, the socket, input ACLs, the session
ssh ... root@127.0.0.1 bash /root/vm-app-check.sh client    # the test client, fullscreen
.\scripts\vm-keys.ps1 a b c; .\scripts\vm-keys.ps1 meta_l     # keys reach the client; Super opens the Guide overlay over it
ssh ... root@127.0.0.1 python3 /root/vm-inject-key.py guide  # the controller's Guide
ssh ... root@127.0.0.1 bash /root/vm-app-check.sh log       # what the compositor and the client saw
ssh ... root@127.0.0.1 bash /root/vm-app-check.sh kill      # the client exits; the shell takes the screen back
```

The client renders in software (`QT_QUICK_BACKEND=software`): llvmpipe has no `EGL_WL_bind_wayland_display`, so a GL client cannot hand its buffers to the compositor in the VM. `compositor/` is not in the `RuyaShell` module, so `lupdate`, `qmllint` and the Qt Quick tests never see it (the Windows Qt kit has no QtWaylandCompositor); the image build compiles it. A fresh disk copy has new SSH host keys: use `-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes`, or `ssh` waits for a host-key prompt that never shows.

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
| `.\scripts\dev.ps1 test` | Text lint (tracked text files are UTF-8 with no stray control characters or tabs); board lint (`docs/STATUS.md` and the task files agree, `scripts/lint-board.ps1`); Rust fmt, clippy (Windows + Linux target) and tests; shell build; token lint (no literal durations or colours outside `Theme.qml`); qmllint (zero warnings); test member lint (qmllint over `shell/tests`, so a test cannot read a member QML cannot see; `scripts/lint-test-members.ps1`); Qt Quick tests. **Must be ALL GREEN before any commit.** |
| `.\scripts\dev.ps1 shots` | Only the Qt Quick tests that save a screenshot (`shotsDir + "/…"`), in real windows, into `output\shell-shots\` (cleared first), and half-size copies in `output\shell-shots\review\` for reviewing at a quarter of the image tokens |
| `.\scripts\dev.ps1 run` | The shell in a window with mock services |
| `.\scripts\dev.ps1 rust` / `shell` | Half of `test` |
| `.\scripts\dev.ps1 qml tst_themes [tst_glass ...]` | **Partial**, for iterating: builds only the test runner (`tst_ruyashell`) and runs the named `shell\tests` files offscreen, one runner process per file (`-input <file>`, log `shell\build-win\ruya-qmltest-<name>.txt`). No lint, no Rust, no other test file. It prints `PARTIAL: ... NOT a substitute for dev.ps1 test` and ends `PARTIAL PASS`, never `ALL GREEN` (exit 0 / 1). `revert-check.ps1 -Test tst_x` uses it. |
| `.\scripts\dev.ps1 docs` | Every check that reads `docs\`: text, board, developer guide and spec lint. Used by `push-main.ps1` and the reviewer's round 2 when only `docs/**/*.md` changed since a green `test`. |
| `output\last-green-test.txt` | Written by `test` only when it ends ALL GREEN on a clean tree whose HEAD did not move during the run (`commit <sha>`, `time <UTC>`); deleted when a `test` starts. `push-main.ps1` skips the full `test` when the marker is under 24 hours old and `git diff <sha> HEAD` is empty, runs only `dev.ps1 docs` when that diff is `docs/*.md` only, and runs `test` otherwise; `push-main.ps1 -DryRun` says which and pushes nothing. Each checkout has its own `output\`. |
| every `dev.ps1` command | Ends with `time: N s; slowest steps: ...` (the five slowest steps). |
| `.\scripts\lint-tokens.ps1` | The token lint alone (also called by `dev.ps1 shell` and by CI): literal durations, font sizes and colours (hex, names, `Qt.rgba`, `Qt.hsla`) outside `Theme.qml` and `qml/themes/`, and a mismatch between `ThemeSet.qml` and `Themes.tokenNames`. Exit 1 and a list of `file:line` on findings. |
| `.\scripts\lint-test-members.ps1 -RspFile shell\build-win\.rcc\qmllint\ruyashell.rsp` | The test member lint alone (qmllint over `shell/tests` plus a per-file canary that proves qmllint still checks the file); CI runs `scripts/lint-test-members.sh`, the same two checks. Needs a built shell and `qmllint` on PATH (`dev.ps1 shell` sets both). |
| `.\scripts\lint-translations.ps1` | The translation lint alone (also called by `dev.ps1 shell` and by CI): fails on any `type="unfinished"` entry in `shell/i18n/*.ts`. `dev.ps1` passes `-LUpdateProject <build>\.lupdate\ruya-shell_lupdate_project.json`, which first refreshes temporary copies from the current sources (so a forgotten refresh and leftover `vanished`/`obsolete` entries fail too); CI checks the committed files only. `dev.ps1` makes that project file itself (from the configure-time `ruya-shell_lupdate_project.Release.cmake`, with Qt's `GenerateLUpdateProject.cmake`) when it is missing (fresh worktree) or older than `shell/CMakeLists.txt` (a merge added a source file), reconfiguring first if needed; no manual step. It uses the CMake from `%ProgramFiles%\CMake`, else Visual Studio's, else PATH (devkitPro's cmake, first on PATH here, cannot drive the Visual Studio generator). Refresh the files with `& "$env:ProgramFiles\CMake\bin\cmake.exe" --build shell\build-win --config Release --target update_translations` (needs `lupdate`, in the Qt `bin`; a bare `cmake` in PowerShell is devkitPro's here). |
| `.\scripts\lint-text.ps1` | The text lint alone (also called by `dev.ps1 test` and by CI). Checks the files `git ls-files` lists, so `git add` a new file before relying on it. Exit 1 and a list of `file:line` on findings. |
| `.\scripts\repro-first-build.ps1 [-Name X]` | Adds a scratch C++ QML type, runs `dev.ps1 shell` once, removes the type, rebuilds. Exit 0 means adding and removing a type works on the first run (T-116). Takes about 3 minutes; run it only if "X is not defined" ever comes back. |

### Local checks and CI

`.github/workflows/ci.yml` (workflow `ci`) runs on every push to `main`, every pull request and by hand (`workflow_dispatch`). It needs no secrets and has `contents: read` only; a newer push to the same ref cancels the run in progress.

| CI job | Runs | Local equivalent |
|---|---|---|
| `lint` | `pwsh scripts/lint-text.ps1`, `lint-board.ps1`, `lint-tokens.ps1`, `lint-icons.ps1`, `lint-translations.ps1`, `lint-tests.ps1`, and `python -I scripts/check-font-coverage.py .` | the "text lint" and "board lint" steps of `dev.ps1 test` and the token, icon, font coverage, translation and test lint steps of `dev.ps1 shell` |
| `services` | `cargo fmt --check`, `clippy -D warnings`, `cargo test` (Ubuntu, Rust **1.92.0**, the host's version: when you update the host's Rust, bump `ci.yml` in the same commit) | `dev.ps1 rust` |
| `shell` | build with Fedora's Qt (Fedora 44 container), `qmllint --max-warnings 0`, Qt Quick tests offscreen | `dev.ps1 shell` (Qt 6.10.3 on MSVC here; CI also proves that no API newer than Qt 6.8 crept in) |
| `image` | needs the three jobs above; `scripts/build.sh`, `RUYA_NO_DEV_KEY=1 make-disk.sh qcow2`, `smoke-test.sh` under KVM (about 20 minutes); uploads `serial.log` | the WSL build and `smoke-test.ps1` (image section above) |

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

The `qtshadertools` module above is also what compiles the shell's shader (`shell/shaders/liquid.frag`, T-205, `qt_add_shaders` in `shell/CMakeLists.txt`); the Fedora image build needs `qt6-qtshadertools-devel` (in `image/Containerfile`). Without it the build still succeeds and the liquid pill falls back to the plain pill.

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

`dev.ps1 shots` runs only the test functions that save a screenshot, in real GPU windows (behaviour is already gated offscreen by `test`), in about 25 s. It stops at once, before building, when the session is locked (`LogonUI` running): red "The Windows session is locked" and a non-zero exit. The check repeats while it waits for another `shots` run and after a run that failed (a desktop that locked mid-run is reported as locked, not as test failures). `RUYA_ASSUME_LOCKED=1` simulates a locked session (read only by `dev.ps1`). Leave the windows alone while it runs. Offscreen is the software renderer, where `MultiEffect` draws nothing, so effects only show up in `shots`.

**Controller pairing screens (T-203).** In a VM, `scripts/vm-devices-check.sh bluetooth` (part of `check`) also checks `InputPresent` (QEMU's keyboard), that the window answers `unavailable` without an adapter and refuses another user. The shell's mock has an input device, so the "no controller" wizard stage and picker hint are not shown. In the mock, `Bluetooth.mockSetInputPresent(false)` and `Bluetooth.mockPairingScript("success"|"timeout"|"rejected"|"wait")` play them (the tests do). Against `ruya-devices --session`, `RUYA_DEVICES_NO_INPUT=1` makes the fake service report no input device (`busctl --user get-property org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Bluetooth InputPresent`); `StartControllerPairing` and `StopControllerPairing` work there too, but the session fakes follow nothing, so the window never ends by itself (no timeout, no pairing).

**Two Bluetooth adapters (T-336).** `RUYA_DEVICES_FAKE_BLUETOOTH=two-adapters ruya-devices --session` serves a fake machine with two adapters (`hci0`, and a USB `hci1` that holds two bonded pads and is the primary adapter); `ListDevices` then carries `adapter`. `vm-devices-check.sh bluetooth` starts it that way on ruya-shell's user bus and calls `Connect` and `Forget` on a pad of `hci1`. The shell's mock has one pad (`bt-pad-old`) on `hci1`.

**Against the real profiles service (Linux):** in `--session` mode the service uses the session bus and creates no Unix users, so it runs fine without root.

```bash
RUYA_PROFILES_FILE=/tmp/profiles.toml cargo run --manifest-path services/Cargo.toml -p ruya-profiles -- --session &
# first profile: no admin credentials needed, must be an admin with a PIN
busctl --user call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 CreateProfile sssss "" "" Me admin 1234
RUYA_DBUS=session RUYA_SERVICES=dbus shell/build/ruya-shell --windowed
```

**On Linux:** you don't have to reflash for QML changes. On any Linux machine or VM with Qt ≥ 6.8 (`qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qttools-devel qt6-linguist qt6-qtshadertools-devel`):

```bash
cmake -S shell -B shell/build -G Ninja && cmake --build shell/build && shell/build/ruya-shell --mock-services
```

## Known limits on this host
- QEMU on Windows renders through software (`MESA-EGL: failed to create dri2 screen` is expected), so FPS numbers there mean nothing.
- Gamepad passthrough into QEMU on Windows is unreliable. Test controllers on hardware or a Linux host (`-device usb-host,...`).
- `smoke-test.ps1` boots without a sound card unless asked (`-Audio`, see "Audio in the VM"). Without one the shell logs `QSoundEffect: playback of this format is not supported` once per cue and nothing plays. With one, the same three lines still appear at the first shell start of a session (a start-up race, benign: the cues play), but not when the shell restarts later.

## Free disk space
F: holds the WSL disk (`F:\wsl\ext4.vhdx`, since 2026-11-07), D: holds `output/` and is nearly full; `build.sh`/`make-disk.sh` refuse with under 15 GiB free on `/mnt/c` or `/mnt/f` (`scripts/lib-diskguard.sh`); and a full drive breaks `make-disk.sh` ("Cannot allocate memory"). After a session with image builds:
- In WSL as root: `podman image prune -f; podman system prune -f`, and `podman rmi` every drill/registry tag you pushed. Keep `localhost/ruyaos:dev`, `fedora-bootc:44`, `bootc-image-builder` and `fedora:44` (the next build needs them).
- `output/qcow2/work.qcow2` and any `.iso` you no longer need; `disk.qcow2` is the newest fresh disk (`make-disk.sh` recreates it).
- The VHDX never shrinks by itself (7 → 29 GB in one failed build, 2026-11-03). **`.\scripts\free-space.ps1`** does all of this section after every image build, passed or failed (owner rule): it refuses while a build runs, prunes untagged images, drill tags (`localhost:5000/*`) and stopped containers, keeps `ruyaos:dev` and the base images, deletes `work.qcow2` (unless `-KeepWork`), shuts WSL down and runs `wsl --manage FedoraLinux-44 --compact` (29 → 5.9 GB on 2026-11-03; the old export/import recipe is no longer needed).

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
