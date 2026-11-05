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
# In a bootc image /root is a symlink to var/roothome, which does not exist while the container
# builds. dracut's base module installs /root, and a dangling symlink made dracut-install print
# "ERROR: installing '/root'" (the initramfs was still written). Give the link a target for the
# duration of dracut and remove it again: /var must stay empty (95-var-tmpfiles, bootc lint).
made_roothome=0
if [ -L /root ] && [ ! -e /root ]; then
    mkdir -p "$(readlink -m /root)"
    made_roothome=1
fi
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible --zstd -v --add ostree -f "/usr/lib/modules/${kver}/initramfs.img"
if [ "$made_roothome" = 1 ]; then
    rmdir "$(readlink -m /root)"
fi
