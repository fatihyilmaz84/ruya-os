#!/usr/bin/env bash
# Checks Devices1.Storage (udisks2, T-174) inside a running VM. Normally driven from the host by
# scripts/vm-storage-check.ps1, which hot-plugs a USB stick through the QEMU monitor
# (device_add usb-storage) between these steps. Run as root in the guest:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-storage-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-storage-check.sh <step>
# Steps, in the order the host runs them:
#   baseline   service up, polkit allows ruya-shell exactly what it needs, ListVolumes (no stick yet),
#              another user is refused
#   format     waits for the blank USB disk the host attached, formats it exFAT (label RUYASTICK)
#   gone       waits until the host has detached the stick again
#   watch      starts recording the Storage signals (busctl monitor)
#   plugged    after the host re-attached the formatted stick: VolumeAdded then VolumesChanged,
#              the volume is listed and mounted nosuid,nodev,noexec, writing works, a program on it
#              does not run, free_bytes is the real free space
#   busy       a process with its working directory on the stick makes Eject answer busy, the stick
#              stays mounted and listed
#   eject      Eject answers ok, the volume leaves the list, nothing stays mounted, no VolumeAdded
#              for the volumes that were there before
#   security   systemd-analyze --user security ruya-devices
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
st=org.ruyaos.Devices1.Storage
label=RUYASTICK
log=/tmp/storage-signals.log
uid="$(id -u ruya-shell)"
as_shell() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

list() { busctl --system call "$svc" "$path" "$st" ListVolumes; }
# The ListVolumes reply is one long line. The service writes each dictionary's keys in alphabetical
# order, so every dictionary starts with "filesystem": dict_of prints the one labelled $label.
dict_of() { list | sed 's/"filesystem" s/\n&/g' | grep "\"label\" s \"$label\""; }
stick_id() { dict_of | grep -o '"id" s "[^"]*"' | head -1 | sed 's/^"id" s "//; s/"$//'; }
# One field of the stick's dictionary.
field() { dict_of | grep -o "\"$1\" [a-z] \(\"[^\"]*\"\|[0-9a-z-]*\)" | head -1 | sed 's/^"[a-z_]*" [a-z] //; s/"//g'; }
usb_disk() { lsblk -dno NAME,TRAN | awk '$2=="usb" {print "/dev/" $1}' | head -1; }

baseline() {
    echo "--- baseline: the service and its permissions"
    if as_shell systemctl --user is-active ruya-devices >/dev/null; then ok "ruya-devices is active"; else bad "ruya-devices not active"; fi
    owner="$(busctl --system status "$svc" 2>/dev/null | sed -n 's/^UID=//p' | head -1)"
    [ "$owner" = "$uid" ] && ok "the name is owned by ruya-shell" || bad "name owner uid '$owner'"
    if busctl --system introspect "$svc" "$path" "$st" >/dev/null 2>&1; then ok "the Storage interface is served"; else bad "no Storage interface"; fi
    # udisks2 is D-Bus activated: the service's first read has started it.
    if systemctl is-active udisks2 >/dev/null; then ok "udisks2.service is active"; else bad "udisks2.service not active"; fi
    pid="$(pgrep -u ruya-shell -x ruya-devices | head -1)"
    if [ -z "$pid" ]; then bad "no ruya-devices process"; else
        # pkcheck: exit 0 = authorized without a prompt, 1 = not authorized, 2 = would ask for a password.
        for a in filesystem-mount eject-media power-off-drive; do
            pkcheck --action-id "org.freedesktop.udisks2.$a" --process "$pid" >/dev/null 2>&1; rc=$?
            [ "$rc" = 0 ] && ok "polkit allows ruya-devices: $a" || bad "polkit verdict for $a: exit $rc (want 0)"
        done
        # Everything else is refused by the rule (NO), including what udisks2's default policy
        # would allow an active session: formatting, unlocking, loop devices.
        for a in filesystem-mount-system filesystem-unmount-others filesystem-fstab modify-device modify-device-system encrypted-unlock loop-setup rescan; do
            pkcheck --action-id "org.freedesktop.udisks2.$a" --process "$pid" >/dev/null 2>&1; rc=$?
            [ "$rc" != 0 ] && ok "polkit does not allow ruya-devices: $a (exit $rc)" || bad "polkit allows $a, it must not"
        done
    fi
    echo "ListVolumes (no stick yet):"; list
    if [ -z "$(stick_id)" ]; then ok "the stick is not there yet"; else bad "a volume labelled $label exists already"; fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$st" ListVolumes 2>&1)"; then
        bad "nobody could call ListVolumes: $out"
    else
        echo "$out"; ok "storage call from nobody refused"
    fi
    for bad_id in "" "/org/freedesktop/UDisks2/block_devices/nope"; do
        r="$(busctl --system call "$svc" "$path" "$st" Eject s "$bad_id")"
        want='s "unknown-volume"'; [ -z "$bad_id" ] && want='s "invalid"'
        [ "$r" = "$want" ] && ok "Eject '$bad_id' answers $want" || bad "Eject '$bad_id' answered $r"
    done
}

