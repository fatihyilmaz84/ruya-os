#!/usr/bin/env bash
# Base console packages: docs/specs/01-platform.md §1.2. No DE, no display manager, and no
# pulseaudio/jack-audio-connection-kit (they conflict with the pipewire-* replacements).
set -euo pipefail
dnf -y install --setopt=install_weak_deps=False \
    qt6-qtbase qt6-qtbase-gui qt6-qtdeclarative qt6-qtwayland qt6-qtmultimedia \
    mesa-dri-drivers mesa-vulkan-drivers vulkan-loader \
    pipewire pipewire-pulseaudio pipewire-alsa pipewire-utils wireplumber \
    NetworkManager-wifi bluez upower \
    udisks2 exfatprogs ntfs-3g \
    flatpak fedora-flathub-remote \
    greenboot greenboot-default-health-checks \
    plymouth plymouth-theme-spinner plymouth-plugin-script \
    google-noto-sans-fonts

# X11-only apps (ADR-034, RUY-434): Xwayland, started per app instance by xwayland-satellite
# (built in the Containerfile's xwayland-satellite stage). The satellite needs libxcb-cursor and
# the Open Sans font. Nothing starts them at boot; 98-guard allows exactly xorg-x11-server-Xwayland.
dnf -y install --setopt=install_weak_deps=False \
    xorg-x11-server-Xwayland xcb-util-cursor open-sans-fonts

# Firmware for the radios and sound chips a living-room PC has. linux-firmware only recommends
# part of it and this image installs without weak dependencies: before this, an Intel Bluetooth
# dongle (ibt-*.sfi) never initialised and Intel Wi-Fi would not have worked either (found on the
# Dell, T-162 session). ADR-009: ship all drivers.
dnf -y install --setopt=install_weak_deps=False     iwlbluetooth-firmware iwlwifi-dvm-firmware iwlwifi-mld-firmware iwlwifi-mvm-firmware     iwlegacy-firmware mediatek-firmware libertas-firmware atmel-firmware zd1211-firmware     intel-vsc-firmware alsa-sof-firmware alsa-firmware
# Fail the build if the one that mattered is missing (a renamed package would otherwise only
# show on a machine with the hardware).
test -e /usr/lib/firmware/intel/ibt-19-0-4.sfi.xz
compgen -G '/usr/lib/firmware/iwlwifi-*' > /dev/null
