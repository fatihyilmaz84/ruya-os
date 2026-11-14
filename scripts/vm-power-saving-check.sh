#!/usr/bin/env bash
# Checks the power-saving parts of T-202 inside a running VM, as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-power-saving-check.sh scripts/vm-inject-key.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-power-saving-check.sh [service|audio|timeline|inhibit|all]
#
#   service   Devices1.Bluetooth.ReportIdle exists and answers "ok" (also with Bluetooth off, as in the VM)
#   audio     Devices1.Audio.Playing exists and reads false on a quiet console, with the shell's ambient bed
#             playing (T-313: the shell's own streams do not count). T-293: it then plays a
#             silent stream with pw-cat as ruya-shell (Playing must become true: a running output
#             stream), stops the player with SIGSTOP (a stream that stopped feeding the graph; where
#             PipeWire then reports it as not running Playing must become false, otherwise the part
#             prints "UNVERIFIED:" because SIGSTOP is not a real cork: try a player's pause on the Dell),
#             and checks that Playing is false again once the player is gone.
#   timeline  shortens every power-saving time by 60 (RUYA_IDLE_DIVISOR=60: 10 minutes -> 10 s) with a
#             drop-in on the compositor unit, restarts the shell, waits without any input and reads the
#             journal: screen saver at ~10 s, display off at ~30 s (and whether DPMS worked: "dpms" or
#             "black frame only"), then removes the drop-in and restarts the shell again. Sleep needs
#             /usr/share/ruyaos/suspend-verified (T-166) and is not exercised here.
#             T-296: it then wakes the display itself with a uinput key (scripts/vm-inject-key.py must be
#             copied next to this script) and checks that the display came back AND that frames are produced
#             again: "display on" in the journal, a CRTC active in /sys/kernel/debug/dri/*/state, dpms On,
#             no page flip / commit error in the journal, and at least one delivered vblank event (a page
#             flip, counted through the drm_vblank_event_delivered tracepoint in tracefs) in the 4 s after
#             the key. Without tracefs or debugfs the part prints "UNVERIFIED:" for what it could not read.
#             That the page below did not move is not checked here (tst_power_saving.qml does).
#   inhibit   RUY-561: an idle inhibitor counts only while its app is the front app. Needs a profile signed
#             in (drive it from the host) and scripts/vm-idle-inhibit-client.py, vm-key-client.qml next to
#             this script. With RUYA_IDLE_DIVISOR=60 (the shell is restarted with the drop-in if it does not
#             have it: sign in again when it asks) it starts the inhibiting client (journal: "idle inhibit
#             +wayland:N" while it is in front), then the key client, whose window takes the front (the
#             inhibiting app is behind it: "idle inhibit -wayland:N" must follow), then "display off"
#             within 60 s although the inhibiting client still runs; when the key client ends, the
#             inhibiting app is in front again and "+wayland:N" must come back; then (with vm-inject-key.py
#             next to this script) Guide opens the Hub: "-wayland:N", and Guide again: "+wayland:N".
# Hardware (the Dell, not this script): the DualSense disconnects after the Controllers-turn-off time and
# reconnects on a button press; a TV's re-sync time after display off is recorded by hand.
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
uid="$(id -u ruya-shell)"
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
part="${1:-all}"

service_check() {
    echo "--- ReportIdle (T-202)"
    out="$(busctl --system call "$svc" "$path" org.ruyaos.Devices1.Bluetooth ReportIdle uub 0 0 false 2>&1)"
    [ "$out" = 's "ok"' ] && ok "ReportIdle(0, 0, false) answers ok" || bad "ReportIdle answered: $out"
    out="$(busctl --system call "$svc" "$path" org.ruyaos.Devices1.Bluetooth ReportIdle uub 4000 900 true 2>&1)"
    [ "$out" = 's "ok"' ] && ok "ReportIdle with hold answers ok" || bad "ReportIdle with hold answered: $out"
    out="$(runuser -u nobody -- busctl --system call "$svc" "$path" org.ruyaos.Devices1.Bluetooth ReportIdle uub 0 0 false 2>&1)"
    case "$out" in 's "ok"'*) bad "another user was allowed to call ReportIdle" ;; *) ok "another user is refused" ;; esac
}

playing() { busctl --system get-property "$svc" "$path" org.ruyaos.Devices1.Audio Playing 2>&1; }

# Waits up to $2 s for Playing to read "$1".
wait_playing() {
    for _ in $(seq 1 "$(( $2 * 5 ))"); do
        [ "$(playing)" = "b $1" ] && return 0
        sleep 0.2
    done
    return 1
}

