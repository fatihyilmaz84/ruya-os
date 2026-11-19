# SPDX-License-Identifier: MIT
#
# Shared by scripts/ci-samples-linux.sh and scripts/play-vm-files.sh (RUY-860): building ruya-pack
# and removing the .play samples' build outputs again. Source it; it sets nothing by itself.
#     . "$(dirname "$0")/lib-samples.sh"

# samples_build_pack <repo root>: builds ruya-pack (release) into $CARGO_TARGET_DIR (default
# <root>/services/target-samples) and exports RUYA_PACK, the path of the binary.
samples_build_pack() {
    local root=$1
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/services/target-samples}"
    (cd "$root/services" && cargo build -p ruya-pack --locked --release) || return 1
    export RUYA_PACK="$CARGO_TARGET_DIR/release/ruya-pack"
    [ -x "$RUYA_PACK" ] || { echo "samples: $RUYA_PACK was not built" >&2; return 1; }
}

# samples_clean_outputs <repo root> <sample>...: the build outputs of the samples (all git-ignored).
# Left in place they fail ruya-pack's samples test.
samples_clean_outputs() {
    local root=$1 s p
    shift
    for s in "$@"; do
        p="$root/samples/$s"
        rm -rf "$p/package/payload" "$p/package/play.files" "$p/package/play.sig" "$p/$s.play.zip"
    done
}
