#!/usr/bin/env bash
# Rebuild the initramfs: needed after any kernel change (40-nvidia.sh) and for Plymouth.
set -euo pipefail
kver="$(ls /usr/lib/modules | sort -V | tail -n1)"
# Remove modules dirs of kernels that are no longer installed (after a kernel upgrade).
for dir in /usr/lib/modules/*; do
    k="$(basename "$dir")"
    rpm -q "kernel-core-${k}" >/dev/null 2>&1 || rpm -qf "$dir" >/dev/null 2>&1 || rm -rf "$dir"
done
plymouth-set-default-theme spinner
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible --zstd -v --add ostree -f "/usr/lib/modules/${kver}/initramfs.img"
