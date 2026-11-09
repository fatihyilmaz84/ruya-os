#!/usr/bin/env bash
# Checks the sound themes inside a running VM, as root (T-227; a lead run, not part of dev.ps1 test):
#   - the bundled theme is installed where the shell looks for it (/usr/share/ruyaos/sounds/dreamglass),
#     owned by root and not writable by the shell's user, with the manifest, the 13 cues and the ambient;
#   - the shell binary's own checker (the function the shell uses) accepts it, and refuses a broken copy
#     and a copy whose manifest points outside its folder;
#   - the shell's journal has no complaint about a sound theme;
#   - the licence notice is installed;
#   - (T-321) the playback probe's output and the shell's own output opened (no "QAudioFormat not valid", no
#     "Requested output sample rate 0"), and with a sound device (-Audio) the shell's ambient stream is
#     `running` in PipeWire; if it is not (the screen saver pauses the bed) the script restarts the shell once.
# What it cannot do: hear anything. With the VM booted with -Audio (docs/dev-setup.md "Audio in the VM",
# scripts/vm-audio-check.sh) the owner listens to the cues and to the ambient loop; that is the
# listening criterion of T-227 and stays with the owner.
# Boot with plain smoke-test.ps1 -Keep, then:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-sounds-check.sh scripts/vm-sounds-probe.qml root@127.0.0.1:/root/
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
    # T-294: the image installs the theme as files, so the binary must not carry a second copy of it as a Qt
    # resource (RUYA_SOUNDS_RESOURCE is off when RUYA_COMPOSITOR is on). The same call on a Windows/Linux test
    # build, which embeds it, ends 0.
    "$shell" --check-sound-theme :/qt/qml/RuyaShell/sounds/dreamglass >/dev/null 2>&1 && bad "ruya-shell embeds a second copy of the bundled theme" || ok "no second copy of the bundled theme in the binary"
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
    # T-296: a folder inside the theme that is a link to somewhere else. Each file below it is a plain
    # file and not a link itself, so only the check that the real path stays inside the theme refuses it.
    # The control right before it has the same layout with a real folder and must be accepted, so the
    # refusal is the link's and not a side effect of the subfolder or of the changed manifest.
    cp -r "$dir" "$tmp/subdir"; mkdir "$tmp/subdir/sub"; mv "$tmp/subdir/select.wav" "$tmp/subdir/sub/select.wav"
    sed -i 's#"select.wav"#"sub/select.wav"#' "$tmp/subdir/theme.json"
    "$shell" --check-sound-theme "$tmp/subdir" >/dev/null 2>&1 && ok "a cue in a real subfolder is accepted (control)" || bad "a cue in a real subfolder was refused (the control for the next case)"
    cp -r "$dir" "$tmp/dirlink"; mkdir "$tmp/elsewhere"; mv "$tmp/dirlink/select.wav" "$tmp/elsewhere/select.wav"
    ln -s "$tmp/elsewhere" "$tmp/dirlink/sub"
    sed -i 's#"select.wav"#"sub/select.wav"#' "$tmp/dirlink/theme.json"
    "$shell" --check-sound-theme "$tmp/dirlink" >/dev/null 2>&1 && bad "a subfolder linking outside the theme was accepted" || ok "a subfolder that links outside the theme is refused"
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

# The image's own Qt Multimedia plays the ambient loop (FLAC): the probe loads it at volume 0 as the shell's user.
# runuser does not start a session, so XDG_RUNTIME_DIR is set to the shell user's own (/run/user/<uid>, where its
# PipeWire socket is): without it Qt Multimedia finds no audio server and "PlayingState not reached" is a false alarm.
# scp scripts/vm-sounds-probe.qml to /root/ together with this script.
if [ -f /root/vm-sounds-probe.qml ]; then
    work=$(mktemp -d); cp /root/vm-sounds-probe.qml "$work/probe.qml"; chmod 755 "$work"; chmod 644 "$work/probe.qml"
    # QT_FORCE_STDERR_LOGGING: Fedora's Qt otherwise sends console.warn and its own warnings to the journal, and
    # probe.log would hold only FFmpeg's lines. QT_AUDIO_BACKEND as in the compositor unit.
    runuser -u ruya-shell -- env QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 QT_AUDIO_BACKEND=pulseaudio \
        XDG_RUNTIME_DIR="/run/user/$(id -u ruya-shell)" timeout 30 "$shell" --load "$work/probe.qml" > "$work/probe.log" 2>&1
    # T-321: an ambient FLAC whose frames do not name their sample rate makes Qt 6.11 open its output at 0 Hz:
    # PlayingState and a moving position, but no sound and these two lines (the first several times a second).
    bad_fmt=$(grep -a -c "QAudioFormat not valid" "$work/probe.log"); bad_rate=$(grep -a -c "Requested output sample rate 0" "$work/probe.log")
    [ "$bad_fmt" = 0 ] && [ "$bad_rate" = 0 ] && ok "the probe's audio output opened with a valid format" \
        || bad "the probe's audio output never opened: $bad_fmt x 'QAudioFormat not valid', $bad_rate x 'Requested output sample rate 0'"
    last=$(grep -a "sounds-probe:" "$work/probe.log" | tail -1)
    echo "    $last"
    echo "$last" | grep -q "loaded=true" && ok "Qt Multimedia loaded ambient.flac (LoadedMedia)" || bad "the ambient file did not load under the image's Qt: $(grep -a -i 'error\|fail' "$work/probe.log" | head -2)"
    dur=$(echo "$last" | sed -n 's/.*duration=\([0-9]*\).*/\1/p')
    [ -n "$dur" ] && [ "$dur" -ge 74000 ] && [ "$dur" -le 77000 ] && ok "duration $dur ms (about 75 s)" || bad "duration '$dur' ms"
    echo "$last" | grep -q "playing=true" && ok "PlayingState reached" || bad "PlayingState not reached (is there an audio device? the VM needs -Audio or a null sink)"
    rm -rf "$work"
