#!/usr/bin/env bash
# Checks the Display part of the Devices service (T-198, org.ruyaos.Devices1.Display) inside a running VM. Copy and run as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-display-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-display-check.sh [check|switch]
# check (default; does not restart the shell, changes nothing that lasts):
#   - the compositor unit has the KMS config environment and the ExecStartPre guard, and ruya-devices has the --display-guard entry point;
#   - ListOutputs answers: the ids are connector names of /sys/class/drm, every output has modes with exactly one preferred and exactly one
#     current, the first listed mode is the first line of that connector's `modes` file, refresh_mhz is 0 or a plausible rate, the physical size
#     is 0 or fits the EDID bytes 21/22 (centimetres) or the first detailed timing;
#   - SetMode refuses an unknown output and an unknown mode, answers unchanged for the mode in use; Keep and Revert answer no-pending; SetUiScale
#     refuses 130 and accepts 125 (UiScale follows, a PropertiesChanged-based read) and the original is restored;
#   - the unit's start limit is StartLimitBurst=10 in 120 s (a deliberate restart must fit under it);
#   - a SetMode to another listed mode writes display-pending.toml and a kms.json that names the output the way QT names its screens
#     ("HDMI1" for the kernel's "HDMI-A-1", "Virtual1" for "Virtual-1": qkmsdevice.cpp nameForConnector) and also by the kernel's name, with
#     the mode as "WxH@Hz" (the golden shape of services/ruya-devices/tests/fixtures/kms-hdmi-1080p60.json), GetPending reports it with
#     starts 0, Revert removes both and the list is as before; Reset on a VM with nothing stored answers unchanged;
#   - the guard, run as ruya-shell on a scratch state directory: a marker with starts = 1 (the shell never confirmed) is dropped, the config
#     is removed, a display-fallback note is left and TakeFallbackNotice's twin (the file) is taken once; a marker with starts = 0 becomes 1;
#   - another user is refused.
# switch (restarts ruya-compositor@tty1 several times; run on a VM with the shell logged in): the real thing end to end.
#   1. SetMode to another mode, restart the compositor, GetPending says starts = 1 (the guard counted the start), the framebuffer size
#      (/sys/class/graphics/fb0/virtual_size) is that mode's (a FAIL when not: it means Qt ignored the KMS config, e.g. a screen name or mode string
#      it does not know), Keep stores it (display.toml),
#      the list marks it current, and it is still current after one more restart;
#   2. SetMode to a third mode, restart twice without Keep: the second start drops the choice (the preferred mode is back, no pending,
#      no kms.json, TakeFallbackNotice answers true once and then false);
#   3. the state files are removed and ruya-devices restarted, so the VM is as it was;
#   4. the recorded compositor starts (display-starts) stay under the unit's limit through all of it (about five starts), else FAIL.
# What QEMU's virtual GPU says is not what a TV says: the Dell run (two modes, one deliberately unsupported that reverts) is by hand, see
# the T-198 Outcome. Whether Qt's eglfs follows the KMS config is proven only by `switch` (the fb size).
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
ifc=org.ruyaos.Devices1.Display
uid="$(id -u ruya-shell)"
state=/var/lib/ruya-shell/.local/state/ruya-devices
# The name Qt's eglfs_kms gives the screen of a kernel connector (display.rs qt_output_name): HDMI-A-1 -> HDMI1, DP-1 -> DP1, Virtual-1 -> Virtual1.
qt_name() {
    local num="${1##*-}" kind="${1%-*}"
    case "$kind" in HDMI-A|HDMI-B) kind=HDMI ;; DVI-I|DVI-D|DVI-A) kind=DVI ;; SVIDEO) kind=TV ;; Component) kind=CTV ;; 9PinDIN) kind=DIN ;; esac
    echo "${kind}${num}"
}
# Compositor starts the guard has recorded within the last 120 s.
recent_starts() {
    python3 -I -c '
import sys, time
now = int(time.time())
try:
    times = [int(l) for l in open(sys.argv[1]).read().split()]
except OSError:
    times = []
print(sum(1 for t in times if t + 120 > now))' "$state/display-starts"
}
as_shell() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
warn() { echo "WARN: $*"; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is needed to read busctl's JSON"; exit 1; }

# call <method> [signature args...]: busctl's JSON answer; unwrap removes the {"type","data"} wrappers.
call() {
    busctl --system --json=short call "$svc" "$path" "$ifc" "$@" 2>&1
}
unwrap() {
    python3 -I -c '
import json, sys
def un(x):
    if isinstance(x, dict) and set(x) == {"type", "data"}:
        return un(x["data"])
    if isinstance(x, dict):
        return {k: un(v) for k, v in x.items()}
    if isinstance(x, list):
        return [un(v) for v in x]
    return x
print(json.dumps(un(json.load(sys.stdin))))'
}
# jget <json> <python expression over d>: evaluates the expression with d = the JSON's data list.
jget() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
d = d["data"] if isinstance(d, dict) and "data" in d else d
r = eval(sys.argv[1])
print(json.dumps(r) if isinstance(r, (list, dict)) else r)' "$2"
}
status() { call "$@" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"][0])' 2>/dev/null; }
outputs() { call ListOutputs | unwrap; }

unit_check() {
    echo "--- the compositor unit and the guard entry point"
    unit="$(systemctl cat 'ruya-compositor@tty1.service' 2>&1)"
    echo "$unit" | grep -q 'QT_QPA_EGLFS_KMS_CONFIG=/var/lib/ruya-shell/.local/state/ruya-devices/kms.json' \
        && ok "the unit points Qt at the KMS config in the service's state directory" || bad "no QT_QPA_EGLFS_KMS_CONFIG in the unit"
    echo "$unit" | grep -q 'ExecStartPre=-/usr/bin/ruya-devices --display-guard' && ok "the unit runs the guard before every start" || bad "no ExecStartPre guard"
    [ "$(systemctl show 'ruya-compositor@tty1.service' -p StartLimitBurst --value)" = 10 ] && ok "StartLimitBurst is 10: a change and its revert fit under it" || bad "StartLimitBurst: $(systemctl show 'ruya-compositor@tty1.service' -p StartLimitBurst --value)"
    [ "$(systemctl show 'ruya-compositor@tty1.service' -p StartLimitIntervalUSec --value)" = 2min ] && ok "StartLimitIntervalSec is 120" || bad "StartLimitIntervalUSec: $(systemctl show 'ruya-compositor@tty1.service' -p StartLimitIntervalUSec --value)"
    [ -d "$state" ] && ok "the state directory $state exists" || bad "no $state"
    [ "$(stat -c %U "$state" 2>/dev/null)" = ruya-shell ] && ok "it belongs to ruya-shell (the compositor and the service are the same user)" || bad "owner of $state: $(stat -c %U "$state" 2>&1)"
    as_shell /usr/bin/ruya-devices --display-list >/tmp/display-list.txt 2>&1 && ok "ruya-devices --display-list runs as ruya-shell" || bad "--display-list failed: $(cat /tmp/display-list.txt)"
    cat /tmp/display-list.txt
}

list_check() {
    echo "--- ListOutputs against /sys/class/drm"
    out="$(outputs)"
    echo "$out" | head -c 1500; echo
    n="$(jget "$out" 'len(d[0])')"
    [ "$n" -ge 1 ] 2>/dev/null && ok "ListOutputs lists $n output(s)" || { bad "ListOutputs listed nothing: $out"; return; }
    ids="$(jget "$out" '" ".join(o["id"] for o in d[0])')"
    for id in $ids; do
        ls -d /sys/class/drm/card*-"$id" >/dev/null 2>&1 && ok "output $id is a connector of /sys/class/drm" || bad "$id is not in /sys/class/drm"
        conn="$(ls -d /sys/class/drm/card*-"$id" | head -1)"
        [ "$(cat "$conn/status")" = connected ] && ok "$id is connected" || bad "$id is not connected"
    done
    first="$(jget "$out" 'd[0][0]["id"]')"
    conn="$(ls -d /sys/class/drm/card*-"$first" | head -1)"
    want="$(head -1 "$conn/modes")"
    got="$(jget "$out" '"%dx%d" % (d[0][0]["modes"][0]["width"], d[0][0]["modes"][0]["height"])')"
    [ "$got" = "$want" ] && ok "the first mode ($got) is the first line of $conn/modes" || bad "first mode $got, modes file says $want"
    for what in preferred current; do
        c="$(jget "$out" 'sum(1 for m in d[0][0]["modes"] if m["'$what'"])')"
        [ "$c" = 1 ] && ok "exactly one $what mode" || bad "$c $what modes"
    done
    bad_rate="$(jget "$out" 'sum(1 for m in d[0][0]["modes"] if m["refresh_mhz"] != 0 and not (20000 <= m["refresh_mhz"] <= 300000))')"
    [ "$bad_rate" = 0 ] && ok "every refresh rate is unknown (0) or between 20 and 300 Hz" || bad "$bad_rate implausible refresh rates"
    mm="$(jget "$out" 'str(d[0][0]["width_mm"]) + "x" + str(d[0][0]["height_mm"])')"
    echo "     physical size reported: $mm mm (0x0: the display did not say)"
    if [ -r "$conn/edid" ] && [ -s "$conn/edid" ]; then
        cm="$(od -An -tu1 -j21 -N2 "$conn/edid" | tr -s ' ')"
        echo "     EDID bytes 21/22 (cm):$cm"
    else
        ok "no EDID on $first (QEMU's virtual GPU has none): the size is 0x0 and the UI size falls back to 1"
        [ "$mm" = 0x0 ] && ok "no EDID, no physical size" || bad "a size without an EDID: $mm"
    fi
}

contract_check() {
    echo "--- SetMode, Keep, Revert, SetUiScale"
    out="$(outputs)"
    id="$(jget "$out" 'd[0][0]["id"]')"
    cur="$(jget "$out" '[m for m in d[0][0]["modes"] if m["current"]][0]')"
    cw="$(jget "$cur" 'd["width"]')"; ch="$(jget "$cur" 'd["height"]')"; cr="$(jget "$cur" 'd["refresh_mhz"]')"
    r="$(status SetMode suuu nowhere 800 600 60000)"
    [ "$r" = unknown-output ] && ok "SetMode on an unknown output: $r" || bad "SetMode unknown output: $r"
    r="$(status SetMode suuu "$id" 1 1 1)"; [ "$r" = unknown-mode ] && ok "SetMode on a mode the output does not offer: $r" || bad "SetMode unknown mode: $r"
    r="$(status SetMode suuu "$id" "$cw" "$ch" "$cr")"; [ "$r" = unchanged ] && ok "SetMode to the mode in use: $r" || bad "SetMode to the current mode: $r"
    r="$(status Keep)"; [ "$r" = no-pending ] && ok "Keep with nothing pending: $r" || bad "Keep: $r"
    r="$(status Revert)"; [ "$r" = no-pending ] && ok "Revert with nothing pending: $r" || bad "Revert: $r"
    [ ! -e "$state/display-pending.toml" ] && ok "no marker was written by the refusals" || bad "a marker exists after refusals"
    r="$(status SetUiScale u 130)"; [ "$r" = invalid ] && ok "SetUiScale 130: $r" || bad "SetUiScale 130: $r"
    before="$(busctl --system get-property "$svc" "$path" "$ifc" UiScale)"
    r="$(status SetUiScale u 125)"; [ "$r" = ok ] && ok "SetUiScale 125: $r" || bad "SetUiScale 125: $r"
    [ "$(busctl --system get-property "$svc" "$path" "$ifc" UiScale)" = "u 125" ] && ok "UiScale reads 125" || bad "UiScale did not follow"
    prev="${before#u }"; status SetUiScale u "$prev" >/dev/null

    r="$(status Reset)"; [ "$r" = unchanged ] && ok "Reset with nothing stored: $r" || bad "Reset on a fresh VM: $r"
    # A different listed mode, if there is one.
    other="$(jget "$out" '[m for m in d[0][0]["modes"] if not m["current"]][-1]' 2>/dev/null)"
    if [ -z "$other" ] || [ "$other" = "[]" ]; then warn "the output offers only one mode: no switch to try"; return; fi
    ow="$(jget "$other" 'd["width"]')"; oh="$(jget "$other" 'd["height"]')"; orr="$(jget "$other" 'd["refresh_mhz"]')"
    r="$(status SetMode suuu "$id" "$ow" "$oh" "$orr")"; [ "$r" = ok ] && ok "SetMode ${ow}x${oh}: $r" || { bad "SetMode ${ow}x${oh}: $r"; return; }
    [ -s "$state/display-pending.toml" ] && ok "the marker is written" || bad "no display-pending.toml"
    hz=$(( (orr + 500) / 1000 ))
    want="${ow}x${oh}@${hz}"; [ "$orr" = 0 ] && want="${ow}x${oh}"
    qn="$(qt_name "$id")"
    grep -q "\"name\": \"$qn\"" "$state/kms.json" && ok "kms.json names the screen $qn (Qt's name for $id)" || bad "kms.json has no entry named $qn: $(cat "$state/kms.json" 2>&1)"
    grep -q "\"mode\": \"$want\"" "$state/kms.json" && ok "kms.json has the mode $want" || bad "kms.json mode (want $want): $(cat "$state/kms.json" 2>&1)"
    p="$(call GetPending | unwrap)"
    [ "$(jget "$p" 'd[0]["starts"]')" = 0 ] && [ "$(jget "$p" 'd[0]["width"]')" = "$ow" ] && ok "GetPending reports it with starts 0" || bad "GetPending: $p"
    r="$(status SetMode suuu "$id" "$cw" "$ch" "$cr")"; [ "$r" = busy ] && ok "a second change meanwhile: $r" || bad "second SetMode: $r"
    r="$(status Revert)"; [ "$r" = ok ] && ok "Revert: $r" || bad "Revert: $r"
    [ ! -e "$state/display-pending.toml" ] && ok "the marker is gone" || bad "the marker is still there"
    [ ! -e "$state/kms.json" ] && ok "kms.json is gone (the preferred mode is Qt's default)" || warn "kms.json remains (a capped default, or a stored choice): $(cat "$state/kms.json")"
    p="$(call GetPending | unwrap)"; [ "$(jget "$p" 'len(d[0])')" = 0 ] && ok "GetPending is empty" || bad "GetPending after Revert: $p"
}

guard_check() {
    echo "--- the guard on a scratch state directory, as ruya-shell"
    scratch="$(mktemp -d /tmp/display-guard.XXXXXX)"; chown ruya-shell "$scratch"
    guard() { as_shell /usr/bin/ruya-devices --display-guard --state-dir "$scratch" 2>&1; }
    cat >"$scratch/display-pending.toml" <<'EOF'
starts = 0

[candidate]
output = "Virtual-1"
width = 800
height = 600
refresh_mhz = 60000
EOF
    chown ruya-shell "$scratch/display-pending.toml"
    guard | grep -q FirstStart && ok "a marker with starts = 0: the first start is counted" || bad "no FirstStart"
    grep -q '^starts = 1' "$scratch/display-pending.toml" && ok "the marker now says starts = 1" || bad "marker: $(cat "$scratch/display-pending.toml")"
    echo '{}' >"$scratch/kms.json"; chown ruya-shell "$scratch/kms.json"
    guard | grep -q FellBack && ok "the second start with the marker drops the choice" || bad "no FellBack"
    [ ! -e "$scratch/display-pending.toml" ] && [ ! -e "$scratch/kms.json" ] && ok "marker and config are removed" || bad "files left: $(ls "$scratch")"
    [ -e "$scratch/display-fallback" ] && ok "the display-fallback note is left for the shell" || bad "no display-fallback"
    guard | grep -q Quiet && ok "a start with nothing pending is quiet" || bad "not quiet"
    rm -rf "$scratch"
    echo "--- another user"
    if runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListOutputs >/dev/null 2>&1; then bad "nobody may call Display"; else ok "nobody is refused"; fi
}

wait_pending() { # wait until GetPending answers (the shell and the user unit are back), at most 90 s
    local n=0
    until [ "$(call GetPending 2>/dev/null | unwrap 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)[0]))' 2>/dev/null)" != "" ] || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    sleep 3
}

switch_check() {
    echo "--- the switch end to end (restarts the compositor)"
    out="$(outputs)"
    id="$(jget "$out" 'd[0][0]["id"]')"
    modes="$(jget "$out" '[m for m in d[0][0]["modes"] if not m["current"]]')"
    n="$(jget "$modes" 'len(d)')"
    [ "$(recent_starts)" -lt 3 ] || { bad "the compositor started $(recent_starts) times in the last two minutes: wait and run again (the run needs about five starts of ten, and the service refuses a change from eight)"; return; }
    [ "$n" -ge 2 ] || { warn "need two modes besides the current one for the whole run; the output has $n"; return; }
    w1="$(jget "$modes" 'd[0]["width"]')"; h1="$(jget "$modes" 'd[0]["height"]')"; r1="$(jget "$modes" 'd[0]["refresh_mhz"]')"
    w2="$(jget "$modes" 'd[1]["width"]')"; h2="$(jget "$modes" 'd[1]["height"]')"; r2="$(jget "$modes" 'd[1]["refresh_mhz"]')"

    echo "1. a change that is kept"
    [ "$(status SetMode suuu "$id" "$w1" "$h1" "$r1")" = ok ] && ok "SetMode ${w1}x${h1}" || { bad "SetMode failed"; return; }
    systemctl restart ruya-compositor@tty1.service; wait_pending
    p="$(call GetPending | unwrap)"
    [ "$(jget "$p" 'd[0]["starts"]')" = 1 ] && ok "after the restart GetPending says starts = 1 (the guard counted the start)" || bad "GetPending: $p"
    fb="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
    for _ in $(seq 1 30); do [ "$fb" = "$w1,$h1" ] && break; sleep 1; fb="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"; done
    [ "$fb" = "$w1,$h1" ] && ok "the framebuffer is $fb: Qt took the KMS config" || bad "framebuffer $fb, wanted $w1,$h1: Qt ignored the KMS config (screen name or mode string); see: journalctl -u ruya-compositor@tty1 | grep -i kms; cat $state/kms.json"
    [ "$(status Keep)" = ok ] && ok "Keep" || bad "Keep"
    grep -q "width = $w1" "$state/display.toml" && ok "display.toml stores the choice" || bad "display.toml: $(cat "$state/display.toml" 2>&1)"
    systemctl restart ruya-compositor@tty1.service; wait_pending
    out="$(outputs)"
    [ "$(jget "$out" '[m for m in d[0][0]["modes"] if m["current"]][0]["width"]')" = "$w1" ] && ok "after one more restart the kept mode is still current" || bad "not current after a restart"

    echo "2. a change nobody confirms"
    [ "$(status SetMode suuu "$id" "$w2" "$h2" "$r2")" = ok ] && ok "SetMode ${w2}x${h2}" || { bad "SetMode failed"; return; }
    systemctl restart ruya-compositor@tty1.service; wait_pending
    systemctl restart ruya-compositor@tty1.service; wait_pending
    p="$(call GetPending | unwrap)"
    [ "$(jget "$p" 'len(d[0])')" = 0 ] && ok "the second start dropped the unconfirmed change" || bad "still pending: $p"
    [ ! -e "$state/kms.json" ] && ok "no kms.json: the preferred mode is back" || warn "kms.json: $(cat "$state/kms.json")"
    [ "$(call TakeFallbackNotice | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"][0])')" = True ] && ok "TakeFallbackNotice answers true once" || bad "no fallback notice"
    [ "$(call TakeFallbackNotice | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"][0])')" = False ] && ok "... and then false" || bad "the notice came twice"

    echo "3. cleaning up"
    rm -f "$state/display.toml" "$state/display-pending.toml" "$state/kms.json" "$state/display-fallback"
    as_shell systemctl --user restart ruya-devices.service
    systemctl restart ruya-compositor@tty1.service
    ok "state files removed, the service and the compositor restarted"
    echo "4. the start limit"
    sleep 5
    ns="$(recent_starts)"
    [ "$ns" -lt 10 ] && ok "$ns compositor starts in the window, under the unit's limit of 10" || bad "$ns compositor starts in the window: the limit of 10 was reached"
    [ "$(systemctl is-active 'ruya-compositor@tty1.service')" = active ] && ok "the compositor unit is active (not start-limit-hit)" || bad "compositor unit: $(systemctl is-active 'ruya-compositor@tty1.service')"
}

case "${1:-check}" in
check)
    unit_check
    list_check
    contract_check
    guard_check
    ;;
switch)
    switch_check
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
