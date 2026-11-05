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
#   mformat    (T-184) waits for the second blank USB disk the host attached and gives it a GPT
#              with three partitions: two exFAT (RUYAPART1, RUYAPART2) and one ext2 (RUYARAW, a
#              filesystem the service does not mount)
#   mplugged   after the host re-attached that disk: the three partitions are listed with one and
#              the same "drive" value (not the first stick's), the exFAT ones mounted
#              nosuid,nodev,noexec, the ext2 one listed as "unknown" and not mounted, one
#              VolumeAdded per partition, VolumeAdded before VolumesChanged
#   meject     Eject of one partition takes the whole drive off: all three leave the list
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
# order, so every dictionary starts with "drive" (T-184): dict_labelled prints the one with a label.
dict_labelled() { list | sed 's/"drive" s/\n&/g' | grep "\"label\" s \"$1\""; }
# One field of the dictionary labelled $1: field_of LABEL KEY.
field_of() { dict_labelled "$1" | grep -o "\"$2\" [a-z] \(\"[^\"]*\"\|[0-9a-z-]*\)" | head -1 | sed 's/^"[a-z_]*" [a-z] //; s/"//g'; }
dict_of() { dict_labelled "$label"; }
stick_id() { field_of "$label" id; }
# One field of the stick's dictionary.
field() { field_of "$label" "$1"; }
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
    case "$(field drive)" in /org/freedesktop/UDisks2/drives/*) ok "drive: $(field drive)";; *) bad "drive '$(field drive)'";; esac
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

part1=RUYAPART1
part2=RUYAPART2
rawpart=RUYARAW

# T-184: a stick with several partitions. The service announces VolumeAdded once per partition
# (also for the one it does not mount); the shell groups them by the "drive" value and toasts once.
mformat() {
    echo "--- mformat: a second blank stick, three partitions"
    n=0; disk=""
    while [ -z "$disk" ] && [ "$n" -lt 30 ]; do disk="$(usb_disk)"; [ -z "$disk" ] && sleep 1; n=$((n + 1)); done
    if [ -z "$disk" ]; then bad "no USB disk appeared"; return; fi
    ok "USB disk $disk appeared"
    if printf 'label: gpt\n,24M\n,24M\n,\n' | sfdisk -q "$disk"; then ok "partitioned $disk (3 partitions)"; else bad "sfdisk failed"; return; fi
    udevadm settle
    n=0; while [ ! -b "${disk}3" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    if [ -b "${disk}1" ] && [ -b "${disk}2" ] && [ -b "${disk}3" ]; then ok "the three partition nodes exist"; else bad "partition nodes missing"; return; fi
    mkfs.exfat -L "$part1" "${disk}1" >/dev/null && ok "${disk}1: exFAT $part1" || bad "mkfs.exfat ${disk}1 failed"
    mkfs.exfat -L "$part2" "${disk}2" >/dev/null && ok "${disk}2: exFAT $part2" || bad "mkfs.exfat ${disk}2 failed"
    # ext2 is a filesystem udisks knows and the service does not mount ("unknown" in the contract).
    mkfs.ext2 -q -F -L "$rawpart" "${disk}3" && ok "${disk}3: ext2 $rawpart" || bad "mkfs.ext2 ${disk}3 failed"
    sync
    # The service mounts the partitions as they get their filesystem; let go before the host detaches.
    sleep 2
    for p in 1 2 3; do umount "${disk}$p" 2>/dev/null; done
    sync
}

mplugged() {
    echo "--- mplugged: the three-partition stick was attached while the service ran"
    n=0
    while { [ -z "$(field_of "$part1" id)" ] || [ -z "$(field_of "$part2" id)" ] || [ -z "$(field_of "$rawpart" id)" ]; } && [ "$n" -lt 40 ]; do sleep 1; n=$((n + 1)); done
    id1="$(field_of "$part1" id)"; id2="$(field_of "$part2" id)"; id3="$(field_of "$rawpart" id)"
    if [ -z "$id1" ] || [ -z "$id2" ] || [ -z "$id3" ]; then bad "not all partitions were listed (after ~$n s): '$id1' '$id2' '$id3'"; list; return; fi
    ok "ListVolumes lists all three partitions after ~$n s"
    d1="$(field_of "$part1" drive)"; d2="$(field_of "$part2" drive)"; d3="$(field_of "$rawpart" drive)"
    echo "drive values: '$d1' '$d2' '$d3'"
    if [ -n "$d1" ] && [ "$d1" = "$d2" ] && [ "$d1" = "$d3" ]; then ok "the three partitions share one non-empty drive value"; else bad "drive values differ or are empty"; fi
    [ "$(field_of "$part1" filesystem)" = exfat ] && [ "$(field_of "$part2" filesystem)" = exfat ] && ok "both exFAT partitions report exfat" || bad "filesystems '$(field_of "$part1" filesystem)' '$(field_of "$part2" filesystem)'"
    [ "$(field_of "$part1" mounted)" = true ] && [ "$(field_of "$part2" mounted)" = true ] && ok "both exFAT partitions are mounted" || bad "exFAT partitions not both mounted"
    for l in "$part1" "$part2"; do
        mp="$(field_of "$l" mount_point)"
        opts="$(findmnt -no OPTIONS "$mp" 2>/dev/null)"
        for o in nosuid nodev noexec; do
            case ",$opts," in *",$o,"*) ok "$l mounted $o";; *) bad "$l: mount option $o missing ($opts)";; esac
        done
    done
    # The unsupported partition stays listed, as "unknown", and is never mounted.
    [ "$(field_of "$rawpart" filesystem)" = unknown ] && ok "the ext2 partition is listed as unknown" || bad "ext2 partition filesystem '$(field_of "$rawpart" filesystem)'"
    [ "$(field_of "$rawpart" mounted)" = false ] && ok "the ext2 partition is not mounted" || bad "ext2 partition mounted='$(field_of "$rawpart" mounted)'"
    [ "$(field_of "$rawpart" removable)" = true ] && ok "the ext2 partition is removable" || bad "ext2 partition removable"
    if [ -n "$d1" ] && [ "$d1" != "$(field_of "$label" drive)" ]; then ok "not the same drive as the first stick"; fi
    # Signals: one VolumeAdded per partition, each before the VolumesChanged that lists it.
    sleep 1
    added="$(grep -ic "member=VolumeAdded" "$log")"
    [ "$added" = 3 ] && ok "three VolumeAdded, one per partition" || bad "VolumeAdded count $added (want 3)"
    for id in "$id1" "$id2" "$id3"; do
        grep -q "$id" "$log" && ok "VolumeAdded carries $id" || bad "no signal carries $id"
    done
    first_add="$(grep -in "member=VolumeAdded" "$log" | head -1 | cut -d: -f1)"
    first_chg="$(grep -in "member=VolumesChanged" "$log" | head -1 | cut -d: -f1)"
    if [ -n "$first_add" ] && [ -n "$first_chg" ] && [ "$first_add" -lt "$first_chg" ]; then ok "VolumeAdded came before VolumesChanged"; else bad "signal order: added line '$first_add', changed line '$first_chg'"; fi
}

meject() {
    echo "--- meject: ejecting one partition takes the whole drive off"
    id1="$(field_of "$part1" id)"; mp1="$(field_of "$part1" mount_point)"; mp2="$(field_of "$part2" mount_point)"
    [ -n "$id1" ] || { bad "no partition listed"; return; }
    r="$(busctl --system call "$svc" "$path" "$st" Eject s "$id1")"
    [ "$r" = 's "ok"' ] && ok "Eject answers ok" || bad "Eject answered $r"
    n=0; while { [ -n "$(field_of "$part1" id)" ] || [ -n "$(field_of "$part2" id)" ] || [ -n "$(field_of "$rawpart" id)" ]; } && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    if [ -z "$(field_of "$part1" id)" ] && [ -z "$(field_of "$part2" id)" ] && [ -z "$(field_of "$rawpart" id)" ]; then ok "all three partitions left the list"; else bad "a partition is still listed"; fi
    for mp in "$mp1" "$mp2"; do
        findmnt "$mp" >/dev/null 2>&1 && bad "still mounted at $mp" || ok "nothing mounted at $mp"
    done
    systemctl is-active udisks2 >/dev/null && ok "udisks2 still active" || bad "udisks2 not active"
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active" || bad "ruya-devices not active"
    pkill -f "busctl --system monitor $svc" 2>/dev/null
}

case "${1:-}" in
baseline) baseline ;;
mformat) mformat ;;
mplugged) mplugged ;;
meject) meject ;;
format) format ;;
gone) gone ;;
watch) watch ;;
plugged) plugged ;;
busy) busy ;;
eject) eject ;;
security) as_shell systemd-analyze --user security ruya-devices --no-pager | tail -15 ;;
*) echo "usage: $0 baseline|format|gone|watch|plugged|busy|eject|mformat|mplugged|meject|security" >&2; exit 2 ;;
esac
[ "$fail" = 0 ] && echo "STEP OK: ${1:-}" || echo "STEP FAILED: ${1:-}"
exit "$fail"
