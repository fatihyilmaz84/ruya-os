#!/usr/bin/env bash
# Checks the power-saving parts of T-202 inside a running VM, as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-power-saving-check.sh scripts/vm-inject-key.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-power-saving-check.sh [service|audio|timeline|all]
#
#   service   Devices1.Bluetooth.ReportIdle exists and answers "ok" (also with Bluetooth off, as in the VM)
#   audio     Devices1.Audio.Playing exists and reads false on a quiet console. T-293: it then plays a
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

audio_check() {
    echo "--- Audio.Playing (T-202, T-293)"
    out="$(playing)"
    [ "$out" = "b false" ] && ok "Playing is false on a quiet console" || bad "Playing read: $out"
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
    pkill -x pw-cat
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

case "$part" in
    service) service_check ;;
    audio) audio_check ;;
    timeline) timeline_check ;;
    all) service_check; audio_check; timeline_check ;;
    *) echo "usage: $0 [service|audio|timeline|all]"; exit 2 ;;
esac
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
