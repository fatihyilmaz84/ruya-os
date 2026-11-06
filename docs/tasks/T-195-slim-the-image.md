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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
