#!/usr/bin/env bash
# Checks the boot experience (T-269) inside a booted VM, as root. Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-boot-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-boot-check.sh
# What it cannot see is the screen: that is scripts/vm-boot-shots.ps1 (shots during boot) and
# dev-setup.md, "Boot experience". It prints the splash-to-shell timeline of this boot.
#   bash /root/vm-boot-check.sh watchdog   the shell's systemd watchdog (RUY-483): WatchdogSec=30s,
#                                          no trip and no automatic restart since boot, and a SIGSTOPped
#                                          shell restarted within 45 s. It restarts the shell (running
#                                          games end): run it once per boot, before checks that end the
#                                          shell themselves (a mode change counts in NRestarts).
set -u
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# --- watchdog mode (RUY-483) ---
# Host tests (test-vm-checks.sh) put fakes in front of PATH and WATCHDOG_KILL in place of kill.
watchdog_check() {
    local unit='ruya-compositor@tty1.service' kill_cmd="${WATCHDOG_KILL:-kill}" limit=45
    local start_line='ruya-shell: systemd watchdog every 15000 ms'
    show() { systemctl show -p "$1" --value "$unit"; }
    local wd na ta pid0 n0 t0 pid1 n1 waited
    wd="$(show WatchdogUSec)"; na="$(show NotifyAccess)"; ta="$(show TimeoutAbortUSec)"
    [ "$wd" = 30s ] && ok "$unit has WatchdogSec=30s" || bad "$unit: WatchdogUSec is '$wd', not 30s"
    [ "$na" = main ] && ok "$unit has NotifyAccess=main" || bad "$unit: NotifyAccess is '$na', not main"
    [ "$ta" = 10s ] && ok "$unit has TimeoutAbortSec=10s" || bad "$unit: TimeoutAbortUSec is '$ta', not 10s (a stopped shell waits for the 90 s stop timeout)"
    if ! systemctl is-active "$unit" >/dev/null; then
        bad "$unit is not active"; return
    fi
    pid0="$(show MainPID)"; n0="$(show NRestarts)"
    [ "$n0" = 0 ] && ok "no automatic restart of the shell since boot (NRestarts 0)" || bad "NRestarts is $n0 before the test (a crash, a watchdog trip, or a check that ended the shell ran before this one)"
    if journalctl -b -q --no-pager -u "$unit" | grep -q 'Watchdog timeout'; then
        bad "the watchdog already tripped in this boot: $(journalctl -b -q --no-pager -u "$unit" | grep 'Watchdog timeout' | head -1)"
    else
        ok "no watchdog timeout in this boot so far"
    fi
    journalctl -b -q --no-pager _PID="$pid0" | grep -qF "$start_line" && ok "the shell (pid $pid0) logged '$start_line'" || bad "no '$start_line' from the shell (pid $pid0)"

    # A stopped process cannot take systemd's SIGABRT: the restart is the SIGKILL after TimeoutAbortSec
    # (no coredump; a real wedge leaves one). The last ping is at most 15 s old when the shell stops, so
    # the trip comes 15-30 s after the stop, the SIGKILL 10 s later and the new start 1 s after that.
    # If the shell is not restarted, the EXIT trap lets it run again (it then takes the pending SIGABRT).
    t0="$(date +%s)"
    trap "'$kill_cmd' -CONT $pid0 2>/dev/null" EXIT # expanded now: the function's locals are gone at exit
    "$kill_cmd" -STOP "$pid0" || { bad "kill -STOP $pid0 failed"; return; }
    echo "    stopped the shell (pid $pid0); waiting up to $limit s for systemd to restart it"
    waited=0; pid1="$pid0"
    while [ "$waited" -lt "$limit" ]; do
        sleep 1; waited=$((waited + 1))
        pid1="$(show MainPID)"
        if [ -n "$pid1" ] && [ "$pid1" != 0 ] && [ "$pid1" != "$pid0" ] && systemctl is-active "$unit" >/dev/null; then
            break
        fi
    done
    if [ "$pid1" = "$pid0" ] || [ -z "$pid1" ] || [ "$pid1" = 0 ]; then
        bad "the stopped shell was not restarted within $limit s (MainPID '$pid1')"; return
    fi
    trap - EXIT
    ok "the stopped shell was restarted after about $waited s (new MainPID $pid1)"
    n1="$(show NRestarts)"
    [ "$n1" = "$((n0 + 1))" ] && ok "NRestarts went from $n0 to $n1" || bad "NRestarts went from $n0 to $n1, not $((n0 + 1))"
    if journalctl -b -q --no-pager -u "$unit" --since "@$t0" | grep -q 'Watchdog timeout'; then
        ok "systemd logged the watchdog timeout: $(journalctl -b -q --no-pager -u "$unit" --since "@$t0" | grep 'Watchdog timeout' | head -1)"
    else
        bad "no 'Watchdog timeout' line from systemd since the stop (restarted for another reason?)"
    fi
    # The new shell loads its QML first (seconds on the VM's software renderer).
    waited=0
    until journalctl -b -q --no-pager _PID="$pid1" | grep -qF "$start_line"; do
        [ "$waited" -ge 30 ] && break
        sleep 1; waited=$((waited + 1))
    done
    journalctl -b -q --no-pager _PID="$pid1" | grep -qF "$start_line" && ok "the new shell (pid $pid1) logged '$start_line' again" || bad "the new shell (pid $pid1) did not log '$start_line' within 30 s"
    echo "note: the stopped shell left no coredump (SIGKILL); after a real wedge, 'coredumpctl info ruya-shell' has one"
}
if [ "${1:-}" = watchdog ]; then
    watchdog_check
    [ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
    exit $fail
fi

cmd="$(cat /proc/cmdline)"
for a in quiet splash loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.plymouth=1 plymouth.ignore-serial-consoles; do
    case " $cmd " in *" $a "*) ok "kernel argument $a" ;; *) bad "kernel argument $a missing: $cmd" ;; esac
