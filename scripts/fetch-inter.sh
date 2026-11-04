#!/bin/bash
# Cuts the shell's typeface from the Inter 4.1 release (T-145, ADR-012).
# Run in the WSL distribution: python3-fonttools and unzip are needed.
#
#   scripts/fetch-inter.sh
#
# Downloads the official release zip from github.com/rsms/inter (pinned URL, SHA-256 checked)
# into a fresh temporary directory. The archive is untrusted data: only a fixed list of members
# is extracted, nothing from it is ever run. Regular, Light and SemiBold are subset to Latin +
# Latin Extended-A (plus common punctuation) and written to shell/fonts/ together with the OFL
# text. The outputs are committed; the download is not.
set -euo pipefail

URL="https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
SHA_ZIP=9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo/shell/fonts"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

curl -fsSL -o inter.zip "$URL"
echo "$SHA_ZIP  inter.zip" | sha256sum -c --quiet - || { echo "SHA-256 mismatch for inter.zip" >&2; exit 1; }

unzip -q -j inter.zip extras/ttf/Inter-Regular.ttf extras/ttf/Inter-Light.ttf \
    extras/ttf/Inter-SemiBold.ttf LICENSE.txt -d src

unicodes="U+0020-007E,U+00A0-017F,U+02C6,U+02DA,U+02DC,U+2013-2014,U+2018-201E,U+2022,U+2026,U+20AC,U+2190-2193,U+2212"
for w in Regular Light SemiBold; do
    python3 -m fontTools.subset "src/Inter-$w.ttf" --unicodes="$unicodes" --layout-features='kern,liga,calt,ccmp,locl,mark,mkmk' \
        --no-hinting --drop-tables+=DSIG --output-file="$out/Inter-$w.ttf"
done
cp src/LICENSE.txt "$out/OFL-Inter.txt"
ls -l "$out"
