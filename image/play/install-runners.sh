#!/usr/bin/env bash
# The image's system runners (ADR-038, docs/specs/05-play-packages.md section 6.4). Each runner is
# one folder image/play/runners/<Name>/ with
#   pin          the pinned upstream release: url=, sha256= and root= (the folder of the archive
#                that becomes the runner), comments with #
#   runner.json  the runner's file (ADR-037), shipped as is at the runner's root
#   anything else, such as licences/  our own files laid over the release at the same paths (the
#                licence texts of a release that ships none); never one the release already has
# Every runner's tree must carry a licence text at its root (LICENSE*, LICENCE*, COPYING* or
# licences/), from the release or from its pin folder.
# A new runner, or another major of one, is a new folder there: this script and image/Containerfile
# stay as they are, and the tmpfiles links (image/rootfs/usr/lib/tmpfiles.d/ruya-play-platform.conf)
# get its line (services/ruya-play/tests/platform.rs holds the folders and the lines together).
#
#   install-runners.sh fetch <runners> <play>         download each pinned release (any other SHA-256
#                      fails the build), unpack its root folder to <play>/runners/<Name>/ without group
#                      or world write bits, put runner.json and the pin folder's other files in it,
#                      refuse a tree without a licence text. Needs the network.
#   install-runners.sh check <ruya-pack> <play> <meta>  `ruya-pack runner-check` on each runner (the
#                      format's own parser and runner hash, never jq or a shell hash): writes
#                      <meta>/runners/<Name>/.ruya-runner-hash and the image's list <meta>/runners.list
#                      (name, family, kind, version, licence, source URL; the About pane reads it)
# Folders are taken in name order. Run by the play-runners stages of image/Containerfile.
set -euo pipefail

die() { echo "install-runners: $*" >&2; exit 1; }

# pin_value <pin> <key>: the value of the one line key=value.
pin_value() {
    local n
    n="$(grep -c "^$2=" "$1" || true)"
    [ "$n" = 1 ] || die "$1: $n lines $2= (exactly one wanted)"
    sed -n "s/^$2=//p" "$1"
}

# check_pin <pin>: only comments, blank lines and the three keys; a SHA-256, an https URL, a root
# folder that is one plain name.
check_pin() {
    local other
    other="$(grep -Ev '^(#.*|[[:space:]]*|url=.*|sha256=.*|root=.*)$' "$1" || true)"
    [ -z "$other" ] || die "$1: unknown line: $other"
    [[ "$(pin_value "$1" sha256)" =~ ^[0-9a-f]{64}$ ]] || die "$1: sha256 is not 64 lower-case hex digits"
    [[ "$(pin_value "$1" url)" == https://* ]] || die "$1: url is not https"
    local root
    root="$(pin_value "$1" root)"
    [[ -n "$root" && "$root" != . && "$root" != .. && "$root" != */* ]] || die "$1: root is not one folder name"
}

# add_own_files <pin folder> <tree> <name>: every file of the pin folder other than pin and
# runner.json (licence texts in licences/, for a release that ships none) goes to the same path in the
# tree, 0644. A path the release already has fails the build (our files never replace the release's),
# and so does anything in the pin folder that is not a plain file, or a target folder that leads out of
# the tree.
add_own_files() {
    local dir="${1%/}" tree="$2" name="$3" rel parent top
    top="$(realpath "$tree")"
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        case "$rel" in pin | runner.json) continue ;; esac
        [ -f "$dir/$rel" ] && [ ! -L "$dir/$rel" ] || die "$name: $rel in the pin folder is not a plain file"
        [ ! -e "$tree/$rel" ] && [ ! -L "$tree/$rel" ] || die "$name: the release already has $rel"
        parent="$(dirname "$tree/$rel")"
        mkdir -p "$parent"
        case "$(realpath "$parent")/" in "$top"/*) ;; *) die "$name: $rel would leave the runner's tree" ;; esac
        install -m 0644 "$dir/$rel" "$tree/$rel"
    done < <(cd "$dir" && find . -mindepth 1 ! -type d -print0 | sort -z)
}

# has_licence <tree>: a licence text at the runner's root: a LICENSE*, LICENCE* or COPYING* file, or a
# file in licences/ (ADR-025's notice duty: the text travels with the binaries).
has_licence() {
    [ -n "$(find "$1" -maxdepth 1 -type f \( -name 'LICENSE*' -o -name 'LICENCE*' -o -name 'COPYING*' \) -print -quit)" ] ||
        [ -n "$(find "$1/licences" -type f -print -quit 2>/dev/null)" ]
}

fetch() {
    local runners="$1" play="$2" dir name pin url sha root work tree writable
    command -v curl >/dev/null || die "no curl"
    mkdir -p "$play/runners"
    for dir in "$runners"/*/; do
        name="$(basename "$dir")"
        pin="$dir/pin"
        [ -f "$pin" ] && [ -f "$dir/runner.json" ] || die "$name: needs pin and runner.json"
        check_pin "$pin"
        url="$(pin_value "$pin" url)"; sha="$(pin_value "$pin" sha256)"; root="$(pin_value "$pin" root)"
        tree="$play/runners/$name"
        [ ! -e "$tree" ] || die "$name: $tree exists"
        work="$(mktemp -d)"
        curl -fsSL --proto '=https' --retry 3 -o "$work/release" "$url" || die "$name: cannot download $url"
        echo "$sha  $work/release" | sha256sum -c --quiet - || die "$name: $url is not the pinned release ($sha)"
        mkdir "$work/x"
        tar -xf "$work/release" -C "$work/x" --no-same-owner
        [ -d "$work/x/$root" ] && [ ! -L "$work/x/$root" ] || die "$name: the release has no folder $root"
        mv "$work/x/$root" "$tree"
        rm -rf "$work"
        install -m 0644 "$dir/runner.json" "$tree/runner.json"
        add_own_files "$dir" "$tree" "$name"
        has_licence "$tree" || die "$name: no licence text at the runner's root (LICENSE*, LICENCE*, COPYING* or a file in licences/); a release that ships none gets them from licences/ in its pin folder"
        # Nothing the image ships is group- or world-writable (the release has a few 0666 files).
        chmod -R go-w "$tree"
        writable="$(find "$tree" ! -type l -perm /022 | head -n 5)"
        [ -z "$writable" ] || die "$name: still group/world-writable: $writable"
        echo "install-runners: $name from $url, $(du -sm "$tree" | cut -f1) MiB"
    done
    [ -n "$(ls -A "$play/runners")" ] || die "no runner in $runners"
}

check() {
    local pack="$1" play="$2" meta="$3" tree name
    mkdir -p "$meta/runners"
    : > "$meta/runners.list"
    for tree in "$play"/runners/*/; do
        tree="${tree%/}"
        name="$(basename "$tree")"
        "$pack" runner-check "$tree" --write-hash --record "$meta/runners.list" || die "$name: runner-check refused it"
        install -D -m 0644 "$tree/.ruya-runner-hash" "$meta/runners/$name/.ruya-runner-hash"
    done
    [ -s "$meta/runners.list" ] || die "no runner in $play/runners"
    chmod 0644 "$meta/runners.list"
    cat "$meta/runners.list"
}

case "${1:-}" in
fetch) [ $# = 3 ] || die "usage: fetch <runners> <play>"; fetch "$2" "$3" ;;
check) [ $# = 4 ] || die "usage: check <ruya-pack> <play> <meta>"; check "$2" "$3" "$4" ;;
*) die "usage: install-runners.sh fetch <runners> <play> | check <ruya-pack> <play> <meta>" ;;
esac
