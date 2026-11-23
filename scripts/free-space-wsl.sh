#!/bin/bash
# The WSL half of scripts/free-space.ps1 (run that, not this): runs as root in the distribution.
# Exit 3 while an image or disk build is still running.
set -uo pipefail

if pgrep -fa 'podman build|bootc-image-builder|make-disk' >/dev/null; then
    echo "An image or disk build is still running in WSL; try again when it ends:"
    pgrep -fa 'podman build|bootc-image-builder|make-disk'
    exit 3
fi

podman rm -f registry >/dev/null 2>&1 || true
podman container prune -f >/dev/null
podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost:5000/' | xargs -r podman rmi -f >/dev/null
# build.sh tags every Containerfile stage as localhost/ruyaos-cache:<stage> (RUY-771), so the build
# cache is not dangling and a plain prune keeps it; stale untagged images go.
podman image prune -f >/dev/null
# A crashed build leaves its working folders and anonymous volumes behind (RUY-957).
rm -rf /var/tmp/buildah[0-9]* 2>/dev/null || true
podman volume prune -f >/dev/null 2>&1 || true
podman images --format '  kept {{.Repository}}:{{.Tag}} {{.Size}}'
fstrim -a >/dev/null 2>&1 || true
echo "  WSL in use: $(df -h --output=used / | tail -1 | tr -d ' ')"
