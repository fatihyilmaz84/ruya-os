# What is in the RuyaOS image, and why

Written in T-195 (owner, 2026-11-06: minimise the image; printing is not needed). The package table in
[`01-platform.md`](specs/01-platform.md) §1.2 is the design intent; **this file is what the built image
holds**. Rule: every package that is a leaf in the image (`dnf leaves`: nothing else depends on it) has a row
here, and every enabled unit has a reason. `scripts/check-image-manifest.sh` (in WSL, after a build) fails
for a leaf that is not named in backticks in this file; `image/build/98-guard.sh` fails the build for a banned
package or an enabled unit outside `image/build/enabled-units.txt`.

Size, measured with `rpm -qa` and `du -sx /usr` in the image:

| Image | Packages | `/usr` |
|---|---|---|
| 0.0.45-fw (before) | 894 | 4.15 GiB |
| 0.0.46-t195 (after) | 793 | 3.79 GiB |

`/usr` is 365 MiB smaller. The image as a container (4.99 GB) is not: the removal is a layer of its own on top of the base image, which still carries the deleted files, so an update still downloads them (rechunking the image would fix that; Inbox). The deployed system does not have them.

The rest is mostly what ADR-009 requires: the NVIDIA user space (1.0 GB), firmware (300 MB), Mesa and LLVM
(400 MB), Qt, codecs.

## 1. Leaf packages

`fedora-bootc` is the base: its packages are the bootc/ostree/systemd/SELinux/SSH/kernel group below. Groups
are in the order of the spec: UI, services, gaming and media, drivers and firmware, base and bootc.

### UI (the shell)