# T-313: makes sure the shell's ambient bed is on (the Ambient sound switch, `sound/ambient`, is on by
# default; a conf that says false is put right and the shell restarted), then waits until the shell has a
# running output stream, which is what used to make Playing true at Home.
ambient_on() {
    home="$(getent passwd ruya-shell | cut -d: -f6)"
    conf="$home/.config/ruyaos/shell.conf"
    if [ -f "$conf" ] && grep -q '^ambient=false' "$conf"; then
        sed -i 's/^ambient=false/ambient=true/' "$conf"
        chown ruya-shell: "$conf"
        systemctl restart ruya-compositor@tty1
        sleep 15
    fi
    for _ in $(seq 1 30); do
        runuser -u ruya-shell -- env "XDG_RUNTIME_DIR=/run/user/$uid" pw-dump 2>/dev/null | tr -d ' \n' | grep -q '"application.process.binary":"ruya-shell"' && return 0
        sleep 1
    done
    return 1
}

audio_check() {
    echo "--- Audio.Playing (T-202, T-293, T-313)"
    if ambient_on; then
        echo "the shell's ambient bed is a stream in the graph"
    else
        echo "UNVERIFIED: no ruya-shell stream in pw-dump (no sound theme or no audio device): the first assertion did not run with the bed playing"
    fi
    out="$(playing)"
    [ "$out" = "b false" ] && ok "Playing is false on a quiet console, with the ambient bed on" || bad "Playing read: $out"
    if ! command -v pw-cat >/dev/null 2>&1; then
        echo "UNVERIFIED: pw-cat is not installed: no stream was played"
        return
    fi
    # PipeWire runs in the ruya-shell user's session.
    runuser -u ruya-shell -- env "XDG_RUNTIME_DIR=/run/user/$uid" pw-cat -p --raw --rate 48000 --channels 2 --format s16 /dev/zero >/dev/null 2>&1 &
    player=$!
    if wait_playing true 8; then
        ok "a running output stream makes Playing true"
    else
        bad "Playing stayed $(playing) with a stream running"
    fi
    pkill -STOP -x pw-cat
    if wait_playing false 8; then
        ok "a stream that stopped running does not hold Playing"
    else
        echo "UNVERIFIED: Playing stays true after SIGSTOP of pw-cat (PipeWire keeps the node running); a real pause is checked on the Dell"
    fi
    pkill -CONT -x pw-cat
    pkill -KILL -x pw-cat
    kill -KILL "$player" 2>/dev/null
    wait "$player" 2>/dev/null
    wait_playing false 8 && ok "Playing is false again once the stream is gone" || bad "Playing stayed true after the stream ended: $(playing)"
}

timeline_check() {
    echo "--- timeline with RUYA_IDLE_DIVISOR=60 (saver ~10 s, display off ~30 s)"
    unit="ruya-compositor@tty1"
    dropin="/etc/systemd/system/$unit.service.d"
    mkdir -p "$dropin"
    printf '[Service]\nEnvironment=RUYA_IDLE_DIVISOR=60\n' > "$dropin/zz-idle-divisor.conf"
    systemctl daemon-reload
    systemctl restart "$unit"
    start="$(date +%s)"
    # Wait for the shell to log its first line, then watch the journal for the display.
    for _ in $(seq 1 60); do
        journalctl -b -q -o cat -u "$unit" --since "@$start" | grep -q 'ruya-compositor: up' && break
        sleep 1
    done
    echo "shell is up; waiting 45 s without input"
    sleep 45
    log="$(journalctl -b -q -o cat --since "@$start" | grep -E 'ruya-shell: (display|idle inhibit)' || true)"
    echo "$log"
    echo "$log" | grep -q 'display off' && ok "the display was switched off" || bad "no 'display off' line after 45 s"
    echo "$log" | grep -q 'display off (dpms)' && ok "DPMS was used (eglfs_kms)" || echo "NOTE: no DPMS ('black frame only' or none): the picture goes black, the monitor stays on"
    if echo "$log" | grep -q 'display off'; then wake_check "$start"; else bad "no wake check: the display never went off"; fi
    rm -f "$dropin/zz-idle-divisor.conf"
    rmdir "$dropin" 2>/dev/null
    systemctl daemon-reload
    systemctl restart "$unit"
    echo "(drop-in removed, shell restarted)"
}

