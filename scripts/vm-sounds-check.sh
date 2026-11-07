#!/usr/bin/env bash
# Checks the sound themes inside a running VM, as root (T-227; a lead run, not part of dev.ps1 test):
#   - the bundled theme is installed where the shell looks for it (/usr/share/ruyaos/sounds/dreamglass),
#     owned by root and not writable by the shell's user, with the manifest, the 13 cues and the ambient;
#   - the shell binary's own checker (the function the shell uses) accepts it, and refuses a broken copy
#     and a copy whose manifest points outside its folder;
#   - the shell's journal has no complaint about a sound theme;
#   - the licence notice is installed.
# What it cannot do: hear anything. With the VM booted with -Audio (docs/dev-setup.md "Audio in the VM",
# scripts/vm-audio-check.sh) the owner listens to the cues and to the ambient loop; that is the
# listening criterion of T-227 and stays with the owner.
# Boot with plain smoke-test.ps1 -Keep, then:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-sounds-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-sounds-check.sh
set -u
dir=/usr/share/ruyaos/sounds/dreamglass
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

[ -f "$dir/theme.json" ] && ok "manifest installed" || bad "no $dir/theme.json"
cues="navigate select back error notification warning open close page volume startup toggle-on toggle-off"
missing=""
for c in $cues; do [ -s "$dir/$c.wav" ] || missing="$missing $c"; done
[ -z "$missing" ] && ok "all 13 cue files present" || bad "missing cue files:$missing"
[ -s "$dir/ambient.flac" ] && ok "ambient loop present ($(stat -c %s "$dir/ambient.flac") bytes)" || bad "no ambient.flac"

owner=$(stat -c %U "$dir/theme.json" 2>/dev/null)
[ "$owner" = root ] && ok "owned by root" || bad "owner is '$owner'"
if runuser -u ruya-shell -- test -w "$dir/theme.json"; then bad "the shell's user can write the bundled theme"; else ok "not writable by ruya-shell"; fi
if runuser -u ruya-shell -- test -r "$dir/ambient.flac"; then ok "readable by ruya-shell"; else bad "ruya-shell cannot read the ambient file"; fi

shell=$(command -v ruya-shell || echo /usr/bin/ruya-shell)
if [ -x "$shell" ]; then
    out=$("$shell" --check-sound-theme "$dir" 2>&1); rc=$?
    echo "    $out"
    [ $rc -eq 0 ] && ok "the shell's checker accepts the bundled theme" || bad "the checker refused the bundled theme"
    out=$("$shell" --check-sound-theme-fixtures 2>&1); rc=$?
    [ $rc -eq 0 ] && ok "the checker fixtures end as expected ($(echo "$out" | grep -c '^ok') cases)" || { echo "$out" | grep '^FAIL'; bad "checker fixtures"; }

    tmp=$(mktemp -d)
    cp -r "$dir" "$tmp/broken"
    : > "$tmp/broken/select.wav"
    "$shell" --check-sound-theme "$tmp/broken" >/dev/null 2>&1 && bad "a truncated cue was accepted" || ok "a truncated cue is refused"
    cp -r "$dir" "$tmp/escape"
    sed -i 's#"select.wav"#"../outside.wav"#' "$tmp/escape/theme.json"
    "$shell" --check-sound-theme "$tmp/escape" >/dev/null 2>&1 && bad "a path outside the folder was accepted" || ok "a path outside the folder is refused"
    cp -r "$dir" "$tmp/link"; rm -f "$tmp/link/back.wav"; ln -s "$dir/select.wav" "$tmp/link/back.wav"
    "$shell" --check-sound-theme "$tmp/link" >/dev/null 2>&1 && bad "a linked cue file was accepted" || ok "a linked cue file is refused"
    rm -rf "$tmp"
else
    bad "ruya-shell not found"
fi

if journalctl -b -u 'ruya-compositor@*' -u ruya-shell --no-pager 2>/dev/null | grep -i "sound theme" | grep -iv "^--" | grep -q .; then
    journalctl -b -u 'ruya-compositor@*' -u ruya-shell --no-pager 2>/dev/null | grep -i "sound theme" | head -5
    bad "the shell logged a sound theme problem"
else
    ok "no sound theme complaint in the journal"
fi

[ -s /usr/share/licenses/ruyaos/LICENSE-Sounds.txt ] && ok "licence notice installed" || bad "no LICENSE-Sounds.txt"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