| Leaf | Why |
|---|---|
| `qt6-qtwayland` | `ruya-shell` is the Wayland compositor (QtWaylandCompositor, ADR-002 A) and runs on KMS through eglfs |
| `qt6-qtmultimedia` | video and sound cues in the shell. It pulls `qt6-qtbase`, `qt6-qtdeclarative`, `qt6-qtquick3d` and `qt6-qtshadertools`; `qt6-qtbase-gui` pulls `gtk3` (the GTK platform theme) and `cups-libs` (Qt's print support, no daemon): they stay because Qt requires them |
| `google-noto-sans-fonts` | fonts for the shell and for text in languages the shell's own font lacks (installed by `20-base.sh`) |
| `plymouth-theme-spinner` | boot splash (`plymouth` itself is in the base) |
| `kmscon` | the base image's text console on tty2 and up; support only, `ruya-compositor@tty1` owns tty1 |
| `ncurses`, `man-db`, `vim-minimal` | the support shell (`clear`, `man`, `vi`), over SSH or tty2 |

### Services (what the Rust services and the shell call)

| Leaf | Why |
|---|---|
| `NetworkManager-wifi` | `ruya-devices` Network; Wi-Fi. `NetworkManager` itself comes with the base |
| `NetworkManager-tui` | `nmtui` for support on a console without the shell |
| `bluez` | `ruya-devices` Bluetooth (`bluetooth.service`, `bluetoothctl`, `btmon` for debugging on the Dell) |
| `upower`, `upower-libs` | controller batteries (`ruya-devices`) |
| `pipewire-pulseaudio`, `pipewire-alsa`, `pipewire-utils` | audio: PulseAudio and ALSA clients through PipeWire; `pw-dump` is what `ruya-devices` reads. `pipewire` and `wireplumber` come with them. **Never** `pulseaudio` or `jack` (conflict) |
| `fedora-flathub-remote` | the signed Flathub `.flatpakrepo`, used by `ruya-flathub-remote.service`. It pulls `flatpak`, which `ruya-store`, `ruya-library` and `ruya-session` run; `bubblewrap` and `xdg-dbus-proxy` come with it (sandbox) |
| `greenboot-default-health-checks` | `greenboot`, the automatic rollback (`greenboot-healthcheck.service`) |
| `chrony` | the clock: TLS, update checks, the scheduled night restart |
| `sudo`, `sudo-python-plugin` | base; `ruya-profiles` does not use it, support does |
| `cloud-utils-growpart` | `bootc-generic-growpart` grows the root partition of a disk image on first boot |

`udisks2` (USB storage, `ruya-devices`), `polkit`, `dbus-broker`, `python3` and `skopeo`/`podman` are not
leaves: other packages depend on them (`udisks2` through `libblockdev-*`, `skopeo` and `podman` through `bootc`,
`greenboot` and `rpm-ostree`; `python3` through `sudo-python-plugin` and `python3-libdnf5`). `vm-*-check.sh` need
`python3` and `pkaction`/`pkcheck` in the guest.

### Gaming and media (codecs, GPU video, controllers)

| Leaf | Why |
|---|---|
| `ffmpeg` | full codec set from RPM Fusion (ADR-009); Qt Multimedia uses it. It links `libsmbclient`, so `samba-client-libs`, `samba-common`, `samba-core-libs`, `samba-ndr-libs`, `libwbclient`, `libldb` stay |
| `gstreamer1-plugin-libav`, `gstreamer1-plugins-bad-freeworld`, `gstreamer1-plugins-ugly`, `gstreamer1-plugin-openh264` | GStreamer plugin set for host-side consumers (ADR-009) |
| `mesa-va-drivers-freeworld` | VA-API H.264/HEVC/VC1 on AMD and virtio |
| `intel-media-driver`, `libva-intel-driver` | VA-API on Intel (iHD for Gen8+, i965 for older): the Dell's UHD |
| `libva-nvidia-driver` | VA-API on NVIDIA through NVDEC |
| `libva-utils` | `vainfo`, for support |
| `libdvdnav`, `librabbitmq`, `librist`, `xevd-libs`, `xeve-libs` | libraries of the codec set (`ffmpeg` / GStreamer plugins) that nothing else names |
| `rpmfusion-free-release`, `rpmfusion-nonfree-release` | the repositories for the codecs and the NVIDIA driver (also for updates inside a derived image) |

Mesa (`mesa-dri-drivers`, `mesa-vulkan-drivers`, 240 MB, plus `llvm-libs`, 147 MB) is required by Qt and needed by every GPU
that is not NVIDIA, and by the VM (software rendering).

### Drivers and firmware (ADR-009: all of it stays)

| Leaf | Why |
|---|---|
| `kernel`, `kmod-nvidia` | the kernel, and the NVIDIA module built for it in `40-nvidia.sh` (signed with an ephemeral key; the public cert is in `/usr/share/ruyaos/secureboot`) |
| `xorg-x11-drv-nvidia` | NVIDIA user space: EGL/GL/Vulkan, **NVDEC/NVENC** (`libnvcuvid`, `libnvidia-encode`, inside `xorg-x11-drv-nvidia-cuda-libs`, 487 MB, which `libva-nvidia-driver` needs), suspend helpers. Not trimmed: it is one package set from RPM Fusion, and the `nvidia-settings` GUI is a hard dependency of it |
| `xorg-x11-drv-nvidia-power` | NVIDIA suspend/resume/hibernate units (`nvidia-suspend.service` etc.) |
| `nvidia-settings` | required by `xorg-x11-drv-nvidia`; 4.5 MB |
| `iwlwifi-dvm-firmware`, `iwlwifi-mvm-firmware`, `iwlegacy-firmware` | Intel Wi-Fi (the Dell); added by T-162; `20-base.sh` also installs `iwlwifi-mld-firmware` and `iwlbluetooth-firmware` |
| `mediatek-firmware`, `libertas-firmware`, `atmel-firmware`, `zd1211-firmware` | Wi-Fi and Bluetooth of other vendors (T-162) |
| `alsa-sof-firmware`, `alsa-firmware`, `alsa-tools-firmware` | sound chips (Sound Open Firmware, T-162) |
| `intel-vsc-firmware` | Intel Visual Sensing Controller (laptops) |
| `microcode_ctl` | CPU microcode |
| `exfatprogs`, `ntfs-3g` | installed on purpose by `20-base.sh`: `ruya-devices` formats/mounts exFAT and NTFS sticks (weakly required, so `dnf leaves` does not list them) |
| `nvme-cli`, `sg3_utils` | disk tools for support and `udisks2`'s SMART/NVMe plugins |
| `ethtool`, `net-tools`, `iproute-tc`, `iptables-utils`, `bind-utils` | network debugging |
| `fwupd`, `fwupd-plugin-modem-manager`, `fwupd-plugin-uefi-capsule-data` | firmware updates from the LVFS (UEFI capsules; no shell UI yet). Not enabled, D-Bus activated |
| `zram-generator` | compressed swap in RAM (Fedora's default) |
| `efibootmgr`, `shim-x64`, `grub2-pc` | boot loader tools (`bootupd`, UEFI and BIOS installs) |

### Base and bootc

| Leaf | Why |
|---|---|
| `dnf5`, `python3-libdnf5`, `python3-rpm` | the package manager of the base image (derived images are built with it; `rpm` needs the bindings) |
| `dracut-network`, `dracut-squash` | initramfs modules the bootc base asks for |
| `cryptsetup` | LUKS tools (`udisks2` opens encrypted USB drives; the initramfs `crypt` module) |
| `openssh-server`, `openssh-clients` | SSH: support, the dev loop and the VM checks |
| `openssl` | certificates and TLS tools for support |
| `nss-altfiles` | users and groups in `/usr/lib` (ostree) |
| `console-login-helper-messages-issuegen`, `console-login-helper-messages-profile` | login banner of the base image |
| `acl`, `attr`, `bzip2`, `hostname`, `keyutils`, `lsof`, `socat`, `gawk-all-langpacks` | small base tools that scripts and support use |

## 2. Removed from the base image (`image/build/50-slim.sh`)

Measured on 0.0.45-fw: 100 requested packages, 101 with the one dependent (`lvm2-libs`); 894 → 793 packages.

| Group | Packages | Why |
|---|---|---|
| CPU emulators | `qemu-user-static*` (18 packages, 171 MB) | nothing runs foreign binaries |
| Cloud SDK | `python3-botocore`, `python3-boto3`, `python3-s3transfer`, `python3-jmespath`, `python3-dateutil` (123 MB), `sos`, `python3-pexpect`, `python3-ptyprocess`, `python3-requests`, `python3-pysocks`, `python3-urllib3`, `python3-idna`, `python3-charset-normalizer`, `python3-html2text`, `python3-pyyaml`, `python3-six`, `python3-packaging`, `python3-file-magic` | boto and the python libraries only `sos` and the cloud tools used; the services are Rust |
| Enterprise identity | `sssd*`, `adcli`, `gssproxy`, `clevis*`, `libsss_*`, `libipa_hbac`, `libini_config`, `libcollection`, `libdhash`, `libpath_utils`, `libref_array`, `libbasicobjects`, `cyrus-sasl-gssapi`, `jose`, `libjose`, `luksmeta`, `libluksmeta`, `libverto-libev`, `libev`, `c-ares`, `adcli-selinux` | profiles are plain Unix users from `useradd`; `authselect` is on the `local` profile (no `pam_sss`); no network-bound disk unlock |
| Cloud agents | `NetworkManager-cloud-setup`, `WALinuxAgent-udev` | Azure/EC2 metadata |
| NFS | `nfs-utils`, `nfs-client-utils`, `nfsv3-client-utils`, `nfsv4-client-utils`, `nfs-common-utils`, `libnfsidmap`, `rpcbind`, `quota`, `quota-nls` | no network file systems |
| LVM | `lvm2`, `device-mapper-persistent-data`, `device-mapper-event`, `device-mapper-event-libs`, `libaio`, and `lvm2-libs` (dependent) | the root is a plain xfs partition. `mdadm` stays: `udisks2` requires `libblockdev-mdraid`. The initramfs omits the `lvm` and `clevis` modules (`60-ruyaos-slim.conf`) |
| Daemons and tools | `avahi`, `libdaemon`, `toolbox`, `stalld`, `irqbalance`, `iptables-services` | mDNS, toolbox containers, realtime stall detector, IRQ balancing, iptables-save restore (NetworkManager uses nftables) |
| Crash dumps and build tools | `kdump-utils`, `kexec-tools`, `makedumpfile`, `chunkah`, `fedora-repos-archive` | `kdump` is not set up on a console; the others are for building images |

Considered and **kept**, with the reason:

| Package | Why it stays |
|---|---|
| `libsmbclient`, `samba-client-libs`, `samba-common`, `samba-core-libs`, `samba-ndr-libs`, `libwbclient`, `libldb`, `krb5-libs` | `ffmpeg` (libavformat) links `libsmbclient`: removing it removes `ffmpeg` and `qt6-qtmultimedia`. The banned-package guard allows exactly the four `samba-*` libraries |
| `gtk3`, `cups-libs`, `cups-filesystem` | `qt6-qtbase-gui` requires them (GTK platform theme, Qt print support). There is no print daemon, no `sane` and no `hplip`: printing is not supported |
| `podman`, `skopeo`, `criu` | `bootc`, `greenboot` and `rpm-ostree` require `podman` (`skopeo` is how `bootc` pulls an image); `podman` recommends `criu` |
| `accountsservice`, `appstream`, `glycin-*` | `flatpak` requires them. The unit `accounts-daemon.service` is disabled |
| `mdadm`, `libblockdev-mdraid` | `udisks2` requires `libblockdev-mdraid`, which requires `mdadm` |
| `tpm2-tools` | the bootc dracut config adds the `tpm2-tss` module, which needs it (dracut stops without it) |
| `qt6-qtquick3d`, `qt6-qtshadertools`, `assimp` | `qt6-qtmultimedia` requires them |
| `fwupd` | firmware updates for real hardware (see above); not enabled |
| `xorg-x11-drv-nvidia*`, `kmod-nvidia`, `nvidia-gpu-firmware`, `linux-firmware` and the vendor firmware packages | ADR-009; nothing in the NVIDIA set is optional (see the table above) |

## 3. Enabled units

`systemctl list-unit-files --state=enabled` (system) and `systemctl --global ...` (user) hold only the units in
`image/build/enabled-units.txt`, each with its reason; `98-guard.sh` fails the build for any other. Disabled
(`image/rootfs/usr/lib/systemd/system-preset/45-ruyaos.preset`, applied by `96-services.sh`; the packages stay
where something requires them) or removed with their package:

| Unit | Result | Why |
|---|---|---|
| `sssd.service`, `avahi-daemon.service`/`.socket`, `lvm2-monitor.service`, `lvm-devices-import.path`/`.service`, `dm-event.socket`, `lvm2-lvmpolld.socket`, `clevis-luks-askpass.path`, `nfs-client.target`, `irqbalance.service` | removed with their packages | |
| `accounts-daemon.service` | disabled | `flatpak` requires `accountsservice`; nothing here asks for user accounts over D-Bus |
| `systemd-homed.service`, `systemd-homed-activate.service` | disabled | profiles are plain Unix users (ADR in `00-overview.md`: not systemd-homed) |
| `mdmonitor.service`, `raid-check.timer` | disabled | no software RAID; `mdadm` stays only for `udisks2` |
| `authselect-apply-changes.service`, `fips-crypto-policy-overlay.service` | disabled | the PAM profile is fixed (`local`); FIPS mode is not supported |
| `rpm-ostree-countme.timer` | disabled | Fedora's usage counter makes a network call; not wanted |
| `bootc-fetch-apply-updates.timer` | disabled | it runs `bootc upgrade --apply` (a reboot) on its own schedule; `ruya-update` owns the update policy (check, download, announce, restart at night when idle) |
| `flatpak-add-fedora-repos.service` | masked | `ruya-flathub-remote.service` adds Flathub and deletes the `fedora` remote; this stock unit would add it back (T-140 documented it as masked; it was not) |
