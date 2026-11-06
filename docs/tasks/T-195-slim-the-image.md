# T-195 — Slim the image: ship what the UI, the services and gaming need, and say why

Status: in-progress · Phase: 2 · Depends: — · Area: image · Size: M · Owner: builder

## Goal
The image holds no desktop environment, no printing, no enterprise identity or cloud tooling and no CPU emulators, and every remaining package group has a stated reason (UI, services, gaming, drivers, base/bootc). Driver and firmware support stays complete (ADR-009). Owner, 2026-11-06: minimise it; printer support is not needed.

## Audit (Dell, image `0.0.44-t162`: 881 packages, `/usr` 4.1 GB; numbers from `rpm -qa --qf '%{SIZE}'`)
- **Already clean:** no GNOME/KDE/XFCE/etc., no display manager, no cups daemon, no sane. Only `gtk3` (22 MB, find who requires it) and `cups-libs`/`cups-filesystem` (Qt's print support, probably keep) remain.
- **Large and probably unneeded:** `qemu-user-static*` (18 packages, 170 MB, nothing requires it), `python3-botocore`/`s3transfer` (122 MB; find why they are there), `sssd*`/`samba*`/`krb5`/`realmd`/`clevis` (enterprise identity), `nfs`/`rpcbind`, `lvm2`/`mdadm`/`dmraid` (check `udisks2` first), `avahi`, `accounts-daemon`, `systemd-homed` (profiles are plain Unix users from `useradd`), `toolbox`, 32 python packages (197 MB).
- **Large and wanted:** NVIDIA user space 1.0 GB (`xorg-x11-drv-nvidia-cuda-libs` 487 MB holds the NVDEC/NVENC libraries: decide what video decode needs before touching it), firmware 299 MB (keep: drivers matter), Mesa and LLVM, Qt, codecs.
- **Enabled services that nothing here uses:** `sssd`, `avahi-daemon`, `accounts-daemon`, `mdmonitor`, `lvm2-monitor`, `lvm-devices-import`, `systemd-homed*`, `clevis-luks-askpass.path`, `nfs-client.target`, `authselect-apply-changes`, `fips-crypto-policy-overlay`, `flatpak-add-fedora-repos` (masked by T-140?). Check each; keep what `bootc`, greenboot, Flatpak and `udisks2` need.

## Read first
- `docs/specs/01-platform.md` §1.1–1.2 (base, package table), `docs/specs/00-overview.md` ADR-009
- `image/CLAUDE.md`, `image/build/20-base.sh`, `30-codecs.sh`, `99-cleanup.sh`, `image/Containerfile`
- `docs/dev-setup.md` (build, smoke, ISO check, update drill)

## Scope
1. **Manifest:** a table in `01-platform.md` §1.2 (or `docs/image-packages.md` if long) listing every package group with the reason: UI (Qt, fonts, Mesa), services (what each Rust service shells out to: `flatpak`, `systemd`, `bluez`, `udisks2`, `NetworkManager`, `upower`, PipeWire), gaming/media (codecs, Vulkan, controllers), drivers and firmware, base/bootc (bootc, ostree, greenboot, SELinux, SSH, kernel). Generate the leaf list with `dnf leaves` / `rpm -qa --qf '%{NAME}'` against the built image so nothing is guessed.
2. **Remove** what the audit marks unneeded, in a new ordered step `image/build/NN-slim.sh` (not by editing the base image's package set in several places). Use `dnf -y remove` and read the transaction: it must never list `bootc`, `ostree`, `systemd`, `greenboot`, `NetworkManager`, `flatpak`, `bluez`, `udisks2`, `upower`, `sshd`, `selinux-policy` or the kernel. A package that something protected needs stays (say so in the manifest).
3. **Disable** the services listed above that stay installed but are not needed (`systemctl disable`/`mask` in the Containerfile, a preset file under `/usr/lib/systemd/system-preset/` is better). Result: `systemctl list-unit-files --state=enabled` has only units with a reason in the manifest.
4. **A guard against regrowth:** a build step that fails when a banned pattern is installed (`gnome-*`, `kde-*`, `plasma-*`, `gdm`, `sddm`, `lightdm`, `cups` (the daemon), `sane-*`, `hplip`, `firewalld`, `cockpit`, `qemu-user-*`, `sssd`, `samba` (not `samba-client-libs` if something protected needs it: list the exceptions)) and prints package count and `/usr` size at the end of the build.
5. **NVIDIA:** keep driver and firmware support complete. Only trim if the manifest shows a package that no GPU feature (display, Vulkan, NVDEC/NVENC, suspend) uses; otherwise state why it stays.

## Out of scope
- Removing any firmware or GPU driver, codecs, Bluetooth/Wi-Fi support, anything `bootc` needs, changing the base image (`fedora-bootc`) or Fedora version.
- Re-introducing a package set per hardware tier (ADR-009: one image).

## Acceptance criteria
- [ ] The manifest exists and covers every package that is a leaf in the built image (`dnf leaves` output compared with the table: none unlisted).
- [ ] Outcome shows before/after: package count and `/usr` size (baseline above), and the list of removed packages and disabled services with the reason for each.
- [ ] The regrowth guard fails the build when a banned package is installed (show it failing once on a deliberately added package, then remove that).
- [ ] VM (this task): image built, `RUYA_BOOT_OK`, greenboot success; `vm-session-check.sh`, `vm-devices-check.sh` (with `-Audio`), `vm-store-check.sh`, `vm-library-check.sh`, `vm-storage-check.sh` ALL PASSED; `vm-iso-check.ps1` passes (Anaconda needs its own dependencies); if `skopeo`/`podman`/`toolbox` or anything `bootc` touches was removed, the update/rollback drill passes too.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN. Every build ends with `scripts\free-space.ps1`.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md`, `smoke-test.ps1`, the VM checks above and `vm-iso-check.ps1`.

## Docs to update
- `01-platform.md` §1.1–1.2 (the manifest and "the build excludes …"), `docs/dev-setup.md` if a check is added, `image/CLAUDE.md` (the new step).

## Hints
- Removing a package can pull dependents: read the whole `dnf remove` transaction before accepting; use `dnf repoquery --installed --whatrequires <pkg>` and `rpm -q --whatrequires` first.
- `bootc container lint --fatal-warnings` is the last step of the build and catches some breakage; the VM boot catches the rest.
- Do it in small steps with a build each (a builder worktree rebuilds from scratch, 30+ minutes: the first build pays for the NVIDIA kmod). One image build at a time on this host.
- Secure Boot, the akmods signing key and `bootupd` are outside this task (Inbox: `bootloader-update` fails on the Dell).

## Keep (found by reviews)
- `python3` and polkit (`pkaction`, `pkcheck`): `vm-update-check.sh` and `vm-storage-check.sh` need them in the guest (T-193 review). `udisks2`, `upower`, `bluez`, `NetworkManager`, `flatpak`, `bluetoothctl`/`btmon` (the Dell's Bluetooth debugging), `iwl*`/`mediatek`/`alsa-sof` firmware (T-162 session).
- Do not remove the `ruya-session` runtime needs: `systemd-run`/`systemctl --machine=`, `loginctl`, `flatpak`, `bubblewrap`, `xdg-dbus-proxy`.

## Outcome
Verified: vm (image `0.0.46-t195` built and booted on this host; hardware not involved)

**Before / after** (same measurement: `rpm -qa`, `du -sx /usr` inside the image; the baseline is the last lead image `0.0.45-fw`, the audit's `0.0.44-t162` had 881 packages and 4.1 GB):

| | packages | `/usr` | qcow2 (bib) | container image |
|---|---|---|---|---|
| 0.0.45-fw | 894 | 4 352 232 KiB (4.15 GiB) | 2.77 GB (the lead's `0.0.44-t162` disk) | 4.91 GB |
| 0.0.46-t195 | 793 | 3 978 604 KiB (3.79 GiB) | 2.92 GB | 4.99 GB |

`/usr` is 365 MiB smaller and 101 packages are gone. **The disk and the image are not smaller, they are a little bigger**: the removal is a layer on top of the base image, whose own layers still carry the deleted files, and bootc keeps every layer in `/sysroot/ostree/repo` (checked in the VM: the `qemu-aarch64-static` object is in two layer refs, repo 4.7 GB). The running system does not have the files; the disk and every update download still do. Fix: rechunk or flatten the image (Inbox).

**Built** (all under `image/`, plus docs and one script):
- `build/50-slim.sh` (own `RUN` after the NVIDIA layer): removes 100 requested packages (101 with the dependent `lvm2-libs`). It runs `dnf remove --assumeno` first and **refuses** the build when the transaction contains a protected package (`bootc`, `ostree`, `rpm-ostree`, `systemd`, `greenboot*`, `NetworkManager*`, `flatpak`, `bluez`, `udisks2`, `upower`, `openssh-*`, `selinux-policy*`, kernel, `polkit`, `bubblewrap`, `xdg-dbus-proxy`, `python3`, `skopeo`, `podman`, `qt6-*`, NVIDIA, Mesa, firmware, `ffmpeg`, `mdadm`, the four samba libs) or a package nobody asked for; afterwards it checks that the protected ones are still installed. Shown refusing: adding `podman` to the list stops with `REFUSED ... bootc, greenboot, greenboot-default-health-checks, podman, rpm-ostree`.
- `rootfs/usr/lib/systemd/system-preset/45-ruyaos.preset` + `build/96-services.sh` (after the rootfs copy): `systemctl preset` for the disabled units, `flatpak-add-fedora-repos.service` masked.
- `rootfs/usr/lib/dracut/dracut.conf.d/60-ruyaos-slim.conf`: omits the `lvm`, `clevis`, `clevis-pin-tpm2` dracut modules; the bootc base asks for them (`30-bootc-standard.conf`, `50-bootc-clevis.conf`) and the first build failed in dracut with "Module 'lvm' cannot be installed" once `lvm2`/`clevis` were gone.
- `build/98-guard.sh` (before the cleanup): fails for a banned package pattern (`gnome-*`, `kde-*`, `plasma-*`, `xfce*`, `lxqt-*`, `mate-*`, `cinnamon*`, `gdm`, `sddm`, `lightdm`, `cups` and its client/filters, `sane-*`, `hplip`, `firewalld`, `cockpit*`, `qemu-user*`, `sssd*`, `samba`/`samba-*` except `samba-client-libs`/`-common`/`-core-libs`/`-ndr-libs`, `realmd`, `adcli`, `clevis*`, `nfs-utils`, `rpcbind`, `avahi`, `toolbox`, `lvm2`, `dmraid`, `python3-botocore`/`boto3`/`s3transfer`, `kdump-utils`, `xorg-x11-server*`), for an enabled unit (system or `--global`) that is not in `build/enabled-units.txt` (each with its reason), and for dangling links in `/etc/systemd/system`; prints `98-guard: 793 packages, /usr 3886 MiB`. **Shown failing** on the built image in a throw-away container: with `sane-backends-libs` installed it printed five `banned package installed: sane-*` lines and `FAILED` (rc 1); with `systemd-homed` enabled `enabled unit without a reason` for both homed units (rc 1); both removed it printed `ok` (rc 0). The real build ran it: `98-guard: ok`.
- `docs/image-packages.md`: the manifest (every leaf by group with the reason, what was removed and why, what was kept although it looked removable, every enabled unit). `scripts/check-image-manifest.sh` compares `dnf leaves` of the image with the names in that file: `90 leaves in localhost/ruyaos:dev`, `ok` (the file was written against the leaf list of a pre-build simulation and checked against the built image). It is a manual check in WSL, not part of `dev.ps1 test`.

**Removed** (details and reasons in `docs/image-packages.md` §2): `qemu-user-static*` (18, 171 MB); the cloud SDK `python3-botocore`/`boto3`/`s3transfer`/`jmespath` (123 MB), `sos` and the python libraries only they used (18 packages); `sssd*`, `adcli`, `gssproxy`, `clevis*` and their helper libraries (identity and network-bound disk unlock; PAM and nsswitch use no `sss`, `authselect` is on `local`); `NetworkManager-cloud-setup`, `WALinuxAgent-udev`; NFS client (`nfs-utils` family, `rpcbind`, `quota`); LVM (`lvm2`, `device-mapper-persistent-data`, `device-mapper-event*`, `libaio`, `lvm2-libs`); `avahi`, `libdaemon`, `toolbox`, `stalld`, `irqbalance`, `iptables-services`; `kdump-utils`, `kexec-tools`, `makedumpfile`, `chunkah`, `fedora-repos-archive`.
**Disabled / masked** (preset): `accounts-daemon` (the package stays: `flatpak` requires `accountsservice`), `systemd-homed` and `-activate`, `mdmonitor`, `raid-check.timer`, `authselect-apply-changes`, `fips-crypto-policy-overlay`, `rpm-ostree-countme.timer` (Fedora's usage counter), **`bootc-fetch-apply-updates.timer`** (it runs `bootc upgrade --apply`, i.e. a reboot, 1 h after boot and every 8 h, next to `ruya-update`'s own policy: it was enabled in 0.0.45; a behaviour fix, not only slimming), `flatpak-add-fedora-repos.service` masked (the spec said T-140 masked it; the unit was enabled and would add the `fedora` remote again on a first boot). Gone with their packages: `sssd`, `avahi-daemon`, `lvm2-monitor`, `lvm-devices-import`, `dm-event.socket`, `lvm2-lvmpolld.socket`, `clevis-luks-askpass.path`, `nfs-client.target`, `irqbalance`. Enabled afterwards: 55 system units and 8 user (`--global`) units, all in `enabled-units.txt`.
**Kept although the audit marked them** (the dry runs said removal would take protected packages): `samba-client-libs`, `libsmbclient`, `libwbclient`, `libldb`, `krb5-libs` (`ffmpeg`'s libavformat links `libsmbclient`: removing them removes `ffmpeg` and Qt Multimedia); `gtk3` and `cups-libs` (required by `qt6-qtbase-gui`); `podman` and `skopeo` (required by `bootc`, `greenboot`, `rpm-ostree`); `mdadm` (`udisks2` -> `libblockdev-mdraid`); `tpm2-tools` (the bootc dracut config adds the `tpm2-tss` module, dracut stopped without it); `accountsservice`, `appstream`, `glycin-*` (`flatpak`); `qt6-qtquick3d`, `qt6-qtshadertools`, `assimp` (`qt6-qtmultimedia`). **NVIDIA is untouched**: `nvidia-settings` is a hard dependency of `xorg-x11-drv-nvidia`, and `xorg-x11-drv-nvidia-cuda-libs` (487 MB) holds `libnvcuvid` / `libnvidia-encode` that `libva-nvidia-driver` (NVDEC) needs. Firmware, codecs, Bluetooth and Wi-Fi packages are untouched.

**VM** (`0.0.46-t195`, qcow2 from `make-disk.sh`, QEMU/WHPX):
- `smoke-test.ps1`: `RUYA_BOOT_OK 0.0.46-t195`; `greenboot-healthcheck` and `greenboot-success.target` active, `systemctl is-system-running` = running, no failed unit, `flatpak remotes --system` = `flathub` only, `flatpak-add-fedora-repos` masked, `bootc-fetch-apply-updates.timer` and `accounts-daemon` disabled.
- `vm-store-check.sh check`, `vm-library-check.sh check`, `vm-session-check.sh check`: ALL CHECKS PASSED each. `vm-devices-check.sh check` in a VM booted with `-Audio -AudioBackend wav`: ALL CHECKS PASSED (57 PASS). `vm-storage-check.ps1`: STORAGE CHECKS PASSED (102 PASS) **after a test fix, see Deviations**.
- `vm-iso-check.ps1`: ISO CHECK PASSED (`install=Install finished after 241 s; boot=RUYA_BOOT_OK 0.0.46-t195; greenboot=success`). The Anaconda install does not need `lvm2` in the target.
- Update drill (the task asks for it because `toolbox` was removed; not run for anything `bootc` touches, which was not touched): a derived image `0.0.47-t195-drill` pushed to a registry in WSL; `bootc switch <wsl-ip>:5000/ruyaos:0.0.47-t195-drill` in the VM (`layers already present: 71; layers needed: 1`, 37 s), `vm-reboot-check.ps1` -> `RUYA_BOOT_OK 0.0.47-t195-drill`, greenboot active; `bootc rollback` + `vm-reboot-check.ps1` -> `RUYA_BOOT_OK 0.0.46-t195`. The automatic greenboot rollback (three failed boots) was not repeated: nothing in this task touches the health checks.
- `scripts\free-space.ps1` ran after the VM checks (C: 41.5 GB free).
- Not checked: real hardware (Dell), Bluetooth/Wi-Fi with a real adapter, NVIDIA on a GPU, Secure Boot.

**Deviations**
- `vm-storage-check.sh`, step `gone`: the check failed 3 of 3 runs on `0.0.46-t195` at `mplugged` with "signal order" (it passed on `0.0.44-t162` in the same harness). Cause (journal and the busctl monitor log, kernel `usb 2-4: USB disconnect` at 08.245, `VolumesChanged` of the *previous* stick's removal at 08.58, new `watch` already recording since about 08.4): the step waited only for the kernel to drop the disk, the recording then started, and ruya-devices published the removal after its debounce, so the first `VolumesChanged` in the log preceded the first `VolumeAdded` of the next stick. Logins are faster now (no sssd/homed lookups), which moved the race into view; the service's order of signals is right (`VolumeAdded` x3 at 11.4667, then `VolumesChanged`). The step now waits until `ListVolumes` is empty and sleeps 2 s (the debounce's quiet time) before `watch`. No assertion was weakened: it adds one (`the service lists no volume`). Revert test: with the old `gone` the check failed three times; with the new one it passed (102 PASS).
- The task text suggests a preset file only; `98-guard.sh` also needs the allowlist file `build/enabled-units.txt`, and the bootc dracut modules needed an omit file. Two extra scripts (`96-services.sh`, `check-image-manifest.sh`) instead of editing the Containerfile's long `RUN` chain.
- `tpm2-tools` was in the first removal list and was taken off it after the first build failed in dracut (above); `libjose`, `libluksmeta`, `libev`, `device-mapper-event-libs`, `libaio`, `libdaemon`, `c-ares`, `adcli-selinux` were added after a dry run on the first slimmed container showed them as new leaves with no user.

**Findings that are not slimming**
- Any edit under `image/build/` rebuilds from the first `RUN` (the NVIDIA step, about 10 minutes here); the Containerfile comment says so. Fast loop: run the script in a throw-away container of the last image (`dev-setup.md`).
- `journalctl` shows one `Activation request for 'org.freedesktop.home1' failed` per boot (logind asks for homed, now disabled). Harmless; not silenced.

**Inbox** (also in the HANDOFF): rechunk or flatten the image so removals shrink the disk and the update download (`chunkah`, which this task removed from the image, is the base's rechunking tool; it belongs in the build, not in the image); decide fwupd (19 MB, not enabled, no shell UI); `libsmbclient` via `ffmpeg` (a build of ffmpeg without smb would drop 20 MB of samba libraries).
