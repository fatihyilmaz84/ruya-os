#!/usr/bin/env bash
# Checks the image's gaming kernel settings (RUY-525 ntsync, RUY-527 sysctls, RUY-737 the drivetemp module; docs/specs/01-platform.md 1.5)
# inside a running VM, as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-gaming-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-gaming-check.sh [check|flatpak <app-id>]
#
#   check    ntsync: the module is loaded (lsmod), /dev/ntsync is a character device with mode 0666, a
#            profile user (the first ruya-p<N>; "nobody" when no profile exists yet) opens it read-write
#            (python3), and its owner and SELinux label are printed for the record.
#            sysctl: vm.max_map_count = 2147483642 and kernel.split_lock_mitigate = 0.
#            scheduler (RUY-531): prints every block device's scheduler; vd*/nvme* stay [none]; an sd*/mmcblk*
#            with rotational 0 is [mq-deadline].
#   flatpak <app-id>   information only (RUY-525 criterion 3): does the sandbox of an installed Flatpak app
#            see /dev/ntsync with --device=all and with --device=dri only? Prints INFO lines, never fails
#            the run; prints UNVERIFIED when flatpak or the app is missing.
#
# NTSYNC_DEV overrides the device path, SYS_BLOCK /sys/block (host tests, scripts/test-vm-checks.sh).
set -u
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
dev="${NTSYNC_DEV:-/dev/ntsync}"
sysblock="${SYS_BLOCK:-/sys/block}"

check() {
    echo "--- ntsync"
    if lsmod | grep -q '^ntsync '; then ok "module ntsync is loaded"; else bad "module ntsync is not loaded (modules-load.d/ruyaos-ntsync.conf)"; fi
    # RUY-737: SATA drives get a temperature (Device health) only through this hwmon driver.
    if lsmod | grep -q '^drivetemp '; then ok "module drivetemp is loaded"; else bad "module drivetemp is not loaded (modules-load.d/ruyaos-drivetemp.conf)"; fi
    if [ -c "$dev" ]; then ok "$dev is a character device"; else bad "$dev is not a character device"; fi
    if [ -e "$dev" ]; then
        mode="$(stat -c '%a' "$dev")"
        echo "info: $dev mode $mode, owner $(stat -c '%U:%G' "$dev"), SELinux label $(stat -c '%C' "$dev" 2>/dev/null || echo unknown)"
        if [ "$mode" = 666 ]; then ok "$dev mode is 0666 (profile users need no udev rule)"; else bad "$dev mode is $mode, expected 0666 (a udev rule would be needed for profile users)"; fi
        user="$(getent passwd | awk -F: '$1 ~ /^ruya-p[0-9]+$/ {print $1; exit}')"
        if [ -z "$user" ]; then user=nobody; echo "info: no profile user exists yet, trying as nobody"; fi
        if runuser -u "$user" -- python3 -c 'import os, sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$dev"; then
            ok "$user opens $dev read-write"
        else
            bad "$user cannot open $dev read-write"
        fi
    fi

    echo "--- sysctl"
    mm="$(sysctl -n vm.max_map_count 2>&1)"
    [ "$mm" = 2147483642 ] && ok "vm.max_map_count = 2147483642" || bad "vm.max_map_count = $mm (expected 2147483642; Fedora's 10-map-count.conf is 1048576)"
    sl="$(sysctl -n kernel.split_lock_mitigate 2>&1)"
    [ "$sl" = 0 ] && ok "kernel.split_lock_mitigate = 0" || bad "kernel.split_lock_mitigate = $sl (expected 0; the kernel default is 1)"

    echo "--- I/O scheduler (RUY-531)"
    for q in "$sysblock"/*/queue; do
        [ -r "$q/scheduler" ] || continue
        d="$(basename "$(dirname "$q")")"
        sched="$(cat "$q/scheduler")"; rot="$(cat "$q/rotational" 2>/dev/null || echo ?)"
        echo "info: $d rotational=$rot scheduler: $sched"
        case "$d" in
            vd*) case "$sched" in *"[none]"*) ok "$d keeps none" ;; *) bad "$d scheduler is $sched, expected [none] (the rule must not touch it)" ;; esac ;;
            # A single-queue NVMe gets the kernel's mq-deadline by default; only bfq would mean a rule touched it.
            nvme*) case "$sched" in *"[bfq]"*) bad "$d scheduler is $sched; the rule must not touch NVMe" ;; *) ok "$d keeps the kernel default" ;; esac ;;
            sd[a-z]*|mmcblk[0-9]*)
                case "$d" in *boot[0-9]|*rpmb) continue ;; esac
                if [ "$rot" = 0 ]; then
                    case "$sched" in *"[mq-deadline]"*) ok "$d (flash) is mq-deadline" ;; *) bad "$d (rotational 0) scheduler is $sched, expected [mq-deadline] (61-ruya-block-scheduler.rules)" ;; esac
                fi ;;
        esac
    done
}

flatpak_info() {
    app="${1:-}"
    if [ -z "$app" ]; then echo "usage: vm-gaming-check.sh flatpak <app-id>"; exit 2; fi
    if ! command -v flatpak >/dev/null 2>&1; then echo "UNVERIFIED: flatpak is not installed"; return; fi
    if ! flatpak info "$app" >/dev/null 2>&1; then echo "UNVERIFIED: $app is not installed (flatpak list --app)"; return; fi
    echo "info: $(flatpak --version); host device: $(ls -l "$dev" 2>&1)"
    for perm in all dri; do
        if out="$(flatpak run --command=sh --device=$perm "$app" -c 'ls -l /dev/ntsync' 2>&1)"; then
            echo "INFO: --device=$perm: /dev/ntsync visible: $out"
        else
            echo "INFO: --device=$perm: /dev/ntsync not visible or the app has no sh: $(printf '%s' "$out" | head -1)"
        fi
    done
}

case "${1:-check}" in
    check) check ;;
    flatpak) flatpak_info "${2:-}"; exit 0 ;;
    *) echo "usage: vm-gaming-check.sh [check|flatpak <app-id>]"; exit 2 ;;
esac
if [ "$fail" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$fail"
