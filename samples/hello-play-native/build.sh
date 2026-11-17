#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
#
# Builds the native sample: compiles the Hello Game sources (../hello-game) into
# package/payload/hello-game, then, when ruya-pack is on the PATH (or RUYA_PACK names it), writes
# play.files and the zip. Needs a C compiler and SDL3 development files (Fedora: gcc SDL3-devel).
#
#     ./build.sh                     # compile, then build hello-play-native.play.zip
#     ./build.sh --payload-only      # compile only
set -eu

here=$(cd "$(dirname "$0")" && pwd)
game="$here/../hello-game/src"
payload="$here/package/payload"

mkdir -p "$payload"
# shellcheck disable=SC2046
${CC:-cc} -std=c11 -O2 -D_DEFAULT_SOURCE -Wall -Wextra \
    -o "$payload/hello-game" "$game/main.c" "$game/game.c" "$game/save.c" \
    $(pkg-config --cflags --libs sdl3) -lm
chmod 755 "$payload/hello-game"
echo "built $payload/hello-game"

[ "${1:-}" = "--payload-only" ] && exit 0

pack=${RUYA_PACK:-ruya-pack}
if ! command -v "$pack" >/dev/null 2>&1; then
    echo "ruya-pack not found: set RUYA_PACK or put it on the PATH to build the zip" >&2
    exit 0
fi
"$pack" build "$here/package" -o "$here/hello-play-native.play.zip"
"$pack" inspect "$here/hello-play-native.play.zip"
