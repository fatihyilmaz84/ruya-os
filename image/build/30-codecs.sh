#!/usr/bin/env bash
# Full codec set (ADR-009). Replaces Fedora's patent-stripped builds with RPM Fusion's:
#  - ffmpeg (H.264/HEVC/AAC/...) for Qt Multimedia and host tools
#  - Mesa VA-API with H.264/HEVC/VC1 decode+encode (AMD, Intel Gallium, virtio)
#  - Intel iHD (Gen8+) and legacy i965 VA-API drivers
#  - GStreamer plugin set for any host-side GStreamer consumer
# Flatpak apps use their runtime's codec extensions instead (03-services-and-apps §6).
set -euo pipefail
dnf -y install --allowerasing --setopt=install_weak_deps=False \
    ffmpeg ffmpeg-libs \
    mesa-va-drivers-freeworld \
    intel-media-driver libva-intel-driver \
    libva-utils \
    gstreamer1-libav gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-plugin-openh264