# T-296: tracefs, where the kernel counts the page flips (completed vblank events) the compositor gets.
trace_dir() {
    local d
    for d in /sys/kernel/tracing /sys/kernel/debug/tracing; do
        [ -w "$d/trace" ] && [ -e "$d/events/drm/drm_vblank_event_delivered/enable" ] && { echo "$d"; return 0; }
    done
    return 1
}
# frames_since_reset <tracedir>: the number of delivered vblank events (page flips of any CRTC) since frames_reset.
frames_reset() { : > "$1/trace"; }
frames_since_reset() { grep -c 'drm_vblank_event_delivered' "$1/trace" || true; }

# The display came back on after "display off": frames must be produced again, not only the journal line.
# DPMS off/on with atomic modesetting can leave the CRTC inactive or make every page flip fail, with the
# shell logging "display on" and the screen staying black. Needs vm-inject-key.py next to this script
# (a uinput keyboard in the guest: the same input path as a controller, no host step).
wake_check() {
    local since="$1" td off_frames on_frames wake errs
    echo "--- wake: a key brings the display back, and frames are produced again"
    if [ ! -f /root/vm-inject-key.py ]; then
        bad "/root/vm-inject-key.py is missing: scp scripts/vm-inject-key.py next to this script (the wake cannot be tested)"
        return
    fi
    if td="$(trace_dir)"; then
        echo 1 > "$td/events/drm/drm_vblank_event_delivered/enable"
        frames_reset "$td"
        sleep 3
        off_frames="$(frames_since_reset "$td")"
        echo "page flips in 3 s while the display is off: $off_frames (a dark screen runs no animation)"
    fi
    echo "dpms while off: $(cat /sys/class/drm/card*-*/dpms 2>/dev/null | tr '\n' ' ')(informational: the atomic path may not touch the legacy property)"
    [ -n "${td:-}" ] && frames_reset "$td"
    wake="$(date +%s)"
    python3 /root/vm-inject-key.py home || bad "the key could not be injected (is /dev/uinput there?)"
    sleep 4
    log="$(journalctl -b -q -o cat --since "@$wake" | grep -E 'ruya-shell: display' || true)"
    echo "$log"
    echo "$log" | grep -q 'display on' && ok "the first key switched the display on" || bad "no 'display on' line after the key"
    if grep -qs '^[[:space:]]*active=1' /sys/kernel/debug/dri/*/state; then
        ok "a CRTC is active again (/sys/kernel/debug/dri/*/state)"
    elif ls /sys/kernel/debug/dri/*/state >/dev/null 2>&1; then
        bad "no CRTC is active after the display came back on"
    else
        echo "UNVERIFIED: no /sys/kernel/debug/dri/*/state (debugfs not mounted): the CRTC state was not read"
    fi
    for c in /sys/class/drm/card*-*; do
        [ "$(cat "$c/status" 2>/dev/null)" = connected ] && [ -r "$c/dpms" ] || continue
        [ "$(cat "$c/dpms")" = On ] && ok "$(basename "$c"): dpms is On" || bad "$(basename "$c"): dpms is $(cat "$c/dpms") after the wake"
    done
    errs="$(journalctl -b -q -o cat --since "@$since" | grep -iE 'pageflip|page flip|atomic commit|drmModeAtomicCommit|failed to (flip|commit)' | head -3 || true)"
    [ -z "$errs" ] && ok "no page flip or commit error in the journal" || bad "page flip or commit errors in the journal: $errs"
    if [ -n "${td:-}" ]; then
        on_frames="$(frames_since_reset "$td")"
        echo 0 > "$td/events/drm/drm_vblank_event_delivered/enable"
        echo "page flips in the 4 s after the wake key: $on_frames"
        [ "$on_frames" -ge 1 ] && ok "frames are produced again after the wake ($on_frames page flips in 4 s)" || bad "no page flip in 4 s after the wake: the display is on but nothing is drawn"
    else
        echo "UNVERIFIED: no tracefs with drm_vblank_event_delivered (is the kernel built with it, is tracefs mounted?): frames were not counted"
    fi
}

# RUY-561: the journal lines for the reason "wayland:N" since $1 (epoch seconds).
inhibit_log() { journalctl -b -q -o cat --since "@$1" | grep -E 'ruya-shell: idle inhibit [+-]wayland:|ruya-shell: display off' || true; }

# Waits up to $3 s for the pattern $2 in the journal since $1; prints the matching line.
wait_log() {
    local since="$1" pat="$2" t="$3"
    for _ in $(seq 1 "$t"); do
        journalctl -b -q -o cat --since "@$since" | grep -E "$pat" | head -n 1 | grep . && return 0
        sleep 1
    done
    return 1
}

