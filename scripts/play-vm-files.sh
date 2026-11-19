#!/bin/bash
# SPDX-License-Identifier: MIT
#
# The two files the .play VM checks need on the guest (RUY-860): the native sample package and
# ruya-pack. scripts/vm-queue.ps1 copies them to /root/ (vm-play-check.sh and vm-library-check.sh
# find them there). Run it in Fedora 44 (WSL: FedoraLinux-44), from the repo root, with the same
# packages as scripts/ci-samples-linux.sh:
#
#     bash scripts/play-vm-files.sh
#
# Writes output/play-vm/hello-play-native.play.zip and output/play-vm/ruya-pack, then removes the
# sample's build outputs again, so `git status` stays clean. CARGO_TARGET_DIR overrides where
# ruya-pack is built (default: services/target-samples).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/lib-samples.sh"
sample=hello-play-native
out="$root/output/play-vm"

trap 'samples_clean_outputs "$root" "$sample"' EXIT
samples_build_pack "$root"
mkdir -p "$out"
rm -f "$out/$sample.play.zip" "$out/ruya-pack"
# build.sh exits 0 without ruya-pack, so the zip check below is the proof.
sh "$root/samples/$sample/build.sh"
zip="$root/samples/$sample/$sample.play.zip"
[ -s "$zip" ] || { echo "play-vm-files: $sample built no $sample.play.zip" >&2; exit 1; }
cp "$zip" "$out/$sample.play.zip"
cp "$RUYA_PACK" "$out/ruya-pack"
echo "play-vm-files: $out/$sample.play.zip ($(wc -c < "$out/$sample.play.zip") bytes) and ruya-pack"
