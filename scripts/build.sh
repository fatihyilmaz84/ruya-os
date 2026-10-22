#!/usr/bin/env bash
# Build the RuyaOS bootc container image. Run inside Linux (Podman Machine, WSL2, VM, CI).
#   scripts/build.sh [version]        -> localhost/ruyaos:dev
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-0.0.0-dev.$(date -u +%Y%m%d%H%M)}"
image="${IMAGE:-localhost/ruyaos:dev}"

podman build \
    --build-arg "RUYA_VERSION=${version}" \
    ${FEDORA_VERSION:+--build-arg "FEDORA_VERSION=${FEDORA_VERSION}"} \
    -f image/Containerfile -t "${image}" .

echo "built ${image} (version ${version})"
