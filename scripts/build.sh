#!/usr/bin/env bash
# Build the RuyaOS bootc container image. Run inside Linux (Podman Machine, WSL2, VM, CI).
#   scripts/build.sh [version]        -> localhost/ruyaos:dev
# After a successful build, untagged images that this build did not use are removed: every build
# leaves the previous image (~4.7 GB) and its stage images behind, and they filled the WSL disk
# (70 GB after two days). The layers this build used stay, so the next build still hits the
# cache. RUYA_KEEP_IMAGES=1 skips the clean-up.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-0.0.0-dev.$(date -u +%Y%m%d%H%M)}"
image="${IMAGE:-localhost/ruyaos:dev}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

podman build \
    --build-arg "RUYA_VERSION=${version}" \
    ${FEDORA_VERSION:+--build-arg "FEDORA_VERSION=${FEDORA_VERSION}"} \
    -f image/Containerfile -t "${image}" . 2>&1 | tee "$log"

echo "built ${image} (version ${version})"

if [[ "${RUYA_KEEP_IMAGES:-}" != 1 ]]; then
    # Ids this build produced or took from the cache ("--> <id>", "--> Using cache <id>").
    used="$(sed -nE 's/^--> (Using cache )?([0-9a-f]{12}).*/\2/p' "$log" | sort -u)"
    removed=0
    # Children must go before their parents, so repeat until nothing more can be removed.
    for _ in 1 2 3 4 5; do
        progress=0
        for id in $(podman images -a -q --no-trunc --filter dangling=true | sed 's/^sha256://' | sort -u); do
            grep -qx "${id:0:12}" <<<"$used" && continue
            if podman rmi "$id" >/dev/null 2>&1; then
                removed=$((removed + 1))
                progress=1
            fi
        done
        [[ $progress == 1 ]] || break
    done
    echo "removed ${removed} stale untagged image(s); $(podman system df --format '{{.Type}} {{.Size}}' | head -1)"
fi
