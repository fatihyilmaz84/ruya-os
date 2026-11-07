#!/usr/bin/env bash
# Sourced by build.sh and make-disk.sh: refuse to start a heavy build when a Windows drive that
# backs WSL is nearly full (the WSL ext4.vhdx grows on its host drive and an out-of-space host
# corrupts the distribution; 2026-10-27).
#   RUYA_MIN_FREE_GIB       minimum free GiB (default 15)
#   RUYA_DISK_GUARD_PATHS   space-separated paths to check (default "/mnt/c /mnt/f"); a path that
#                           does not exist is skipped, so CI and plain Linux hosts pass.
#   RUYA_SKIP_DISK_GUARD=1  skip the check
ruya_disk_guard() {
    [[ "${RUYA_SKIP_DISK_GUARD:-}" == 1 ]] && return 0
    local min="${RUYA_MIN_FREE_GIB:-15}" p free
    for p in ${RUYA_DISK_GUARD_PATHS:-/mnt/c /mnt/f}; do
        [[ -d "$p" ]] || continue
        free="$(df -P -BG "$p" 2>/dev/null | awk 'NR==2 { gsub("G", "", $4); print $4 }')"
        [[ "$free" =~ ^[0-9]+$ ]] || continue
        if (( free < min )); then
            echo "refusing to build: only ${free} GiB free on ${p} (need ${min}). Free space (scripts/free-space.ps1) or set RUYA_SKIP_DISK_GUARD=1." >&2
            return 1
        fi
    done
}
