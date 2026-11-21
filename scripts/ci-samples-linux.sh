#!/bin/bash
# SPDX-License-Identifier: MIT
#
# CI "samples" job (RUY-822): compile both .play samples, build each .play.zip with the real
# ruya-pack and inspect it. Run it in Fedora 44 (the CI container, or WSL: FedoraLinux-44):
#
#     bash scripts/ci-samples-linux.sh
#
# It installs nothing. Packages (the same line as the `samples` job in .github/workflows/ci.yml):
#     gcc SDL3-devel pkgconf-pkg-config mingw64-gcc mingw32-gcc cargo rust findutils
# CARGO_TARGET_DIR overrides where ruya-pack is built (default: services/target-samples).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/lib-samples.sh"

samples_build_pack "$root" || exit 1

# Warnings fail here; a developer's plain ./build.sh keeps its defaults.
export CC="${CC:-cc} -Werror"
# The Windows build.sh quotes $MINGW_CC and $MINGW_CC32 as one word each, so -Werror goes in a tiny
# wrapper per compiler.
wrap=$(mktemp -d)
# The build outputs go on exit (lib-samples.sh).
clean() {
    rm -rf "$wrap"
    samples_clean_outputs "$root" hello-play-native hello-play-wine
}
trap clean EXIT
for w in "mingw-gcc:${MINGW_CC:-x86_64-w64-mingw32-gcc}" "mingw32-gcc:${MINGW_CC32:-i686-w64-mingw32-gcc}"; do
    printf '#!/bin/sh
exec %s -Werror "$@"
' "${w#*:}" > "$wrap/${w%%:*}"
    chmod +x "$wrap/${w%%:*}"
done
export MINGW_CC="$wrap/mingw-gcc" MINGW_CC32="$wrap/mingw32-gcc"

fail=0
summary=""
for s in hello-play-native hello-play-wine; do
    dir="$root/samples/$s"
    zip="$dir/$s.play.zip"
    rm -f "$zip"
    # The build scripts exit 0 without ruya-pack; the zip check below catches that.
    if ! sh "$dir/build.sh"; then
        summary="$summary$s: FAILED (build.sh)\n"; fail=1; continue
    fi
    if [ ! -s "$zip" ]; then
        summary="$summary$s: FAILED (no zip)\n"; fail=1; continue
    fi
    summary="$summary$s: $(wc -c < "$zip") bytes, inspect ok\n"
done

echo "== ci-samples summary =="
printf '%b' "$summary"
exit $fail
