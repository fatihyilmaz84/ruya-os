#!/usr/bin/env bash
# Checks the power-saving parts of T-202 inside a running VM, as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-power-saving-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-power-saving-check.sh [service|audio|timeline|all]
#
#   service   Devices1.Bluetooth.ReportIdle exists and answers "ok" (also with Bluetooth off, as in the VM)
#   audio     Devices1.Audio.Playing exists and reads false on a quiet console
#   timeline  shortens every power-saving time by 60 (RUYA_IDLE_DIVISOR=60: 10 minutes -> 10 s) with a
#             drop-in on the compositor unit, restarts the shell, waits without any input and reads the
#             journal: screen saver at ~10 s, display off at ~30 s (and whether DPMS worked: "dpms" or
#             "black frame only"), then removes the drop-in and restarts the shell again. Sleep needs
#             /usr/share/ruyaos/suspend-verified (T-166) and is not exercised here.
#             The wake is a host-side step: send a key afterwards (scripts/vm-keys.ps1 / vm-inject-key.py)
#             and expect "display on" in the journal; the screen must come back on the first key and the
#             page below must not have moved.
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

audio_check() {
    echo "--- Audio.Playing (T-202)"
    out="$(busctl --system get-property "$svc" "$path" org.ruyaos.Devices1.Audio Playing 2>&1)"
    [ "$out" = "b false" ] && ok "Playing is false on a quiet console" || bad "Playing read: $out"
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
    rm -f "$dropin/zz-idle-divisor.conf"
    rmdir "$dropin" 2>/dev/null
    systemctl daemon-reload
    systemctl restart "$unit"
    echo "(drop-in removed, shell restarted)"
    echo "Now send a key from the host and expect 'ruya-shell: display on' (journalctl -b -o cat | grep 'display')."
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