format() {
    echo "--- format: the blank stick the host attached"
    n=0; disk=""
    while [ -z "$disk" ] && [ "$n" -lt 30 ]; do disk="$(usb_disk)"; [ -z "$disk" ] && sleep 1; n=$((n + 1)); done
    if [ -z "$disk" ]; then bad "no USB disk appeared"; return; fi
    ok "USB disk $disk appeared"
    mkfs.exfat -L "$label" "$disk" >/dev/null && ok "formatted exFAT, label $label" || bad "mkfs.exfat failed"
    sync
}

gone() {
    echo "--- gone: the host detached the stick"
    n=0; while [ -n "$(usb_disk)" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
    [ -z "$(usb_disk)" ] && ok "the USB disk is gone" || bad "the USB disk is still there"
}

watch() {
    echo "--- watch: recording Storage signals"
    pkill -f "busctl --system monitor $svc" 2>/dev/null
    : > "$log"
    nohup busctl --system monitor "$svc" > "$log" 2>&1 &
    sleep 1
    ok "recording to $log"
}

plugged() {
    echo "--- plugged: the stick was attached while the service ran"
    n=0; id=""
    while [ -z "$id" ] && [ "$n" -lt 40 ]; do id="$(stick_id)"; [ -z "$id" ] && sleep 1; n=$((n + 1)); done
    if [ -z "$id" ]; then bad "ListVolumes never listed $label"; list; return; fi
    ok "ListVolumes lists $label ($id) after ~$n s"
    # The mount happens before the list is published: the first listing is already mounted.
    mounted="$(field mounted)"; mp="$(field mount_point)"
    [ "$mounted" = true ] && ok "mounted: true" || bad "mounted='$mounted'"
    echo "filesystem=$(field filesystem) removable=$(field removable) read_only=$(field read_only) mount_point=$mp size=$(field size_bytes) free=$(field free_bytes)"
    [ "$(field filesystem)" = exfat ] && ok "filesystem exfat" || bad "filesystem $(field filesystem)"
    [ "$(field removable)" = true ] && ok "removable: true" || bad "removable $(field removable)"
    [ -n "$mp" ] && [ -d "$mp" ] && ok "the mount point exists: $mp" || bad "mount point '$mp'"
    opts="$(findmnt -no OPTIONS "$mp" 2>/dev/null)"
    echo "mount options: $opts"
    if out="$(runuser -u nobody -- ls /run/media/ruya-shell 2>&1)"; then bad "nobody can list /run/media/ruya-shell: $out"; else ok "nobody cannot read /run/media/ruya-shell"; fi
    for o in nosuid nodev noexec; do
        case ",$opts," in *",$o,"*) ok "mounted $o";; *) bad "mount option $o missing";; esac
    done
    # Signals: VolumeAdded for exactly this id, before VolumesChanged.
    sleep 1
    added="$(grep -ic "member=VolumeAdded" "$log")"
    [ "$added" = 1 ] && ok "exactly one VolumeAdded" || bad "VolumeAdded count $added"
    grep -q "$id" "$log" && ok "VolumeAdded carries the volume id" || bad "VolumeAdded without the id"
    first_add="$(grep -in "member=VolumeAdded" "$log" | head -1 | cut -d: -f1)"
    first_chg="$(grep -in "member=VolumesChanged" "$log" | head -1 | cut -d: -f1)"
    if [ -n "$first_add" ] && [ -n "$first_chg" ] && [ "$first_add" -lt "$first_chg" ]; then ok "VolumeAdded came before VolumesChanged"; else bad "signal order: added line '$first_add', changed line '$first_chg'"; fi
    # Writing works; running something from the stick does not.
    if echo hello > "$mp/test.txt" && [ "$(cat "$mp/test.txt")" = hello ]; then ok "writing to the stick works"; else bad "cannot write to $mp"; fi
    cp /usr/bin/true "$mp/prog" 2>/dev/null; chmod +x "$mp/prog" 2>/dev/null
    if out="$("$mp/prog" 2>&1)"; then bad "a program on the stick ran"; else echo "$out"; ok "a program on the stick does not run (noexec)"; fi
    # Free space is the filesystem's own, within a cluster of what the kernel says.
    kfree=$(( $(stat -f -c %a "$mp") * $(stat -f -c %S "$mp") )); sfree="$(field free_bytes)"
    echo "free: service $sfree, kernel $kfree"
    if [ -n "$sfree" ] && [ "$sfree" -gt 0 ] && [ $(( kfree - sfree )) -lt 4194304 ] && [ $(( sfree - kfree )) -lt 4194304 ]; then ok "free_bytes matches the filesystem"; else bad "free_bytes $sfree vs $kfree"; fi
    out="$(as_shell busctl --system call "$svc" "$path" "$st" ListVolumes >/dev/null 2>&1; echo $?)"
    [ "$out" = 0 ] && ok "ruya-shell can list" || bad "ruya-shell could not list"
}

