#!/bin/bash
# Cuts the shell's icon fonts from Material Symbols Rounded (T-157, ADR-013).
# Run in the WSL distribution: python3-fonttools is needed (sudo dnf install python3-fonttools);
# skia-pathops (overlap removal, see below) is installed into a throwaway virtual environment from
# scripts/subset-icons-requirements.txt (pinned version, SHA-256 of the wheels, pip --require-hashes).
#
#   scripts/subset-icons.sh
#
# Downloads the variable font (pinned commit, SHA-256 checked) into a fresh temporary directory,
# keeps the code points listed in shell/fonts/icons.txt, and writes two static instances
# (wght 400, GRAD 0, opsz 40) to shell/fonts/: outlined (FILL 0) and filled (FILL 1), with their
# overlapping contours merged (T-206): the variable font draws the filled gear as two coincident
# contours of opposite direction that cancel in the nonzero fill rule, and the Windows rasteriser
# leaves speckled holes where their edges meet (the gear in the active Settings pill).
# Lines of icons.txt that end in the word `ruya` are not Material's: scripts/add-pad-glyphs.py adds
# them (the controller silhouettes, one per SVG in shell/art/pads/, T-199, RUY-491) into both cuts, at
# private-use code points that upstream does not use (checked here).
# The outputs, icons.txt and the upstream LICENSE are committed; the download is not.
set -euo pipefail

COMMIT=10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7
BASE="https://raw.githubusercontent.com/google/material-design-icons/$COMMIT"
AXES="MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D"
SHA_FONT=7e74e36533ccee12c2b81e75bfcf3ccf123d3bb7e7e46d65d94445f23db0c97c
SHA_CODEPOINTS=a7404d9e5a1b63f496cf05ace45d386075886b5a7f123fba9f29527cb6006fde
SHA_LICENSE=58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo/shell/fonts"
list="$out/icons.txt"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

python3 -m venv --system-site-packages venv
# skia-pathops (for --remove-overlaps): pinned, hash-checked wheels only (T-297)
venv/bin/pip install -q --only-binary=:all: --require-hashes -r "$repo/scripts/subset-icons-requirements.txt"
PY="$work/venv/bin/python"

fetch() {   # fetch <url path> <file> <sha256>
    curl -fsSL -o "$2" "$BASE/$1"
    echo "$3  $2" | sha256sum -c --quiet - || { echo "SHA-256 mismatch for $2" >&2; exit 1; }
}
fetch "variablefont/$AXES.ttf" variable.ttf "$SHA_FONT"
fetch "variablefont/$AXES.codepoints" upstream.codepoints "$SHA_CODEPOINTS"
fetch "LICENSE" LICENSE "$SHA_LICENSE"

# icons.txt -> a comma-separated U+ list; every pair must match the upstream code point.
unicodes=""
while read -r name cp rest; do
    case "$name" in ""|"#"*) continue ;; esac
    if [ "$rest" = "ruya" ]; then   # our own glyph: its code point must be free upstream
        if grep -qi " $cp\$" upstream.codepoints; then
            echo "icons.txt: $name uses U+$cp, which upstream assigns to an icon" >&2
            exit 1
        fi
        continue
    fi
    want="$(grep -m1 "^$name " upstream.codepoints | cut -d' ' -f2 || true)"
    if [ "$want" != "$cp" ]; then
        echo "icons.txt: $name is $cp, upstream says '${want:-unknown}'" >&2
        exit 1
    fi
    unicodes="$unicodes${unicodes:+,}U+$cp"
done < "$list"
[ -n "$unicodes" ] || { echo "icons.txt lists no icons" >&2; exit 1; }

# Subset the variable font first (fast), then cut the two instances.
"$PY" -m fontTools.subset variable.ttf --unicodes="$unicodes" --layout-features= --no-hinting \
    --drop-tables+=DSIG,STAT --output-file=subset.ttf

cut() {   # cut <fill> <family name> <output file>
    "$PY" -m fontTools.varLib.instancer subset.ttf FILL="$1" GRAD=0 opsz=40 wght=400 --remove-overlaps -o "cut-$1.ttf" -q
    "$PY" "$repo/scripts/add-pad-glyphs.py" "cut-$1.ttf" "$1" "pads-$1.ttf" "$list" "$repo/shell/art/pads"
    "$PY" - "pads-$1.ttf" "$2" "$out/$3" <<'EOF'
import sys
from fontTools.ttLib import TTFont
src, family, dst = sys.argv[1:4]
font = TTFont(src)
for rec in font["name"].names:
    if rec.nameID in (1, 16):
        rec.string = family
    elif rec.nameID in (4, 6):
        rec.string = family if rec.nameID == 4 else family.replace(" ", "")
    elif rec.nameID in (2, 17):
        rec.string = "Regular"
font.save(dst)
EOF
}
cut 0 "Material Symbols Rounded" MaterialSymbolsRounded.ttf
cut 1 "Material Symbols Rounded Filled" MaterialSymbolsRoundedFilled.ttf

cp LICENSE "$out/LICENSE-MaterialSymbols.txt"
ls -l "$out"