inhibit_check() {
    echo "--- an idle inhibitor counts only while its app is in front (RUYA_IDLE_DIVISOR=60)"
    here="$(cd "$(dirname "$0")" && pwd)"
    for f in vm-idle-inhibit-client.py vm-key-client.qml; do
        [ -f "$here/$f" ] || { bad "$f must be next to this script"; return; }
    done
    install -m 0644 "$here/vm-idle-inhibit-client.py" /var/tmp/vm-idle-inhibit-client.py
    install -m 0644 "$here/vm-key-client.qml" /var/tmp/vm-key-client.qml
    unit="ruya-compositor@tty1"
    dropin="/etc/systemd/system/$unit.service.d"
    added=0
    shellpid="$(pgrep -u ruya-shell -x ruya-shell | head -n 1)"
    if ! tr '\0' '\n' < "/proc/$shellpid/environ" 2>/dev/null | grep -qx 'RUYA_IDLE_DIVISOR=60'; then
        mkdir -p "$dropin"
        printf '[Service]\nEnvironment=RUYA_IDLE_DIVISOR=60\n' > "$dropin/zz-idle-divisor.conf"
        systemctl daemon-reload
        systemctl restart "$unit"
        added=1
        echo "shell restarted with the divisor: sign in a profile now (waiting up to 180 s)"
    fi
    active=""
    for _ in $(seq 1 180); do
        active="$(busctl --system get-property org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ActiveProfile 2>/dev/null | cut -d'"' -f2)"
        [ -n "$active" ] && break
        sleep 1
    done
    [ -n "$active" ] || { bad "no profile signed in"; return; }
    sleep 3
    run() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=ruya-0 "$@"; }
    start="$(date +%s)"
    run python3 /var/tmp/vm-idle-inhibit-client.py >/var/tmp/vm-idle-inhibit-client.log 2>&1 &
    line="$(wait_log "$start" 'idle inhibit \+wayland:[0-9]+' 20)" && ok "the inhibiting app in front holds: $line" || bad "no '+wayland:N' after the inhibiting client started (see /var/tmp/vm-idle-inhibit-client.log)"
    n="$(echo "$line" | sed -n 's/.*wayland:\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [ -n "$n" ]; then
        behind="$(date +%s)"
        run env QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software /usr/bin/ruya-shell --load /var/tmp/vm-key-client.qml >/dev/null 2>&1 &
        wait_log "$behind" "idle inhibit -wayland:$n" 20 >/dev/null && ok "another window in front: -wayland:$n" || bad "no '-wayland:$n' after another window took the front"
        wait_log "$behind" 'display off' 75 >/dev/null && ok "display off although the inhibiting client still runs" || bad "no 'display off' within 75 s with the inhibitor behind"
        back="$(date +%s)"
        pkill -f '[v]m-key-client.qml'
        wait_log "$back" "idle inhibit \+wayland:$n" 20 >/dev/null && ok "in front again: +wayland:$n" || bad "no '+wayland:$n' after the other window ended"
        # The Hub over the app (needs vm-inject-key.py next to this script): Guide releases, Guide again takes it.
        if [ -f "$here/vm-inject-key.py" ]; then
            hub="$(date +%s)"
            python3 "$here/vm-inject-key.py" guide >/dev/null 2>&1
            wait_log "$hub" "idle inhibit -wayland:$n" 20 >/dev/null && ok "the Hub open over the app: -wayland:$n" || bad "no '-wayland:$n' with the Hub open"
            hub2="$(date +%s)"
            python3 "$here/vm-inject-key.py" guide >/dev/null 2>&1
            wait_log "$hub2" "idle inhibit \+wayland:$n" 20 >/dev/null && ok "the Hub closed: +wayland:$n" || bad "no '+wayland:$n' after the Hub closed"
        else
            echo "UNVERIFIED: vm-inject-key.py is not next to this script: the Hub step was not run"
        fi
    fi
    pkill -f '[v]m-key-client.qml'
    pkill -f '[v]m-idle-inhibit-client.py'
    echo "$(inhibit_log "$start")"
    if [ "$added" = 1 ]; then
        rm -f "$dropin/zz-idle-divisor.conf"
        rmdir "$dropin" 2>/dev/null
        systemctl daemon-reload
        systemctl restart "$unit"
        echo "(drop-in removed, shell restarted)"
    fi
}

case "$part" in
    service) service_check ;;
    audio) audio_check ;;
    timeline) timeline_check ;;
    inhibit) inhibit_check ;;
    all) service_check; audio_check; timeline_check ;;
    *) echo "usage: $0 [service|audio|timeline|inhibit|all]"; exit 2 ;;
esac
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