done
case " $cmd " in *" loglevel=3 "*) bad "old loglevel=3 still on the command line (kargs.d change not applied?)" ;; esac

[ "$(plymouth-set-default-theme)" = ruyaos ] && ok "default Plymouth theme is ruyaos" || bad "default theme: $(plymouth-set-default-theme)"
journalctl -b -q -u plymouth-start.service --no-pager | grep -q . && ok "plymouth-start ran in this boot" || ok "plymouth-start has no journal lines (it ran in the initramfs)"

# GRUB: a new disk has the policy in grub.cfg, an older one gets custom.cfg from ruya-grub-menu.service.
if grep -q 'ruya_menu_policy=1' /boot/grub2/grub.cfg 2>/dev/null; then
    ok "grub.cfg carries the menu policy (disk installed from this image)"
elif grep -qx '# ruyaos-managed: grub-menu-custom.cfg' /boot/grub2/custom.cfg 2>/dev/null; then
    ok "custom.cfg carries the menu policy (older disk, written by ruya-grub-menu.service)"
else
    bad "no menu policy in /boot/grub2/grub.cfg or custom.cfg"
fi
[ "$(systemctl show -p Result --value ruya-grub-menu.service)" = success ] && ok "ruya-grub-menu.service succeeded" || bad "ruya-grub-menu.service: $(systemctl show -p Result --value ruya-grub-menu.service)"
cmp -s /usr/lib/ruyaos/grub-menu-custom.cfg /boot/grub2/custom.cfg && ok "custom.cfg equals /usr/lib/ruyaos/grub-menu-custom.cfg" || echo "note: custom.cfg differs or is absent"
echo "grubenv: $(grub2-editenv list | tr '\n' ' ')"
# T-296: ruya-grub-menu.service remounts /boot read-write and back to read-only inside its own private mount
# namespace (PrivateMounts / ProtectSystem in the unit), so the remount itself cannot be seen from here, not even
# while the unit runs. What this can and does check is the result in the host's namespace afterwards: /boot is
# its own mount (not just a directory of the read-only root, which would be "ro" for the wrong reason), it is
# mounted ro, and a write really fails with EROFS. That the service restores the flag in its namespace is only
# implied by the host view staying read-only.
boot_target="$(findmnt -n --target /boot -o TARGET)"
if [ "$boot_target" = /boot ]; then ok "/boot is its own mount"; else bad "/boot is not a mount of its own (findmnt says $boot_target)"; fi
findmnt -n --target /boot -o OPTIONS | tr ',' '\n' | grep -qx ro && ok "/boot is mounted ro in the host namespace" || bad "/boot is not mounted ro in the host namespace"
if wr="$({ : > /boot/.ruya-write-test; } 2>&1)"; then
    rm -f /boot/.ruya-write-test
    bad "a file could be created in /boot: it is writable in the host namespace"
else
    case "$wr" in *"ead-only"*) ok "writing to /boot fails with 'Read-only file system'" ;; *) bad "writing to /boot failed for another reason: $wr" ;; esac
fi

# No text console: nothing started a login on tty1.
if journalctl -b -q -u getty@tty1.service --no-pager | grep -q -E 'Started|Starting'; then
    bad "getty@tty1 started in this boot (a login prompt may flash)"
else
    ok "getty@tty1 did not start"
fi
systemctl is-active plymouth-quit.service >/dev/null && ok "plymouth-quit.service ran (retain-splash)" || echo "note: plymouth-quit.service not active"
systemctl show -p ExecStart --value plymouth-quit.service | grep -q 'retain-splash' && ok "plymouth-quit uses --retain-splash" || bad "plymouth-quit does not retain the splash"
pgrep -x plymouthd >/dev/null && echo "note: plymouthd is still running" || ok "plymouthd has exited"

# The compositor is up, started after Plymouth had quit.
systemctl is-active 'ruya-compositor@tty1.service' >/dev/null && ok "compositor active" || bad "compositor not active"
systemctl show -p After --value 'ruya-compositor@tty1.service' | grep -q 'plymouth-quit-wait.service' && ok "compositor is ordered after plymouth-quit-wait" || bad "compositor is not ordered after plymouth-quit-wait"

echo "--- timeline of this boot (seconds since the kernel started, from the journal)"
for pat in 'plymouth-start.service' 'plymouth-quit.service' 'ruya-compositor@tty1.service'; do
    journalctl -b -q -o short-monotonic --no-pager -u "$pat" 2>/dev/null | grep -E 'Starting|Started|Finished' | head -2 | sed "s/^/  /"
done
uid="$(id -u ruya-shell 2>/dev/null || echo 0)"
journalctl -b -q -o short-monotonic --no-pager _UID="$uid" | grep -E 'ruya-shell: ready' | head -1 | sed 's/^/  /'
exit $fail
