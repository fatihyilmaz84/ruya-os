#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
#
# Builds the Wine sample: cross-compiles the two Windows programs into package/payload/, then,
# when ruya-pack is on the PATH (or RUYA_PACK names it), writes play.files and the zip.
# Needs a cross compiler: Fedora `sudo dnf install mingw64-gcc`, Debian `gcc-mingw-w64-x86-64`.
#
#     ./build.sh                     # cross-compile, then build hello-play-wine.play.zip
#     ./build.sh --payload-only      # cross-compile only
set -eu

here=$(cd "$(dirname "$0")" && pwd)
payload="$here/package/payload"
cc=${MINGW_CC:-x86_64-w64-mingw32-gcc}

mkdir -p "$payload"
"$cc" -O2 -Wall -Wextra -mwindows -o "$payload/hello.exe" "$here/src/hello.c" -lshell32 -lgdi32 -luser32
"$cc" -O2 -Wall -Wextra -o "$payload/setup.exe" "$here/src/setup.c"
echo "built $payload/hello.exe and $payload/setup.exe"

[ "${1:-}" = "--payload-only" ] && exit 0

pack=${RUYA_PACK:-ruya-pack}
if ! command -v "$pack" >/dev/null 2>&1; then
    echo "ruya-pack not found: set RUYA_PACK or put it on the PATH to build the zip" >&2
    exit 0
fi
# The sample uses source: system, so nothing is bundled; the dry run names the OS's Wine.
"$pack" build "$here/package" -o "$here/hello-play-wine.play.zip"
"$pack" inspect "$here/hello-play-wine.play.zip" --system-wine 10.2
