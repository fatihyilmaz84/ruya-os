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
# A worktree made by Git for Windows has a D:/ gitdir that Linux git cannot read: say so, don't fail.
rev="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown (worktree gitdir not readable in WSL)")"
say "image-chain $version at $rev"
# In a worktree the git-ignored image/bib/config.toml (the dev SSH key) is missing and make-disk.sh
# would stop after a 20-minute build (lead-7): take it from the main checkout the worktree's .git
# file points to ("gitdir: D:/dev/RuyaOS/.git/worktrees/<name>").
if [ ! -f image/bib/config.toml ] && [ -f .git ]; then
    main="$(sed -n 's|^gitdir: \([A-Za-z]\):\(.*\)/\.git/worktrees/.*$|/mnt/\L\1\E\2|p' .git)"
    if [ -n "$main" ] && [ -f "$main/image/bib/config.toml" ]; then
        cp "$main/image/bib/config.toml" image/bib/config.toml && say "config.toml copied from $main"
    fi
fi
# SKIP_BUILD=1 reuses localhost/ruyaos:dev from a build that passed (a later step failed, e.g.
# make-disk ran out of memory while dev.ps1 test ran beside it, lead-8): never after a failed build.
if [ "${SKIP_BUILD:-}" = "1" ]; then
    say "SKIP build (SKIP_BUILD=1: the image built before is reused)"
else
    step build scripts/build.sh "$version" || { say "CHAIN FAILED"; exit 1; }
fi
step disk scripts/make-disk.sh qcow2 || { say "CHAIN FAILED"; exit 1; }
if [ "$want_oci" = "oci" ]; then
    mkdir -p /mnt/f/RuyaOS-tmp
    step oci podman save --format oci-archive -o "/mnt/f/RuyaOS-tmp/ruyaos-$version.oci" localhost/ruyaos:dev \
        || { say "CHAIN FAILED"; exit 1; }
fi
say "image: $(podman image inspect --format '{{.Id}}' localhost/ruyaos:dev 2>/dev/null | cut -c1-12)"
say "CHAIN OK"
