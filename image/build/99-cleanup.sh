#!/usr/bin/env bash
set -euo pipefail
dnf clean all
rm -rf /var/cache/* /var/log/* /var/lib/dnf /tmp/* /var/tmp/*
# /run is a tmpfs at runtime; anything package scriptlets left there during the build is
# dead weight (`bootc container lint`: nonempty-run-tmp). Keep the container runtime's own
# files, which are bind mounts and cannot be removed anyway.
find /run -mindepth 1 -maxdepth 1 ! -name .containerenv ! -name secrets -exec rm -rf {} + 2>/dev/null || true
