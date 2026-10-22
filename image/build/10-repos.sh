#!/usr/bin/env bash
# RPM Fusion free + nonfree (ADR-009: ship all codecs and drivers).
set -euo pipefail
fedora="$(rpm -E %fedora)"
dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora}.noarch.rpm"