else
    echo "SKIP: /root/vm-sounds-probe.qml not copied, no playback probe"
fi

# T-321: the shell's own ambient bed really sounds. Its output stream must be `running` in PipeWire (not only
# present: the broken bed had a stream that stayed idle, ports in [init]) and the shell's journal must not have
# the two lines of an output that never opened. Needs a sound device: boot the VM with -Audio.
uid=$(id -u ruya-shell)
as_shell() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
# The running shell is the compositor unit's main process; its own lines only, so that a restart starts clean.
shell_pid() {
    local unit; unit=$(systemctl list-units 'ruya-compositor@*' --plain --no-legend 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$unit" ] && systemctl show -p MainPID --value "$unit"
}
journal_bad() {
    local pid; pid=$(shell_pid)
    if [ -n "$pid" ] && [ "$pid" != 0 ]; then journalctl -b "_PID=$pid" --no-pager 2>/dev/null; else journalctl -b "_UID=$uid" --no-pager 2>/dev/null; fi \
        | grep -a -c "QAudioFormat not valid\|Requested output sample rate 0"
}
n=$(journal_bad)
[ "$n" = 0 ] && ok "no 'QAudioFormat not valid' or 'sample rate 0' in the running shell's journal (pid $(shell_pid))" \
    || bad "the shell's journal has $n lines of an audio output that never opened ('QAudioFormat not valid', 'Requested output sample rate 0')"
# One line per PipeWire node: media.class, process binary, state, node.name, id. python3, not jq:
# the image has no jq (lint-vm-checks.ps1). A pw-dump that does not parse prints PWDUMP_PARSE_FAILED.
nodes() {
    as_shell pw-dump 2>/dev/null | python3 -I -c '
import json, sys
try:
    objs = json.load(sys.stdin)
except Exception:
    print("PWDUMP_PARSE_FAILED"); sys.exit(0)
for o in objs:
    if o.get("type") != "PipeWire:Interface:Node":
        continue
    info = o.get("info") or {}
    p = info.get("props") or {}
    print(p.get("media.class") or "-", p.get("application.process.binary") or "-",
          info.get("state") or "-", p.get("node.name") or "-", o.get("id"))
'
}
running_ids() { nodes | awk '$1 == "Stream/Output/Audio" && $2 == "ruya-shell" && $3 == "running" {print $5}' | sort; }
# A cue is a running shell stream too, for at most 1.5 s (the startup cue right after a restart): the bed is
# the stream that stays running for 3 s, sampled every half second.
shell_running() {
    local ids next i
    ids=$(running_ids)
    for i in 1 2 3 4 5 6; do
        [ -n "$ids" ] || return 1
        sleep 0.5
        next=$(running_ids)
        ids=$(comm -12 <(echo "$ids") <(echo "$next"))
    done
    [ -n "$ids" ]
}
if nodes | grep -q PWDUMP_PARSE_FAILED; then
    bad "pw-dump as ruya-shell gave no JSON (is PipeWire running?)"
elif ! nodes | awk '$1 == "Audio/Sink" && $4 != "auto_null"' | grep -q .; then
    echo "SKIP: no sound device, so no running stream to look for (boot the VM with -Audio)"
else
    # The bed plays on the picker and Home, and pauses under the screen saver (10 min idle by default): if it
    # is not running now, restart the shell, which starts it again, and look once more.
    # Each look takes 3 s while a stream runs, well under 1 s while none does.
    bed=no; tries=0
    until [ $bed = yes ] || [ $tries -ge 3 ]; do shell_running && bed=yes || sleep 1; tries=$((tries + 1)); done
    if [ $bed = no ]; then
        echo "    no running ambient stream yet (screen saver up?): restarting the shell"
        systemctl restart 'ruya-compositor@*'
        tries=0
        until [ $bed = yes ] || [ $tries -ge 20 ]; do shell_running && bed=yes || sleep 1; tries=$((tries + 1)); done
    fi
    if [ $bed = yes ]; then
        ok "the shell's ambient stream is running in PipeWire"
    else
        nodes | grep ruya-shell | sed 's/^/    /'
        bad "no ruya-shell output stream is running (is Settings -> Audio -> Ambient sound on, the Ambient level above 0?)"
    fi
    n=$(journal_bad)
    [ "$n" = 0 ] && ok "still no 'QAudioFormat not valid' after the stream started" || bad "the shell's journal now has $n lines of an output that never opened"
fi

[ -s /usr/share/licenses/ruyaos/LICENSE-Sounds.txt ] && ok "licence notice installed" || bad "no LICENSE-Sounds.txt"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