busy() {
    echo "--- busy: a process works on the stick"
    id="$(stick_id)"; mp="$(field mount_point)"
    [ -n "$id" ] || { bad "no stick listed"; return; }
    (cd "$mp" && exec sleep 600) &
    holder=$!
    sleep 1
    r="$(busctl --system call "$svc" "$path" "$st" Eject s "$id")"
    [ "$r" = 's "busy"' ] && ok "Eject while a process uses the stick: busy" || bad "Eject answered $r"
    [ "$(field mounted)" = true ] && findmnt "$mp" >/dev/null && ok "still mounted and listed after busy" || bad "not mounted after busy"
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
}

eject() {
    echo "--- eject"
    id="$(stick_id)"; mp="$(field mount_point)"
    [ -n "$id" ] || { bad "no stick listed"; return; }
    r="$(busctl --system call "$svc" "$path" "$st" Eject s "$id")"
    [ "$r" = 's "ok"' ] && ok "Eject answers ok" || bad "Eject answered $r"
    n=0; while [ -n "$(stick_id)" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    [ -z "$(stick_id)" ] && ok "the volume left the list" || bad "still listed"
    findmnt "$mp" >/dev/null 2>&1 && bad "still mounted at $mp" || ok "nothing mounted at $mp"
    if usb_disk | grep -q .; then echo "note: the USB disk $(usb_disk) is still known to the kernel (QEMU keeps the device after PowerOff)"; else ok "the USB disk is gone from the kernel"; fi
    sleep 2
    # After the eject nothing must remount it: no new mount, no VolumeAdded beyond the first.
    [ "$(grep -ic "member=VolumeAdded" "$log")" = 1 ] && ok "no second VolumeAdded after the eject" || bad "VolumeAdded count $(grep -ic "member=VolumeAdded" "$log")"
    systemctl is-active udisks2 >/dev/null && ok "udisks2 still active" || bad "udisks2 not active"
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active" || bad "ruya-devices not active"
    pkill -f "busctl --system monitor $svc" 2>/dev/null
}

case "${1:-}" in
baseline) baseline ;;
format) format ;;
gone) gone ;;
watch) watch ;;
plugged) plugged ;;
busy) busy ;;
eject) eject ;;
security) as_shell systemd-analyze --user security ruya-devices --no-pager | tail -15 ;;
*) echo "usage: $0 baseline|format|gone|watch|plugged|busy|eject|security" >&2; exit 2 ;;
esac
[ "$fail" = 0 ] && echo "STEP OK: ${1:-}" || echo "STEP FAILED: ${1:-}"
exit "$fail"
