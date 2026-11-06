#!/usr/bin/env bash
# Every leaf package of the built image must appear in docs/image-packages.md (T-195).
#   scripts/check-image-manifest.sh [image]      (in WSL, repo root; default localhost/ruyaos:dev)
# `dnf leaves` lists the packages nothing else depends on: if a package group is added to the image,
# it shows up here until the manifest gives its reason. Exit 1 lists the unlisted leaves. (The NVIDIA
# kernel module package has the kernel version in its name: the manifest lists it as kmod-nvidia.)
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:-localhost/ruyaos:dev}"

leaves="$(podman run --rm "$image" bash -c \
    'dnf leaves 2>/dev/null | sed -E "s/^[ -]+//" | while read -r e; do rpm -q --qf "%{NAME}\n" "$e"; done' | sed -E 's/^kmod-nvidia-.*/kmod-nvidia/' | sort -u)"
[ -n "$leaves" ] || { echo "check-image-manifest: no leaves read from $image"; exit 1; }

documented="$(grep -oE '`[A-Za-z0-9_.+-]+`' docs/image-packages.md | tr -d '`' | sort -u)"

missing=0
while read -r name; do
    if ! grep -qxF "$name" <<<"$documented"; then
        echo "not in docs/image-packages.md: $name"
        missing=1
    fi
done <<<"$leaves"

echo "check-image-manifest: $(wc -l <<<"$leaves") leaves in $image"
[ "$missing" = 0 ] || exit 1
echo "check-image-manifest: ok"
