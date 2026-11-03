#!/usr/bin/env bash
set -euo pipefail
dnf clean all
rm -rf /var/cache/* /var/log/* /var/lib/dnf /tmp/* /var/tmp/*
# /run is a tmpfs at runtime; anything package scriptlets left there during the build is
# dead weight (`bootc container lint`: nonempty-run-tmp). Keep the container runtime's own
# files, which are bind mounts and cannot be removed anyway.
find /run -mindepth 1 -maxdepth 1 ! -name .containerenv ! -name secrets -exec rm -rf {} + 2>/dev/null || true
# Build fix (T-159): when Fedora's kernel is newer than the base image's, 40-nvidia.sh upgrades
# it inside the container. That leaves /boot/symvers-*.xz (lint: nonempty-boot; bootc images keep
# the kernel under /usr/lib/modules and /boot must be empty) and /var/lib/rpm-state/kernel (lint:
# var-tmpfiles). Neither is needed in the image.
find /boot -mindepth 1 -delete 2>/dev/null || true
rm -rf /var/lib/rpm-state
