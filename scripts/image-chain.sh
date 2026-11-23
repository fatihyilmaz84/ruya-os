#!/usr/bin/env bash
# Image chain for a lead session (LEAD.md, "Lead efficiency"): build.sh, then make-disk.sh qcow2,
# with every step's full log in output/chain/ and a summary of at most 15 lines on stdout and in
# output/chain/summary.txt. Run it in WSL from the checkout (or worktree) to build:
#   wsl -d FedoraLinux-44 -- bash -lc 'cd /mnt/d/dev/RuyaOS && scripts/image-chain.sh 0.0.57'
# Optional second argument "oci": also writes the oci-archive for the Dell update route
# (docs/dev-setup.md, "When to build the ISO") to /mnt/f/RuyaOS-tmp/ruyaos-<version>.oci.
# The VM checks and free-space.ps1 run from Windows afterwards.
# Disk (RUY-957; F: filled up mid-build twice, lead-38 and lead-44, and WSL's root went read-only:
# inside WSL `df /` shows the vhdx's virtual size, so only the host drives tell): before the build
# and on every exit the chain runs free-space-wsl.sh (untagged images, build leftovers, trim), with
# "oci" it keeps only the newest Dell archive on F:, and it refuses to start, or to write the
# archive, with less than RUYA_CHAIN_MIN_FREE_GIB (default 30: a build grows the vhdx by about
# 20 GiB, the archive is 3.2 GiB) free on a drive that backs WSL (lib-diskguard.sh).
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
source scripts/lib-diskguard.sh
export RUYA_MIN_FREE_GIB="${RUYA_CHAIN_MIN_FREE_GIB:-30}"
# host_free: one summary line with the free GiB of each drive that backs WSL.
host_free() {
    local p line=""
    for p in ${RUYA_DISK_GUARD_PATHS:-/mnt/c /mnt/f}; do
        [ -d "$p" ] && line="$line $p $(df -P -BG "$p" 2>/dev/null | awk 'NR==2 { print $4 }')"
    done
    echo "free:$line"
}
cleanup() {
    bash scripts/free-space-wsl.sh > "$out/cleanup.log" 2>&1 || true
}
# finish <verdict line> <exit code>: every end of the chain, passed or failed, removes the build's
# leftovers (the vhdx itself is compacted from Windows), and the verdict stays the summary's last line.
finish() {
    cleanup
    say "after cleanup: $(host_free)"
    say "$1"
    exit "$2"
}
cleanup
if [ "$want_oci" = "oci" ] && [ -d /mnt/f/RuyaOS-tmp ]; then
    # The Dell's update needs only the newest archive; its rollback lives on the Dell.
    ls -1t /mnt/f/RuyaOS-tmp/ruyaos-*.oci 2>/dev/null | tail -n +2 | xargs -r rm -f
fi
say "before: $(host_free)"
ruya_disk_guard 2>&1 | tee -a "$summary"
[ "${PIPESTATUS[0]}" -eq 0 ] || finish "CHAIN FAILED (disk guard: run scripts\\free-space.ps1 from Windows)" 1
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
    step build scripts/build.sh "$version" || finish "CHAIN FAILED" 1
fi
# The pad drivers are in the image (RUY-154: xpad comes only with kernel-modules-extra).
step drivers bash scripts/check-image-input-drivers.sh || finish "CHAIN FAILED" 1
step disk scripts/make-disk.sh qcow2 || finish "CHAIN FAILED" 1
if [ "$want_oci" = "oci" ]; then
    mkdir -p /mnt/f/RuyaOS-tmp
    ruya_disk_guard 2>&1 | tee -a "$summary"
    [ "${PIPESTATUS[0]}" -eq 0 ] || finish "CHAIN FAILED (disk guard before the archive)" 1
    step oci podman save --format oci-archive -o "/mnt/f/RuyaOS-tmp/ruyaos-$version.oci" localhost/ruyaos:dev \
        || finish "CHAIN FAILED" 1
fi
say "image: $(podman image inspect --format '{{.Id}}' localhost/ruyaos:dev 2>/dev/null | cut -c1-12)"
finish "CHAIN OK" 0
