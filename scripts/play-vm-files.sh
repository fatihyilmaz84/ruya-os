#!/bin/bash
# SPDX-License-Identifier: MIT
#
# The files the .play VM checks need on the guest (RUY-860): the native sample package, ruya-pack
# and, for vm-play-check.sh launch-windows (RUY-902) and bundled (RUY-1248), the Windows sample package.
# scripts/vm-queue.ps1 copies them to /root/ (vm-play-check.sh and vm-library-check.sh find them
# there). Run it in Fedora 44 (WSL: FedoraLinux-44), from the repo root, with the same packages as
# scripts/ci-samples-linux.sh:
#
#     bash scripts/play-vm-files.sh
#
# Writes output/play-vm/hello-play-native.play.zip, output/play-vm/ruya-pack and
# output/play-vm/hello-play-wine.play.zip, then removes the samples' build outputs again, so
# `git status` stays clean. The first two are written before the Windows sample is built: without
# the MinGW cross compilers (mingw64-gcc and mingw32-gcc) the script says so and exits 1, and the
# queue skips launch-windows and bundled only. CARGO_TARGET_DIR overrides where ruya-pack is built (default:
# services/target-samples).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/lib-samples.sh"
samples="hello-play-native hello-play-wine"
out="$root/output/play-vm"

# shellcheck disable=SC2086
trap 'samples_clean_outputs "$root" $samples' EXIT
samples_build_pack "$root"
mkdir -p "$out"
rm -f "$out/ruya-pack"
cp "$RUYA_PACK" "$out/ruya-pack"
for sample in $samples; do
    rm -f "$out/$sample.play.zip"
    if [ "$sample" = hello-play-wine ]; then
        for cc in "${MINGW_CC:-x86_64-w64-mingw32-gcc}" "${MINGW_CC32:-i686-w64-mingw32-gcc}"; do
            command -v "$cc" >/dev/null 2>&1 || { echo "play-vm-files: no $cc (dnf install mingw64-gcc mingw32-gcc): $sample is not built, launch-windows will be skipped" >&2; exit 1; }
        done
    fi
    # build.sh exits 0 without ruya-pack, so the zip check below is the proof.
    sh "$root/samples/$sample/build.sh"
    zip="$root/samples/$sample/$sample.play.zip"
    [ -s "$zip" ] || { echo "play-vm-files: $sample built no $sample.play.zip" >&2; exit 1; }
    cp "$zip" "$out/$sample.play.zip"
    echo "play-vm-files: $out/$sample.play.zip ($(wc -c < "$out/$sample.play.zip") bytes)"
done
echo "play-vm-files: and ruya-pack in $out"
