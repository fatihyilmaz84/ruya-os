#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
#
# Builds the Windows sample: cross-compiles the three Windows programs into package/payload/
# (hello.exe and setup.exe 64-bit, check.exe 32-bit), then, when ruya-pack is on the PATH (or
# RUYA_PACK names it), writes play.files and the zip.
# Needs two cross compilers: Fedora `sudo dnf install mingw64-gcc mingw32-gcc`, Debian
# `gcc-mingw-w64-x86-64 gcc-mingw-w64-i686`.
#
#     ./build.sh                     # cross-compile, then build hello-play-wine.play.zip
#     ./build.sh --payload-only      # cross-compile only
set -eu

here=$(cd "$(dirname "$0")" && pwd)
payload="$here/package/payload"
cc=${MINGW_CC:-x86_64-w64-mingw32-gcc}
cc32=${MINGW_CC32:-i686-w64-mingw32-gcc}

mkdir -p "$payload"
"$cc" -O2 -Wall -Wextra -mwindows -o "$payload/hello.exe" "$here/src/hello.c" -lshell32 -lgdi32 -luser32
"$cc" -O2 -Wall -Wextra -o "$payload/setup.exe" "$here/src/setup.c"
"$cc32" -O2 -Wall -Wextra -static -o "$payload/check.exe" "$here/src/check.c" -lws2_32 -lshell32
echo "built $payload/hello.exe, $payload/setup.exe and $payload/check.exe"

[ "${1:-}" = "--payload-only" ] && exit 0

pack=${RUYA_PACK:-ruya-pack}
if ! command -v "$pack" >/dev/null 2>&1; then
    echo "ruya-pack not found: set RUYA_PACK or put it on the PATH to build the zip" >&2
    exit 0
fi
# The sample uses source: system, so nothing is bundled; the dry run names the OS's GE-Proton.
"$pack" build "$here/package" -o "$here/hello-play-wine.play.zip"
"$pack" inspect "$here/hello-play-wine.play.zip" --system-proton-ge GE-Proton11-12
