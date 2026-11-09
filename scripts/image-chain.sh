#!/usr/bin/env bash
# Image chain for a lead session (LEAD.md, "Lead efficiency"): build.sh, then make-disk.sh qcow2,
# with every step's full log in output/chain/ and a summary of at most 15 lines on stdout and in
# output/chain/summary.txt. Run it in WSL from the checkout (or worktree) to build:
#   wsl -d FedoraLinux-44 -- bash -lc 'cd /mnt/d/dev/RuyaOS && scripts/image-chain.sh 0.0.57'
# Optional second argument "oci": also writes the oci-archive for the Dell update route
# (docs/dev-setup.md, "When to build the ISO") to /mnt/f/RuyaOS-tmp/ruyaos-<version>.oci.
# The VM checks and free-space.ps1 run from Windows afterwards.
set -u
version="${1:?usage: image-chain.sh <version> [oci]}"
want_oci="${2:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/output/chain"
mkdir -p "$out"
summary="$out/summary.txt"
: > "$summary"

say() { echo "$*" | tee -a "$summary"; }

step() {
    local name="$1"; shift
    local log="$out/$name.log"
    local start end
    start=$(date +%s)
    if "$@" > "$log" 2>&1; then
        end=$(date +%s)
        say "PASS $name ($(( (end - start) / 60 )) min) log: output/chain/$name.log"
        return 0
    fi
    end=$(date +%s)
    say "FAIL $name ($(( (end - start) / 60 )) min) log: output/chain/$name.log; last lines:"
    tail -n 6 "$log" | tee -a "$summary"
    return 1
}

cd "$root" || exit 2
say "image-chain $version at $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
step build scripts/build.sh "$version" || { say "CHAIN FAILED"; exit 1; }
step disk scripts/make-disk.sh qcow2 || { say "CHAIN FAILED"; exit 1; }
if [ "$want_oci" = "oci" ]; then
    mkdir -p /mnt/f/RuyaOS-tmp
    step oci podman save --format oci-archive -o "/mnt/f/RuyaOS-tmp/ruyaos-$version.oci" localhost/ruyaos:dev \
        || { say "CHAIN FAILED"; exit 1; }
fi
say "image: $(podman image inspect --format '{{.Id}}' localhost/ruyaos:dev 2>/dev/null | cut -c1-12)"
say "CHAIN OK"
