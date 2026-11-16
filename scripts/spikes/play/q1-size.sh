#!/usr/bin/env bash
# Q1 sizes: commit and install time, peak extra disk and deduplication for a
# generated play.* app with an incompressible payload.
# Usage: q1-size.sh <GiB> [archive-z2|bare-user-only]
#   The staged payload stands for the unpacked package (§7.3 step 4). It is
#   hardlinked into the build dir (LINK_PAYLOAD), so the build dir costs nothing.
#   A downloaded .play.zip kept until the commit would add one more <GiB>.
. "$(dirname "$0")/common.sh"
GB=${1:?size in GiB}
export REPO_MODE=${2:-archive-z2}
export REPO=$WORK/repo-size-$REPO_MODE REMOTE=ruy91-size
export LINK_PAYLOAD=1
FS=/var
OUT=$LOGS/q1-size-${GB}G-$REPO_MODE.txt
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }

# Fresh state for this measurement.
flatpak uninstall -y --system --noninteractive play.test.big1 play.test.big2 >/dev/null 2>&1 || true
flatpak remote-delete --system --force "$REMOTE" >/dev/null 2>&1 || true
rm -rf "$REPO" "$WORK/build/play.test.big1" "$WORK/build/play.test.big2" "$WORK/src/big"
ensure_repo; ensure_remote
[ -n "$(flatpak list --system --columns=ref | grep Play.Launcher)" ] || { build_launcher; install_ref org.ruyaos.Play.Launcher; }
flatpak build-update-repo --gpg-sign="$(key_id)" --gpg-homedir="$GNUPGHOME" "$REPO" >/dev/null 2>&1 || true

mkdir -p "$WORK/src/big"
echo '{ "id": "test.big", "run": { "command": ["/bin/true"] } }' > "$WORK/src/big.play.json"
base=$(fs_used $FS)
t=$(now)
head -c "$((GB * 1024 * 1024 * 1024))" /dev/urandom > "$WORK/src/big/payload.bin"
sync
say "payload ${GB} GiB generated in $(elapsed "$t") s, +$(( ($(fs_used $FS) - base) / 1048576 )) MiB"
staged=$(fs_used $FS)

# Peak sampler: highest used bytes on $FS while the steps run.
( while :; do fs_used $FS; sleep 0.5; done ) > "$LOGS/peak.samples" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

t=$(now)
build_app play.test.big1 "$WORK/src/big" "$WORK/src/big.play.json" >/dev/null 2>"$LOGS/big1-export.log"
sync
say "commit (build-export, $REPO_MODE): $(elapsed "$t") s, repo $(du -sm "$REPO" | cut -f1) MiB, fs +$(( ($(fs_used $FS) - staged) / 1048576 )) MiB over staging"
pre_inst=$(fs_used $FS)
t=$(now)
install_ref play.test.big1 2>"$LOGS/big1-install.log"
sync
say "install: $(elapsed "$t") s, fs +$(( ($(fs_used $FS) - pre_inst) / 1048576 )) MiB"
after1=$(fs_used $FS)
kill $SAMPLER; trap - EXIT
peak=$(sort -n "$LOGS/peak.samples" | tail -1)
say "peak extra over the state before the payload: $(( (peak - base) / 1048576 )) MiB (payload $((GB * 1024)) MiB)"
say "after install, extra over before the payload: $(( (after1 - base) / 1048576 )) MiB (staging + local repo + installed)"

# Deduplication: a second app bundling the same large file.
cp -al "$WORK/src/big" "$WORK/src/big2"
echo "second app" > "$WORK/src/big2/other.txt"
before2=$(fs_used $FS); fl2=$(du -sm /var/lib/flatpak | cut -f1)
t=$(now)
build_app play.test.big2 "$WORK/src/big2" "$WORK/src/big.play.json" >/dev/null 2>"$LOGS/big2-export.log"
install_ref play.test.big2 2>"$LOGS/big2-install.log"
sync
say "second app with the same file: export+install $(elapsed "$t") s, fs +$(( ($(fs_used $FS) - before2) / 1048576 )) MiB, /var/lib/flatpak +$(( $(du -sm /var/lib/flatpak | cut -f1) - fl2 )) MiB"

# What is left once staging and the local repo are dropped (the importer's end state).
rm -rf "$WORK/src/big" "$WORK/src/big2" "$WORK/build/play.test.big1" "$WORK/build/play.test.big2" "$REPO"
sync
say "after dropping staging and the local repo: extra over before $(( ($(fs_used $FS) - base) / 1048576 )) MiB"
flatpak uninstall -y --system --noninteractive play.test.big1 play.test.big2 >/dev/null
flatpak remote-delete --system --force "$REMOTE" >/dev/null
sync
say "after uninstall: extra $(( ($(fs_used $FS) - base) / 1048576 )) MiB"
