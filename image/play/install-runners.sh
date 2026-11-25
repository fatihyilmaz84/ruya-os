#!/usr/bin/env bash
# The image's system runners (ADR-038, docs/specs/05-play-packages.md section 6.4). Each runner is
# one folder image/play/runners/<Name>/ with
#   pin          the pinned upstream release: url=, sha256= and root= (the folder of the archive
#                that becomes the runner), comments with #
#   runner.json  the runner's file (ADR-037), shipped as is at the runner's root
#   prune        optional: the release's files to delete, one glob per line relative to the runner's root, with
#                a comment giving the reason (ruya_play_format::runner::Prune is the grammar)
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
#                      or world write bits, delete what the pin folder's prune names (before the runner hash
#                      is computed), put runner.json and the pin folder's other files in it,
#                      refuse a tree without a licence text. Needs the network.
#   install-runners.sh check-pin <pin>               only the pin's grammar (check_pin); the same verdicts as
#                      ruya_play_format::runner::Pin::parse on services/ruya-play-format/tests/fixtures/pins/
#   install-runners.sh check-prune <prune>           only the prune file's grammar (check_prune); the same verdicts as
#                      ruya_play_format::runner::Prune::parse on services/ruya-play-format/tests/fixtures/prunes/
#   install-runners.sh check <ruya-pack> <play> <meta>  `ruya-pack runner-check` on each runner (the
#                      format's own parser and runner hash, never jq or a shell hash): writes
#                      <meta>/runners/<Name>/.ruya-runner-hash. The shell lists the runners through
#                      Library1 ListRunners (RUY-959), which scans the folders themselves
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
# folder that is one plain name. A pin is LF only (as ruya_play_format::runner::Pin::parse): the CR
# is counted with tr: Git Bash drops it in grep, sed and $(...), but the number printed has none.
check_pin() {
    [ "$(tr -cd '\r' < "$1" | wc -c)" = 0 ] || die "$1: carriage return: the pin file is LF only"
    local other
    other="$(grep -Ev '^(#.*|[[:space:]]*|url=.*|sha256=.*|root=.*)$' "$1" || true)"
    [ -z "$other" ] || die "$1: unknown line: $other"
    [[ "$(pin_value "$1" sha256)" =~ ^[0-9a-f]{64}$ ]] || die "$1: sha256 is not 64 lower-case hex digits"
    [[ "$(pin_value "$1" url)" == https://* ]] || die "$1: url is not https"
    local root
    root="$(pin_value "$1" root)"
    [[ -n "$root" && "$root" != . && "$root" != .. && "$root" != */* ]] || die "$1: root is not one folder name"
}

# check_prune <prune>: only comments, blank lines and globs; at least one of each kind; a glob is a
# relative path of plain components (letters, digits and ._+- with * and ? as wildcards), none empty,
# . or .. (the same verdicts as ruya_play_format::runner::Prune::parse).
check_prune() {
    local line comments=0 globs=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == '#'* ]]; then
            comments=$((comments + 1))
        elif [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
            [[ "$line" =~ ^[A-Za-z0-9._+*?-]+(/[A-Za-z0-9._+*?-]+)*$ ]] || die "$1: not a plain relative glob: $line"
            case "/$line/" in */./* | */../*) die "$1: not a plain relative glob: $line" ;; esac
            globs=$((globs + 1))
        fi
    done < "$1"
    [ "$comments" -gt 0 ] || die "$1: no comment line giving the reason"
    [ "$globs" -gt 0 ] || die "$1: no glob"
}

# inside_tree <top> <path>: the real path of <path> is <top> (a realpath) or below it, so a folder link in
# the release cannot lead a write or a delete out of the runner's tree.
inside_tree() {
    case "$(realpath "$2")/" in "$1"/*) return 0 ;; esac
    return 1
}

# prune_tree <prune> <tree> <name>: delete what each glob of the prune file matches in the runner's
# tree (a file or a link, never a folder). A glob that matches nothing fails the build: the release
# moved on and the prune is stale, so someone has to look.
prune_tree() {
    local prune="$1" tree="$2" name="$3" glob m n=0 top matches=()
    top="$(realpath "$tree")"
    check_prune "$prune"
    while IFS= read -r glob; do
        [[ "$glob" == '#'* || "$glob" =~ ^[[:space:]]*$ ]] && continue
        # mapfile: a name with a space is neither split nor globbed again
        mapfile -t matches < <(cd "$tree" && compgen -G "$glob" || true)
        [ "${#matches[@]}" -gt 0 ] || die "$name: prune $glob matches nothing in the release"
        for m in "${matches[@]}"; do
            inside_tree "$top" "$(dirname "$tree/$m")" || die "$name: prune $glob: $m is outside the runner's tree"
            [ ! -d "$tree/$m" ] || [ -L "$tree/$m" ] || die "$name: prune $glob matches the folder $m"
            rm -f -- "$tree/$m"
            n=$((n + 1))
        done
    done < "$prune"
    echo "install-runners: $name: pruned $n file(s) ($(basename "$prune"))"
}

# add_own_files <pin folder> <tree> <name>: every file of the pin folder other than pin, prune and
# runner.json (licence texts in licences/, for a release that ships none) goes to the same path in the
# tree, 0644. A path the release already has fails the build (our files never replace the release's),
# and so does anything in the pin folder that is not a plain file, or a target folder that leads out of
# the tree.
add_own_files() {
    local dir="${1%/}" tree="$2" name="$3" rel parent top
    top="$(realpath "$tree")"
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        case "$rel" in pin | runner.json | prune) continue ;; esac
        [ -f "$dir/$rel" ] && [ ! -L "$dir/$rel" ] || die "$name: $rel in the pin folder is not a plain file"
        [ ! -e "$tree/$rel" ] && [ ! -L "$tree/$rel" ] || die "$name: the release already has $rel"
        parent="$(dirname "$tree/$rel")"
        mkdir -p "$parent"
        inside_tree "$top" "$parent" || die "$name: $rel would leave the runner's tree"
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
        [ ! -f "$dir/prune" ] || prune_tree "$dir/prune" "$tree" "$name"
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
    local pack="$1" play="$2" meta="$3" tree name checked=0
    mkdir -p "$meta/runners"
    for tree in "$play"/runners/*/; do
        [ -d "$tree" ] || continue
        tree="${tree%/}"
        name="$(basename "$tree")"
        "$pack" runner-check "$tree" --write-hash || die "$name: runner-check refused it"
        install -D -m 0644 "$tree/.ruya-runner-hash" "$meta/runners/$name/.ruya-runner-hash"
        checked=$((checked + 1))
    done
    [ "$checked" -gt 0 ] || die "no runner in $play/runners"
    echo "install-runners: $checked runner(s) checked"
}

case "${1:-}" in
fetch) [ $# = 3 ] || die "usage: fetch <runners> <play>"; fetch "$2" "$3" ;;
check-pin) [ $# = 2 ] || die "usage: check-pin <pin>"; check_pin "$2" ;;
check-prune) [ $# = 2 ] || die "usage: check-prune <prune>"; check_prune "$2" ;;
check) [ $# = 4 ] || die "usage: check <ruya-pack> <play> <meta>"; check "$2" "$3" "$4" ;;
*) die "usage: install-runners.sh fetch <runners> <play> | check-pin <pin> | check-prune <prune> | check <ruya-pack> <play> <meta>" ;;
esac
