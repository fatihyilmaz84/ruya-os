#!/usr/bin/env bash
# Base console packages: docs/specs/01-platform.md §1.2. No DE, no display manager, and no
# pulseaudio/jack-audio-connection-kit (they conflict with the pipewire-* replacements).
set -euo pipefail
dnf -y install --setopt=install_weak_deps=False \
    cage \
    qt6-qtbase qt6-qtbase-gui qt6-qtdeclarative qt6-qtwayland qt6-qtmultimedia \
    mesa-dri-drivers mesa-vulkan-drivers vulkan-loader \
    pipewire pipewire-pulseaudio pipewire-alsa pipewire-utils wireplumber \
    NetworkManager-wifi bluez \
    udisks2 exfatprogs ntfs-3g \
    flatpak \
    greenboot greenboot-default-health-checks \
    plymouth plymouth-theme-spinner \
    google-noto-sans-fonts
