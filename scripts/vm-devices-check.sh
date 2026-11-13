#!/usr/bin/env bash
# Checks the Devices service (audio T-128, network T-132, controller batteries T-161, Bluetooth T-173) inside a running VM booted with sound. Copy and run as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-devices-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-devices-check.sh [check|events|security|state|batteries|bluetooth|gamepads|storage|thermal|thermal-fake|time|system|inputd]
# check (default): unit active, name owned by ruya-shell, ListSinks, a MasterVolume write reaches
# PipeWire, a call from another user is refused; then the network part: State is connected, Primary is
# the ethernet link with an IPv4 address, ListWifi and Scan answer, unknown ids are refused, another
# user is refused, pkcheck as the service's process allows the five NetworkManager actions it needs and
# refuses eleven others (T-180, T-448); then the batteries part: upower is installed and answers on the bus, ListBatteries answers an
# empty list (no controller in the VM; a real controller's battery is NOT checked here), another user is
# refused; then the Bluetooth part: bluetooth.service is active and org.bluez is on the bus, Powered is false,
# ListDevices answers an empty list, StartScan/Pair/Connect answer unavailable (no adapter in the VM; a real
# adapter and controller are NOT checked here), unknown ids and empty ids are refused, another user is
# refused. T-203: InputPresent is true (QEMU's keyboard counts, so /sys/class/input is readable in the user unit), StartControllerPairing
# answers unavailable (no adapter) and invalid for 301 s, ControllerPairingState stays idle, StopControllerPairing answers ok, another user is
# refused. Needs the shell logged in (VM booted with -Audio).
# Then the storage part (T-196): GetSystemUsage matches `stat -f /var` (within 1 %), apps_bytes and data_bytes
# are measured in the background (data_bytes is -1 for now: the profile homes are 0700 profile users'),
# free + apps (+ data when known) + system add up to total, apps_bytes is close to du of
# /var/lib/flatpak, another user is refused, and installing a signed 80 MB test app through the Store makes
# apps_bytes grow and sends SystemUsageChanged (SKIP_APPS_GROWTH=1 skips the install; `storage` runs only this part).
# Then the thermal part (T-200): ListSensors answers; with a processor sensor in /sys (coretemp, k10temp or the
# x86_pkg_temp thermal zone) there is a cpu entry whose value is within 3 degrees of /sys, Level is normal when the
# VM idles; QEMU may expose no sensor at all: then there is no cpu entry (the list is empty) and Level is normal.
# Another user is refused. `thermal` runs only this part. `thermal-fake` (not part of check) points the service at a
# made-up sysfs tree (RUYA_THERMAL_SYSFS) and walks one sensor through normal, hot, critical and back, checking
# Level and the LevelChanged signal; it restarts ruya-devices twice and removes the tree.
# Then the time part (T-213): GetTimezone and ListTimezones answer (the list has Europe/Istanbul and UTC), NtpSynchronised is a
# boolean, an unknown or malformed name is invalid, a call from another user is refused, root sets Asia/Tokyo and timedatectl,
# /etc/localtime and `date +%Z` follow, a zone set by timedatectl from outside shows in GetTimezone within 5 s (the service follows
# timedated), the shell's own call is `forbidden` while profiles exist and nobody (or a standard profile) is signed in, `ok` for a signed-in admin
# and while no profile exists (first-boot setup), pkcheck as the service's process allows org.freedesktop.timedate1.set-timezone and refuses set-time, set-ntp
# and set-local-rtc. The original zone is restored. `time` runs only this part.
# Then the system information part (T-226): Devices1.System.GetInfo against the guest's own files and tools: console.kernel is
# uname -r, console.version the image's version file, firmware and Secure Boot match /sys/firmware, uptime follows /proc/uptime
# and moves between calls, cpu.model/threads/cores match /proc/cpuinfo and lscpu, memory total/available/used and swap match
# /proc/meminfo (no swap: the keys are absent, not 0), the GPU's pci_id and driver match /sys/class/drm/card0 (no GPU: absent),
# every internal disk of lsblk is in storage.drives, the default route's interface and MAC match, no Bluetooth adapter: no chipset;
# another user is refused. Then Storage.SaveReport: an unknown volume, unsafe file names and no files are refused, another user is
# refused, and with a mounted removable volume (attach one to QEMU: -drive if=none,id=u,file=stick.img,format=raw -device usb-storage,drive=u)
# the two report files are written there and read back, and Storage.ListFiles and ReadFile (RUY-42) list the JSON and read it
# back, refuse more than max_bytes unread, a path and a symlink (on a filesystem that has them). Then the performance part (T-451): Devices1.System.GetPerformance
# answers all nine metrics with a contract state, the rates are "unavailable" at a first reading and cpu_percent is a
# 0-100 "supported" share at the next, ram_total is MemTotal and ram_used within 5 % of MemTotal - MemAvailable, two
# calls inside 250 ms answer the same, cpu_temp follows whether /sys has a processor sensor, the GPU load, VRAM, the
# GPU temperature and power are "unsupported" as the service runs as ruya-shell on virtio-gpu (no amdgpu sysfs, RAPL
# root-only or absent), another user is refused. T-454: GetBrightness answers (su) "unsupported" 0 (QEMU has no backlight device), SetBrightness 50 is "unsupported", 0 is "invalid", another user is refused. `system` runs only these parts. The hardware part (the Dell: compare the
# page with `lscpu`, `free`, `lspci`) is done by eye on the machine, see the T-226 Outcome.
# inputd (T-337, not part of check): virtual gamepads from /dev/uinput; a pad destroyed while holding Down and A leaves KEY_DOWN and KEY_ENTER up on
# "RuyaOS Navigation" (read with EVIOCGKEY); two pads hold Down, one lets go, Down stays down, the other lets go, Down is up; the journal line
# `gone: ...; released ...` is there. WARNING: it sends real Down and Enter key presses to the running shell, which activates whatever has focus:
# run it last, or with a throwaway screen focused. No /dev/uinput access as root: prints UNVERIFIED and passes nothing.
# events: only the PipeWire event checks (T-133); IDLE=60 adds the idle-process count (also part of check; samples the process list for IDLE seconds).
# state: prints State and Primary (for the link test, see docs/dev-setup.md).
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
ifc=org.ruyaos.Devices1.Audio
net=org.ruyaos.Devices1.Network
bat=org.ruyaos.Devices1.Batteries
therm=org.ruyaos.Devices1.Thermal
bt=org.ruyaos.Devices1.Bluetooth
uid="$(id -u ruya-shell)"
as_shell() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# T-193: polkit_expect <action-id> <pid> <want-exit> <text>. pkcheck answers 1 ("not authorized") for
# an id polkit does not know as well, so a mistyped or removed id would pass as "refused". The id
# must be registered first (pkaction --action-id exits 0 only then); otherwise this is a FAIL.
polkit_expect() {
    local action="$1" pid="$2" want="$3" text="$4" rc
    if ! pkaction --action-id "$action" >/dev/null 2>&1; then
        bad "polkit action $action is not registered (pkaction --action-id fails): its verdict means nothing"
        return
    fi
    pkcheck --action-id "$action" --process "$pid" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$want" ]; then ok "$text"; else bad "polkit verdict for $action: exit $rc (want $want)"; fi
}

# T-133: PipeWire is followed by events (one long-running pw-dump --monitor), not polled.
# $1 = seconds to watch the idle system for spawned processes (0 skips that part).
events_check() {
    idle="$1"
    echo "--- events (T-133)"
    mons="$(pgrep -x pw-dump | wc -l)"
    if [ "$mons" = 1 ]; then ok "exactly one pw-dump runs (the monitor)"; else bad "$mons pw-dump processes"; fi
    pgrep -a -x pw-dump
    set_outside() { as_shell wpctl set-volume @DEFAULT_AUDIO_SINK@ "$1"; }
    # Waits up to $2 tenths of a second for MasterVolume to read $1; prints the tenths it took.
    wait_volume() {
        n=0
        while [ "$n" -le "$2" ]; do
            [ "$(busctl --system get-property "$svc" "$path" "$ifc" MasterVolume 2>/dev/null)" = "u $1" ] && { echo "$n"; return 0; }
            sleep 0.1; n=$((n + 1))
        done
        return 1
    }
    set_outside 0.50; sleep 1
    set_outside 0.20
    if took="$(wait_volume 20 10)"; then ok "a wpctl change from outside shows in MasterVolume after ~$took/10 s"; else bad "MasterVolume did not follow wpctl within 1 s"; fi
    if [ "$idle" -gt 0 ]; then
        # The outside change makes the service re-read PipeWire once or twice within ~0.5 s (debounced
        # events, T-133); let that settle before counting (0.0.63: a trailing pw-dump landed in the window).
        # Wait for quiet (0.0.64: one trailing pw-dump after a fixed 2 s): no pw-dump or wpctl besides
        # the monitor for 3 s in a row, at most 15 s.
        monitor="$(pgrep -x pw-dump | head -1)"
        quiet=0; waited=0
        # 8 s, longer than PipeWire's idle suspend of the nodes the check's own volume change woke
        # (0.0.65: one pw-dump by ruya-devices itself after 3 s of quiet, an event, not a poll).
        while [ "$quiet" -lt 80 ] && [ "$waited" -lt 250 ]; do
            if pgrep -x 'pw-dump|wpctl' | grep -v -x "$monitor" | grep -q .; then quiet=0; else quiet=$((quiet + 1)); fi
            sleep 0.1; waited=$((waited + 1))
        done
        echo "quiet for 8 s after $((waited / 10)) s"
        # Idle: sample the process list ten times a second; the 1 s poll started a pw-dump and a
        # wpctl every second (each lives some tens of ms), so it would be caught many times.
        cpu0="$(as_shell systemctl --user show ruya-devices -p CPUUsageNSec --value)"
        seen=" "; samples=$((idle * 10)); i=0
        while [ "$i" -lt "$samples" ]; do
            for p in $(pgrep -x 'pw-dump|wpctl'); do
                [ "$p" = "$monitor" ] && continue
                case "$seen" in *" $p "*) ;; *) seen="$seen$p "
                    echo "spawned: $(ps -o pid=,ppid=,etimes=,args= -p "$p" 2>/dev/null) parent: $(ps -o args= -p "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" 2>/dev/null)";; esac
            done
            sleep 0.1; i=$((i + 1))
        done
        cpu1="$(as_shell systemctl --user show ruya-devices -p CPUUsageNSec --value)"
        spawned="$(echo $seen | wc -w)"
        cpu_ms=$(( (cpu1 - cpu0) / 1000000 ))
        echo "pw-dump/wpctl processes seen in ${idle} s idle (besides the monitor): $spawned; ruya-devices used ${cpu_ms} ms of CPU"
        if [ "$spawned" = 0 ]; then ok "idle: no pw-dump or wpctl started"; else bad "$spawned short-lived pw-dump/wpctl in ${idle} s idle"; fi
        if [ "$cpu_ms" -lt 200 ]; then ok "idle: the service used ${cpu_ms} ms of CPU"; else bad "idle CPU ${cpu_ms} ms"; fi
        [ "$(pgrep -x pw-dump | wc -l)" = 1 ] && ok "still only the monitor" || bad "more than the monitor"
    fi
    echo "restarting PipeWire"
    as_shell systemctl --user restart pipewire.service
    n=0
    until as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 || [ "$n" -ge 30 ]; do sleep 1; n=$((n + 1)); done
    sleep 3
    set_outside 0.30
    if took="$(wait_volume 30 40)"; then ok "service recovered after the PipeWire restart (MasterVolume followed in ~$took/10 s)"; else bad "MasterVolume did not follow after the PipeWire restart"; fi
    [ "$(pgrep -x pw-dump | wc -l)" = 1 ] && ok "one monitor again" || bad "monitor count after restart: $(pgrep -x pw-dump | wc -l)"
    as_shell systemctl --user status ruya-devices --no-pager | tail -6
    busctl --system set-property "$svc" "$path" "$ifc" MasterVolume u 50
}

# T-173: BlueZ behind Devices1.Bluetooth. No adapter in the VM: the service answers, the list is empty.
bluetooth_check() {
    echo "--- bluetooth (T-173): BlueZ behind Devices1.Bluetooth"
    if systemctl is-active bluetooth; then ok "bluetooth.service is active"; else bad "bluetooth.service not active"; fi
    if busctl --system status org.bluez >/dev/null 2>&1; then ok "org.bluez is on the system bus"; else bad "org.bluez is not on the bus"; fi
    ls /sys/class/bluetooth 2>/dev/null | head -3
    powered="$(busctl --system get-property "$svc" "$path" "$bt" Powered)"
    echo "Powered: $powered"
    case "$powered" in 'b false') ok "Powered is false (no adapter)";; *) bad "Powered is not false";; esac
    disc="$(busctl --system get-property "$svc" "$path" "$bt" Discovering)"
    case "$disc" in 'b false') ok "Discovering is false";; *) bad "Discovering is not false: $disc";; esac
    list="$(busctl --system call "$svc" "$path" "$bt" ListDevices)"
    echo "ListDevices: $list"
    case "$list" in 'aa{sv} 0') ok "ListDevices answers an empty list";; *) bad "ListDevices did not answer an empty aa{sv}";; esac
    scan="$(busctl --system call "$svc" "$path" "$bt" StartScan)"
    echo "StartScan: $scan"
    case "$scan" in 's "unavailable"') ok "StartScan answers unavailable";; *) bad "StartScan did not answer unavailable";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Pair sb AA:BB:CC:DD:EE:FF false)"
    case "$r" in 's "unavailable"') ok "Pair answers unavailable";; *) bad "Pair answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Pair sb "" false)"
    case "$r" in 's "invalid"') ok "Pair with an empty id is invalid";; *) bad "Pair('') answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Forget s AA:BB:CC:DD:EE:FF)"
    case "$r" in 's "unknown-device"') ok "Forget of an unknown device is refused";; *) bad "Forget answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" StopScan)"
    case "$r" in 's "ok"') ok "StopScan with no scan answers ok";; *) bad "StopScan answered: $r";; esac
    if out="$(busctl --system set-property "$svc" "$path" "$bt" Powered b true 2>&1)"; then
        bad "Powered could be set with no adapter"
    else
        echo "$out"; ok "Powered write without an adapter answers a D-Bus error"
    fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$bt" ListDevices 2>&1)"; then
        bad "nobody could call ListDevices: $out"
    else
        echo "$out"; ok "bluetooth call from nobody refused"
    fi
    # RUY-411 (06-input.md section 6): unbonded HID stays closed. ClassicBondedOnly defaults to true
    # when no file sets it; no config of the image may turn it off. HID goes through the kernel.
    cfgs="$(ls /etc/bluetooth/*.conf /usr/etc/bluetooth/*.conf 2>/dev/null)"
    echo "bluetooth config files: $cfgs"
    if [ -n "$cfgs" ] && grep -hEi '^[[:space:]]*ClassicBondedOnly[[:space:]]*=[[:space:]]*(false|0|no)' $cfgs; then
        bad "ClassicBondedOnly is set to false in the BlueZ config"
    else
        ok "ClassicBondedOnly is not turned off (BlueZ default true)"
    fi
    # UserspaceHID must sit under [General]: awk prints the section of the key.
    hid_section="$(awk '/^[[:space:]]*\[/ {s=$0} /^[[:space:]]*UserspaceHID[[:space:]]*=[[:space:]]*false[[:space:]]*$/ {print s}' /etc/bluetooth/input.conf 2>/dev/null | tr -d '[:space:]')"
    if [ "$hid_section" = "[General]" ] &&
        ! grep -hEi '^[[:space:]]*UserspaceHID[[:space:]]*=[[:space:]]*(true|1|yes)' $cfgs; then
        ok "UserspaceHID=false under [General] in /etc/bluetooth/input.conf"
    else
        bad "UserspaceHID=false is not under [General] in /etc/bluetooth/input.conf"
    fi
    # T-203: the controller pairing window. No adapter in the VM, so it cannot open; the rest is checked.
    ip="$(busctl --system get-property "$svc" "$path" "$bt" InputPresent)"
    echo "InputPresent: $ip"
    case "$ip" in 'b true') ok "InputPresent is true (QEMU's keyboard counts; /sys/class/input is readable in the user unit)";; *) bad "InputPresent is not true: $ip";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" StartControllerPairing u 0)"
    case "$r" in 's "unavailable"') ok "StartControllerPairing answers unavailable (no adapter)";; *) bad "StartControllerPairing answered: $r";; esac
    st="$(busctl --system get-property "$svc" "$path" "$bt" ControllerPairingState)"
    case "$st" in 's "idle"') ok "ControllerPairingState stays idle";; *) bad "ControllerPairingState is: $st";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" StartControllerPairing u 301)"
    case "$r" in 's "invalid"') ok "a window of 301 s is invalid";; *) bad "StartControllerPairing 301 answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" StopControllerPairing)"
    case "$r" in 's "ok"') ok "StopControllerPairing answers ok";; *) bad "StopControllerPairing answered: $r";; esac
    for m in "StartControllerPairing u 0" "StopControllerPairing"; do
        if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$bt" $m 2>&1)"; then
            bad "nobody could call $m: $out"
        else
            echo "$out"; ok "$m from nobody refused"
        fi
    done
    # T-453: ListGamepads answers a list (QEMU's keyboard is no pad, so it is empty here), and nobody else may call it.
    r="$(busctl --system call "$svc" "$path" "$bt" ListGamepads)"
    echo "ListGamepads: $r"
    case "$r" in 'aa{sv} 0') ok "ListGamepads answers an empty list (no controller in the VM; the keyboard is no pad)";; *) bad "ListGamepads did not answer an empty aa{sv}: $r";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$bt" ListGamepads 2>&1)"; then
        bad "nobody could call ListGamepads: $out"
    else
        echo "$out"; ok "ListGamepads from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the Bluetooth calls" || bad "ruya-devices not active"
    bluetooth_fake_check
    bluetooth_two_adapters_check
    bluetooth_two_pads_check
    bluetooth_keyboard_check
}

# T-300: the VM has no Bluetooth adapter, so ListDevices is empty on the system bus. `bonded` and
# `device_name` are read from a second instance of the service on ruya-shell's own user bus
# (`ruya-devices --session`: the fake BlueZ with a renamed pad that is paired but not bonded). The
# real unit owns org.ruyaos.Devices1 on the SYSTEM bus only, so the name is free on the user bus.
# JSON is parsed (python3 stays in the image), key order is never relied on.
bluetooth_fake_check() {
    local out verdict ubus="unix:path=/run/user/$uid/bus"
    echo "--- bluetooth (T-300): bonded and device_name of a fake device (ruya-shell's user bus, FakeBluez)"
    if ! command -v python3 >/dev/null; then
        bad "python3 is needed for the fake-device check"
        return
    fi
    if as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1; then
        bad "org.ruyaos.Devices1 is already on ruya-shell's user bus: the fake-device check needs the name free"
        return
    fi
    out="$(as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" bash -c '
        /usr/bin/ruya-devices --session >/dev/null 2>&1 &
        pid=$!
        n=0
        until busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1 || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
        busctl --user --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Bluetooth ListDevices
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    ' 2>&1)"
    verdict="$(printf '%s' "$out" | python3 -I -c '
import json, sys
text = sys.stdin.read()
try:
    devices = json.loads(text[text.index("{"):])["data"][0]
except Exception as err:
    print("unparsable: %r" % (err,)); sys.exit(0)
rows = {d["id"]["data"]: d for d in devices}
for d in devices:
    print("device %s name=%r device_name=%r paired=%s bonded=%s family=%r" % (
        d["id"]["data"], d["name"]["data"], d["device_name"]["data"], d["paired"]["data"], d["bonded"]["data"], d["family"]["data"]))
old = rows.get("AA:00:00:00:00:03")
good = rows.get("AA:00:00:00:00:01")
if old is None or good is None:
    print("missing: the fake devices are not listed")
elif old["bonded"]["data"] is not False or old["paired"]["data"] is not True:
    print("wrong: the old pad should be paired and not bonded")
elif good["bonded"]["data"] is not True:
    print("wrong: a normal pad should be bonded")
elif old["name"]["data"] != "Living room pad" or old["device_name"]["data"] != "DualSense Wireless Controller":
    print("wrong: name is the alias and device_name the model")
elif old["family"]["data"] != "playstation":
    print("wrong: a renamed DualSense keeps its family")
else:
    print("VERDICT ok")
' 2>&1)"
    echo "$verdict"
    case "$verdict" in
    *"VERDICT ok"*) ok "ListDevices carries bonded and device_name (a renamed DualSense: alias, model, playstation, paired and not bonded)";;
    *) bad "ListDevices of the fake BlueZ: $verdict $out";;
    esac
}

# T-336: a second instance of the service with the two-adapter fake (RUYA_DEVICES_FAKE_BLUETOOTH=two-adapters)
# on ruya-shell's user bus: AA:..:11 lives on hci1; it must be listed with adapter hci1, and Connect and
# Forget of it must answer ok (the fake only accepts a call that goes through the adapter holding the device).
# T-335: the same instance's stderr (what the journal collects from the real unit) must say what happened:
# the connect and the forget with who asked and through which adapter, and the pairing window's open and close.
bluetooth_two_adapters_check() {
    local out verdict ubus="unix:path=/run/user/$uid/bus" bt_user=org.ruyaos.Devices1.Bluetooth
    local log="/run/user/$uid/ruya-devices-two-adapters.log" missing want
    echo "--- bluetooth (T-336): two adapters (ruya-shell's user bus, FakeBluez::with_two_adapters)"
    if ! command -v python3 >/dev/null; then
        bad "python3 is needed for the two-adapter check"
        return
    fi
    if as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1; then
        bad "org.ruyaos.Devices1 is already on ruya-shell's user bus: the two-adapter check needs the name free"
        return
    fi
    out="$(as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" RUYA_DEVICES_FAKE_BLUETOOTH=two-adapters bash -c '
        /usr/bin/ruya-devices --session >/dev/null 2>'"$log"' &
        pid=$!
        n=0
        until busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1 || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
        call() { busctl --user --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 '"$bt_user"' "$@"; }
        echo "START $(call StartControllerPairing u 0)"
        echo "STOP $(call StopControllerPairing)"
        echo "LIST $(call ListDevices)"
        echo "CONNECT $(call Connect s AA:00:00:00:00:11)"
        echo "FORGET $(call Forget s AA:00:00:00:00:11)"
        echo "LIST2 $(call ListDevices)"
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    ' 2>&1)"
    verdict="$(printf '%s' "$out" | python3 -I -c '
import json, sys
rows = {}
for line in sys.stdin.read().splitlines():
    key, _, body = line.partition(" ")
    try:
        rows[key] = json.loads(body)["data"]
    except Exception:
        pass
try:
    first = {d["id"]["data"]: d for d in rows["LIST"][0]}
    second = {d["id"]["data"] for d in rows["LIST2"][0]}
    pad = first["AA:00:00:00:00:11"]
    other = first["AA:00:00:00:00:01"]
except Exception as err:
    print("unparsable: %r" % (err,)); sys.exit(0)
for d in first.values():
    print("device %s adapter=%r" % (d["id"]["data"], d.get("adapter", {}).get("data")))
if pad["adapter"]["data"] != "hci1" or other["adapter"]["data"] != "hci0":
    print("wrong: the pads should say hci1 and hci0")
elif rows.get("START") != ["ok"] or rows.get("STOP") != ["ok"]:
    print("wrong: the pairing window answered %r / %r" % (rows.get("START"), rows.get("STOP")))
elif rows.get("CONNECT") != ["ok"]:
    print("wrong: Connect of the pad on hci1 answered %r" % (rows.get("CONNECT"),))
elif rows.get("FORGET") != ["ok"]:
    print("wrong: Forget of the pad on hci1 answered %r" % (rows.get("FORGET"),))
elif "AA:00:00:00:00:11" in second or "AA:00:00:00:00:01" not in second:
    print("wrong: Forget should remove only the pad of hci1")
else:
    print("VERDICT ok")
' 2>&1)"
    echo "$verdict"
    case "$verdict" in
    *"VERDICT ok"*) ok "a pad on hci1 is listed with adapter hci1; Connect and Forget of it answer ok";;
    *) bad "ListDevices/Connect/Forget of the two-adapter fake: $verdict $out";;
    esac
    missing=
    for want in         'ruya-devices: pairing window opened on hci1 for 2 min'         'ruya-devices: pairing window on hci1 closed: stopped'         'ruya-devices: connect AA:00:00:00:00:11 "Second Pad" (hci1): user'         'ruya-devices: remove AA:00:00:00:00:11 "Second Pad" (hci1): forget'; do
        grep -qF -- "$want" "$log" 2>/dev/null || missing="$missing [$want]"
    done
    if [ -z "$missing" ]; then
        ok "the service's log names the window (opened, closed: stopped), the connect (user) and the forget, each with its adapter"
    else
        echo "--- log:"; cat "$log" 2>/dev/null
        bad "the service's log lacks:$missing"
    fi
    rm -f "$log"
}

# T-453: ListGamepads with a pad that exists. A virtual gamepad is made through /dev/uinput (root; USB bus, Microsoft's
# vendor id, BTN_SOUTH and BTN_EAST: what the service takes for a pad, input.rs). The service reads the kernel's input
# devices every two seconds, so the check waits up to 8 s: the pad must then be in ListGamepads once (id and name
# "Ruya Test Pad", family xbox, transport usb, exactly the four keys, the baseline included: the service did not
# start with it), and gone again up to 8 s after the device is destroyed. No uinput in the image: reported, not a failure.
gamepads_check() {
    local verdict
    echo "--- gamepads (T-453): ListGamepads with a virtual pad (/dev/uinput)"
    if ! command -v python3 >/dev/null; then
        bad "python3 is needed for the gamepads check"
        return
    fi
    if [ ! -e /dev/uinput ]; then
        modprobe uinput 2>/dev/null || true
    fi
    if [ ! -e /dev/uinput ]; then
        echo "SKIP: no /dev/uinput in this image; ListGamepads with a real pad is not checked here"
        return
    fi
    verdict="$(python3 -I - "$svc" "$path" "$bt" <<'PY'
import fcntl, json, os, struct, subprocess, sys, time
svc, path, iface = sys.argv[1:4]
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_SETUP = 0x40045564, 0x40045565, 0x405C5503
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
def pads():
    out = subprocess.run(["busctl", "--system", "--json=short", "call", svc, path, iface, "ListGamepads"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)["data"][0]
def wait(want, seconds):
    end = time.time() + seconds
    while True:
        got = pads()
        if len(got) == want or time.time() > end:
            return got
        time.sleep(0.5)
try:
    if pads():
        print("wrong: the VM already has a pad:", pads())
        sys.exit(0)
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, 1)
    for code in (0x130, 0x131):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("<HHHH80sI", 3, 0x045E, 0x028E, 1, b"Ruya Test Pad", 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    try:
        got = wait(1, 8)
        if len(got) != 1:
            print("wrong: the virtual pad is not in ListGamepads after 8 s:", got)
            sys.exit(0)
        pad = {k: v["data"] for k, v in got[0].items()}
        want = {"id": "Ruya Test Pad", "name": "Ruya Test Pad", "family": "xbox", "transport": "usb"}
        if pad != want:
            print("wrong: the pad is", pad, "not", want)
            sys.exit(0)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
    if wait(0, 8):
        print("wrong: the pad is still listed 8 s after it was destroyed")
        sys.exit(0)
    print("VERDICT ok")
except Exception as err:
    print("wrong:", err)
PY
)"
    echo "$verdict"
    case "$verdict" in
        *"VERDICT ok"*) ok "ListGamepads lists a virtual USB pad (id, name, xbox, usb) within 8 s and drops it within 8 s of its removal";;
        *) bad "ListGamepads with a virtual pad: $verdict";;
    esac
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the gamepads check" || bad "ruya-devices not active"
}

# T-334: two pads of one model at once (RUYA_DEVICES_FAKE_BLUETOOTH=two-pads, FakeBluez::with_two_pads) on
# ruya-shell's user bus: AA:..:04 is paired, bonded and connected, AA:..:05 is in range; both are called
# "Wireless Controller" with the same modalias. The pairing window is opened and the second pad is paired
# (by hand, as the Settings pane does; the --session service has no BlueZ signals to wake the window's own
# pairing, so the real window path is covered by the Rust tests). Then ListDevices must carry both pads,
# both paired and bonded, the first still connected; Forget of the second must leave the first; and the
# service's log (the journal's text) must not say "remove" for the first pad at any point.
bluetooth_two_pads_check() {
    local out verdict ubus="unix:path=/run/user/$uid/bus" bt_user=org.ruyaos.Devices1.Bluetooth
    local log="/run/user/$uid/ruya-devices-two-pads.log"
    echo "--- bluetooth (T-334): two pads of one model (ruya-shell's user bus, FakeBluez::with_two_pads)"
    if ! command -v python3 >/dev/null; then
        bad "python3 is needed for the two-pads check"
        return
    fi
    if as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1; then
        bad "org.ruyaos.Devices1 is already on ruya-shell's user bus: the two-pads check needs the name free"
        return
    fi
    out="$(as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" RUYA_DEVICES_FAKE_BLUETOOTH=two-pads bash -c '
        /usr/bin/ruya-devices --session >/dev/null 2>'"$log"' &
        pid=$!
        n=0
        until busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1 || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
        call() { busctl --user --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 '"$bt_user"' "$@"; }
        echo "LIST0 $(call ListDevices)"
        echo "START $(call StartControllerPairing u 0)"
        echo "PAIR $(call Pair sb AA:00:00:00:00:05 false)"
        echo "STOP $(call StopControllerPairing)"
        echo "LIST $(call ListDevices)"
        echo "FORGET $(call Forget s AA:00:00:00:00:05)"
        echo "LIST2 $(call ListDevices)"
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    ' 2>&1)"
    verdict="$(printf '%s' "$out" | python3 -I -c '
import json, sys
rows = {}
for line in sys.stdin.read().splitlines():
    key, _, body = line.partition(" ")
    try:
        rows[key] = json.loads(body)["data"]
    except Exception:
        pass
A, B = "AA:00:00:00:00:04", "AA:00:00:00:00:05"
try:
    before = {d["id"]["data"]: d for d in rows["LIST0"][0]}
    after = {d["id"]["data"]: d for d in rows["LIST"][0]}
    last = {d["id"]["data"]: d for d in rows["LIST2"][0]}
except Exception as err:
    print("unparsable: %r" % (err,)); sys.exit(0)
def flag(table, address, key):
    return table[address][key]["data"]
for d in after.values():
    print("device %s name=%r paired=%s bonded=%s connected=%s" % (
        d["id"]["data"], d["name"]["data"], d["paired"]["data"], d["bonded"]["data"], d["connected"]["data"]))
if set(before) != {A, B} or flag(before, B, "paired") is not False or flag(before, A, "connected") is not True:
    print("wrong: before the pairing A should be connected and B in range, got %r" % (sorted(before),))
elif flag(before, A, "name") != flag(before, B, "name"):
    print("wrong: the two pads should have the same name")
elif rows.get("START") != ["ok"] or rows.get("PAIR") != ["ok"] or rows.get("STOP") != ["ok"]:
    print("wrong: START/PAIR/STOP answered %r / %r / %r" % (rows.get("START"), rows.get("PAIR"), rows.get("STOP")))
elif set(after) != {A, B}:
    print("wrong: after the pairing both pads should be listed, got %r" % (sorted(after),))
elif not all(flag(after, x, k) is True for x in (A, B) for k in ("paired", "bonded")):
    print("wrong: both pads should be paired and bonded")
elif flag(after, A, "connected") is not True:
    print("wrong: the first pad should still be connected")
elif rows.get("FORGET") != ["ok"] or set(last) != {A} or flag(last, A, "connected") is not True:
    print("wrong: Forget of the second pad should leave the first, connected: %r %r" % (rows.get("FORGET"), sorted(last)))
else:
    print("VERDICT ok")
' 2>&1)"
    echo "$verdict"
    case "$verdict" in
    *"VERDICT ok"*) ok "two pads of one name: the second pairs in the window, both paired and bonded, the first stays connected, Forget of the second leaves the first";;
    *) bad "ListDevices/Pair/Forget of the two-pads fake: $verdict $out";;
    esac
    if grep -qF -- "remove AA:00:00:00:00:04" "$log" 2>/dev/null; then
        echo "--- log:"; cat "$log"
        bad "the service's log says it removed the first pad"
    elif grep -qF -- "ruya-devices: remove AA:00:00:00:00:05" "$log" 2>/dev/null; then
        ok "the service's log shows only the second pad removed (forget); the first was never removed"
    else
        echo "--- log:"; cat "$log" 2>/dev/null
        bad "the service's log lacks the removal of the second pad"
    fi
    rm -f "$log"
}

# RUY-422: the service is the gate for the shell's "This is a keyboard. Pair it?" question. A third instance on
# ruya-shell's user bus serves the fake BlueZ with a keyboard in range (RUYA_DEVICES_FAKE_BLUETOOTH=keyboard,
# AA:..:06): Pair without keyboard_confirmed must answer not-confirmed, leave the keyboard unpaired and say so in
# the log; with it the keyboard pairs; a pad (AA:..:02) pairs without it. The VM has no radio, so this covers the
# service's D-Bus signature (sb), the status string and the log line as the image builds them, not a real keyboard.
bluetooth_keyboard_check() {
    local out verdict ubus="unix:path=/run/user/$uid/bus" bt_user=org.ruyaos.Devices1.Bluetooth
    local log="/run/user/$uid/ruya-devices-keyboard.log"
    echo "--- bluetooth (RUY-422): the keyboard gate of Pair (ruya-shell's user bus, FakeBluez::with_keyboard)"
    if ! command -v python3 >/dev/null; then
        bad "python3 is needed for the keyboard-gate check"
        return
    fi
    if as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1; then
        bad "org.ruyaos.Devices1 is already on ruya-shell's user bus: the keyboard-gate check needs the name free"
        return
    fi
    out="$(as_shell env DBUS_SESSION_BUS_ADDRESS="$ubus" RUYA_DEVICES_FAKE_BLUETOOTH=keyboard bash -c '
        /usr/bin/ruya-devices --session >/dev/null 2>'"$log"' &
        pid=$!
        n=0
        until busctl --user status org.ruyaos.Devices1 >/dev/null 2>&1 || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
        call() { busctl --user --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 '"$bt_user"' "$@"; }
        echo "LIST0 $(call ListDevices)"
        echo "PLAIN $(call Pair sb AA:00:00:00:00:06 false)"
        echo "LIST1 $(call ListDevices)"
        echo "CONFIRMED $(call Pair sb AA:00:00:00:00:06 true)"
        echo "LIST2 $(call ListDevices)"
        echo "CONNECT_UNTRUSTED $(call Connect s AA:00:00:00:00:07)"
        echo "CONNECT_CONFIRMED $(call Connect s AA:00:00:00:00:06)"
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    ' 2>&1)"
    verdict="$(printf '%s' "$out" | python3 -I -c '
import json, sys
rows = {}
for line in sys.stdin.read().splitlines():
    key, _, body = line.partition(" ")
    try:
        rows[key] = json.loads(body)["data"]
    except Exception:
        pass
K = "AA:00:00:00:00:06"
try:
    first = {d["id"]["data"]: d for d in rows["LIST0"][0]}
    refused = {d["id"]["data"]: d for d in rows["LIST1"][0]}
    done = {d["id"]["data"]: d for d in rows["LIST2"][0]}
except Exception as err:
    print("unparsable: %r" % (err,)); sys.exit(0)
if K not in first or first[K]["keyboard"]["data"] is not True or first[K]["paired"]["data"] is not False:
    print("wrong: the keyboard should be listed, flagged keyboard and not paired")
elif rows.get("PLAIN") != ["not-confirmed"]:
    print("wrong: Pair without the confirmation answered %r" % (rows.get("PLAIN"),))
elif K not in refused or refused[K]["paired"]["data"] is not False:
    print("wrong: the refused keyboard must stay unpaired")
elif rows.get("CONFIRMED") != ["ok"] or K not in done or done[K]["paired"]["data"] is not True:
    print("wrong: Pair with the confirmation answered %r" % (rows.get("CONFIRMED"),))
elif rows.get("CONNECT_UNTRUSTED") != ["not-confirmed"]:
    print("wrong: Connect of a bonded, untrusted keyboard answered %r" % (rows.get("CONNECT_UNTRUSTED"),))
elif rows.get("CONNECT_CONFIRMED") != ["ok"]:
    print("wrong: Connect of the keyboard confirmed through Pair answered %r" % (rows.get("CONNECT_CONFIRMED"),))
else:
    print("VERDICT ok")
' 2>&1)"
    echo "$verdict"
    case "$verdict" in
    *"VERDICT ok"*) ok "Pair of a keyboard: not-confirmed without keyboard_confirmed (still unpaired), ok with it; Connect (RUY-444): not-confirmed for a bonded untrusted keyboard, ok once trusted through Pair";;
    *) bad "Pair of the keyboard fake: $verdict $out";;
    esac
    if grep -qF -- "refused to pair AA:00:00:00:00:06" "$log" 2>/dev/null; then
        ok "the service's log says it refused to pair the unconfirmed keyboard"
    else
        echo "--- log:"; cat "$log" 2>/dev/null
        bad "the service's log lacks the refusal of the unconfirmed keyboard"
    fi
    if grep -qF -- "refused to connect AA:00:00:00:00:07" "$log" 2>/dev/null; then
        ok "the service's log says it refused to connect the untrusted keyboard"
    else
        echo "--- log:"; cat "$log" 2>/dev/null
        bad "the service's log lacks the refusal to connect the untrusted keyboard"
    fi
    rm -f "$log"
}

# T-196: Devices1.Storage.GetSystemUsage, the console's own storage. Compares the filesystem numbers
# with `stat -f /var`, waits for the first background measurement, checks that the parts add up,
# and that installing an app (a signed 80 MB test repository through the Store) makes apps_bytes
# grow and sends SystemUsageChanged. SKIP_APPS_GROWTH=1 leaves the install out.
stor=org.ruyaos.Devices1.Storage
store_svc=org.ruyaos.Store1
store_path=/org/ruyaos/Store1
usage_work=/var/lib/ruya-devices-usage-test
usage_remote=ruyaos-usage-test
usage_app=org.ruyaos.UsageTestApp
usage_rt=org.ruyaos.UsageTestRuntime

# usage_key <key>: one number out of `busctl call ... GetSystemUsage` (prints -2 when it cannot be read).
usage_key() {
    local line num
    line="$(busctl --system call "$svc" "$path" "$stor" GetSystemUsage 2>/dev/null)" || { echo -2; return; }
    num="$(echo "$line" | grep -o "\"$1\" x -\?[0-9]*" | head -1 | awk '{print $3}')"
    echo "${num:--2}"
}

usage_build_repo() {
    rm -rf "$usage_work"; mkdir -p "$usage_work/gpg" "$usage_work/rt/usr/share/ruya-test" "$usage_work/app/files/bin" "$usage_work/rt/files" "$usage_work/rt/var" "$usage_work/app/var"
    chmod 700 "$usage_work/gpg"
    gpg --homedir "$usage_work/gpg" --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "ruya-devices-usage-test <test@example.org>" default default never >/dev/null 2>&1 || return 1
    local key
    key="$(gpg --homedir "$usage_work/gpg" --list-keys --with-colons | awk -F: '/^pub/ {k=$5} END {print k}')"
    echo hello > "$usage_work/rt/usr/share/ruya-test/hello"
    head -c 80000000 /dev/urandom > "$usage_work/app/files/payload.bin"   # incompressible: apps_bytes must grow by about this
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$usage_rt" "$usage_rt" "$usage_rt" > "$usage_work/rt/metadata"
    printf '#!/bin/sh\necho hello\n' > "$usage_work/app/files/bin/hello"; chmod 755 "$usage_work/app/files/bin/hello"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=hello\n' "$usage_app" "$usage_rt" "$usage_rt" > "$usage_work/app/metadata"
    local sign="--gpg-sign=$key --gpg-homedir=$usage_work/gpg"
    flatpak build-export --runtime $sign "$usage_work/repo" "$usage_work/rt" stable || return 1
    flatpak build-finish --command=hello "$usage_work/app" || return 1
    flatpak build-export $sign "$usage_work/repo" "$usage_work/app" stable || return 1
    flatpak build-update-repo $sign "$usage_work/repo" >/dev/null 2>&1
    {
        printf '[Flatpak Repo]\nTitle=Usage check\nUrl=file://%s/repo\n' "$usage_work"
        printf 'GPGKey=%s\n' "$(gpg --homedir "$usage_work/gpg" --export "$key" | base64 -w0)"
    } > "$usage_work/test.flatpakrepo"
}

usage_clean() {
    flatpak uninstall --system -y "$usage_app" "$usage_rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$usage_remote" >/dev/null 2>&1
    rm -rf "$usage_work"
}

storage_usage_check() {
    echo "--- storage usage (T-196): GetSystemUsage"
    local raw total free apps data system n sum du_apps d mon before after out s_blocks s_unit s_avail s_total s_free tol
    raw="$(busctl --system call "$svc" "$path" "$stor" GetSystemUsage)"
    echo "GetSystemUsage: $raw"
    case "$raw" in 'a{sv} 5 '*) ok "GetSystemUsage answers five keys";; *) bad "GetSystemUsage did not answer five keys"; return;; esac
    total="$(usage_key total_bytes)"; free="$(usage_key free_bytes)"
    read -r s_blocks s_unit s_avail <<STATEOF
$(stat -f -c '%b %S %a' /var)
STATEOF
    s_total=$((s_blocks * s_unit)); s_free=$((s_avail * s_unit)); tol=$((s_total / 100))
    echo "service: total=$total free=$free; stat -f /var: total=$s_total free=$s_free (tolerance $tol)"
    if [ "$total" -ge 0 ] && [ "$((total - s_total))" -le "$tol" ] && [ "$((s_total - total))" -le "$tol" ]; then ok "total_bytes matches stat -f /var within 1 %"; else bad "total_bytes $total vs stat -f $s_total"; fi
    if [ "$free" -ge 0 ] && [ "$((free - s_free))" -le "$tol" ] && [ "$((s_free - free))" -le "$tol" ]; then ok "free_bytes matches stat -f /var within 1 % of the disk"; else bad "free_bytes $free vs stat -f $s_free"; fi

    # The first measurement runs in the background (the call never waits for it): -1 until done.
    n=0
    until [ "$(usage_key apps_bytes)" -ge 0 ] || [ "$n" -ge 120 ]; do sleep 1; n=$((n + 1)); done
    apps="$(usage_key apps_bytes)"; data="$(usage_key data_bytes)"; system="$(usage_key system_bytes)"
    total="$(usage_key total_bytes)"; free="$(usage_key free_bytes)"
    echo "measured after about $n s: apps=$apps data=$data system=$system"
    if [ "$apps" -ge 0 ]; then ok "apps_bytes was measured"; else bad "apps_bytes=$apps after $n s"; return; fi
    # The profile homes are 0700 users' directories the service (ruya-shell) cannot read: unknown, not a small number.
    if [ "$data" = -1 ]; then ok "data_bytes is -1 (the profile homes are not readable by the service)"; elif [ "$data" -ge 0 ]; then ok "data_bytes is known ($data): the homes were readable"; else bad "data_bytes=$data"; fi
    if [ "$system" -ge 0 ]; then ok "system_bytes is not negative"; else bad "system_bytes=$system"; fi
    sum=$((free + apps + system)); [ "$data" -gt 0 ] && sum=$((sum + data))
    if [ "$system" = 0 ] || { [ "$sum" -le "$total" ] && [ "$((total - sum))" -le "$((total / 100))" ]; }; then ok "free + apps + data + system add up to total (system is the rest)"; else bad "free+apps+data+system=$sum vs total=$total (data=$data)"; fi
    du_apps="$(du -s --block-size=1 -x /var/lib/flatpak 2>/dev/null | awk '{print $1}')"
    echo "du -sx /var/lib/flatpak (hard links counted once): $du_apps"
    if [ -n "$du_apps" ] && [ "$du_apps" -gt 0 ]; then
        # The service caches apps_bytes (60 s) and a Flathub appstream refresh can land after its first
        # walk (0.0.48-lead: 7.9 MB against 175 MB): ask again for a while before calling it a mismatch.
        n=0
        while :; do
            d=$((apps - du_apps)); [ "$d" -lt 0 ] && d=$((0 - d))
            if [ "$d" -le "$((du_apps / 20 + 4000000))" ] || [ "$n" -ge 8 ]; then break; fi
            sleep 20; n=$((n + 1)); apps="$(usage_key apps_bytes)"
            du_apps="$(du -s --block-size=1 -x /var/lib/flatpak 2>/dev/null | awk '{print $1}')"
        done
        if [ "$d" -le "$((du_apps / 20 + 4000000))" ]; then ok "apps_bytes is close to du of /var/lib/flatpak"; else bad "apps_bytes $apps vs du $du_apps"; fi
    fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$stor" GetSystemUsage 2>&1)"; then
        bad "nobody could call GetSystemUsage: $out"
    else
        echo "$out"; ok "GetSystemUsage from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after GetSystemUsage" || bad "ruya-devices not active"

    if [ "${SKIP_APPS_GROWTH:-0}" = 1 ]; then echo "(SKIP_APPS_GROWTH=1: no install)"; return; fi
    echo "--- storage usage (T-196): apps_bytes grows after an install"
    usage_clean
    if usage_build_repo; then ok "test repository built"; else bad "cannot build the test repository"; usage_clean; return; fi
    busctl --system --json=short monitor "$svc" > "$usage_work/signals.log" 2>&1 &
    mon=$!
    sleep 1
    before="$(usage_key apps_bytes)"
    out="$(busctl --system call "$store_svc" "$store_path" "$store_svc" AddRemote ss "$usage_remote" "file://$usage_work/test.flatpakrepo")"
    case "$out" in 's "ok"') ok "test remote added";; *) bad "AddRemote: $out"; kill "$mon" 2>/dev/null; usage_clean; return;; esac
    n=0
    until as_shell busctl --system call "$store_svc" "$store_path" "$store_svc" Search sa{sv} "UsageTestApp" 0 | grep -q "$usage_app" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    out="$(as_shell busctl --system call "$store_svc" "$store_path" "$store_svc" Install s "$usage_app")"
    echo "Install: $out"
    n=0
    until flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$usage_app" || [ "$n" -ge 180 ]; do sleep 1; n=$((n + 1)); done
    if flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$usage_app"; then ok "the test app is installed (after about $n s)"; else bad "the test app did not install"; fi
    # InstalledChanged -> the service measures again and sends SystemUsageChanged.
    n=0
    until [ "$(usage_key apps_bytes)" -gt "$((before + 40000000))" ] || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    after="$(usage_key apps_bytes)"
    echo "apps_bytes before=$before after=$after (about $n s after the install)"
    if [ "$after" -gt "$((before + 40000000))" ]; then ok "apps_bytes grew by $((after - before)) bytes after the install"; else bad "apps_bytes did not grow (before $before, after $after)"; fi
    kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    if grep -q '"member":"SystemUsageChanged"' "$usage_work/signals.log"; then ok "SystemUsageChanged was sent"; else bad "no SystemUsageChanged was seen"; fi
    usage_clean
}

# T-200: the cpu entry of ListSensors (its value), printed; nothing when there is none.
thermal_cpu_value() {
    busctl --system --json=short call "$svc" "$path" "$therm" ListSensors \
        | sed 's/},{"class"/}\n{"class"/g' \
        | sed -n -E 's/.*"class":\{"type":"s","data":"cpu"\}.*"value":\{"type":"d","data":(-?[0-9.]+([eE][+-]?[0-9]+)?)\}.*/\1/p' \
        | awk '{printf "%.1f", $1}'      # sd-json prints 40.0 as 40, or as 4.00e+01
}

# The processor temperature the kernel shows, in degrees (empty when the VM has none).
thermal_sys_cpu() {
    local h name f z
    for h in /sys/class/hwmon/hwmon*; do
        name="$(cat "$h/name" 2>/dev/null)"
        case "$name" in
        coretemp)
            for f in "$h"/temp*_label; do
                case "$(cat "$f" 2>/dev/null)" in "Package id"*) awk '{printf "%.1f", $1 / 1000}' "${f%_label}_input"; return;; esac
            done;;
        k10temp) awk '{printf "%.1f", $1 / 1000}' "$h/temp1_input"; return;;
        esac
    done
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] && { awk '{printf "%.1f", $1 / 1000}' "$z/temp"; return; }
    done
}

thermal_level() { busctl --system get-property "$svc" "$path" "$therm" Level; }

# T-226: Devices1.System.GetInfo against /proc, /sys and the usual tools inside the guest, and
# Devices1.Storage.SaveReport's refusals (and, with a mounted USB stick, a real save).
sysi=org.ruyaos.Devices1.System

# sys_key <key>: the value of one scalar key of GetInfo (strings without their quotes), "" when absent.
sys_key() {
    local line
    line="$(busctl --system call "$svc" "$path" "$sysi" GetInfo 2>/dev/null)" || return
    echo "$line" | grep -o "\"$1\" [stb] \(\"[^\"]*\"\|[0-9a-z]*\)" | head -1 | sed -e 's/^"[^"]*" [stb] //' -e 's/^"//' -e 's/"$//'
}

# near <a> <b> <percent>: a is within percent of b.
near() { awk -v a="$1" -v b="$2" -v p="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= b * p / 100) }'; }

sysinfo_check() {
    echo "--- system information (T-226): Devices1.System.GetInfo against /proc and /sys"
    local raw v want n slot sizes id mp vols out s
    raw="$(busctl --system call "$svc" "$path" "$sysi" GetInfo)"
    echo "GetInfo: $(echo "$raw" | cut -c1-300)"
    case "$raw" in 'a{sv} '[1-9]*) ok "GetInfo answers a dictionary";; *) bad "GetInfo did not answer a non-empty a{sv}"; return;; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$sysi" GetInfo 2>&1)"; then
        bad "nobody could call GetInfo: $out"
    else
        echo "$out"; ok "GetInfo from nobody refused"
    fi

    # Console
    v="$(sys_key console.kernel)"; [ "$v" = "$(uname -r)" ] && ok "console.kernel is uname -r ($v)" || bad "console.kernel '$v' vs $(uname -r)"
    v="$(sys_key console.version)"; want="$(cat /usr/lib/ruyaos/version)"; [ "$v" = "$want" ] && ok "console.version is /usr/lib/ruyaos/version ($v)" || bad "console.version '$v' vs '$want'"
    v="$(sys_key console.firmware)"
    if [ -d /sys/firmware/efi ]; then want=uefi; else want=bios; fi
    [ "$v" = "$want" ] && ok "console.firmware is $want" || bad "console.firmware '$v' vs $want"
    if [ -d /sys/firmware/efi ] && [ -r /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]; then
        want="$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c | tr -d ' ')"
        v="$(sys_key console.secure_boot)"
        if { [ "$want" = 1 ] && [ "$v" = true ]; } || { [ "$want" = 0 ] && [ "$v" = false ]; }; then ok "console.secure_boot matches the EFI variable ($v)"; else bad "console.secure_boot '$v' vs $want"; fi
    fi
    v="$(sys_key console.uptime_s)"; want="$(cut -d. -f1 /proc/uptime)"
    if [ $(( want - ${v:-0} )) -le 5 ] && [ $(( ${v:-0} - want )) -le 5 ]; then ok "console.uptime_s ($v) follows /proc/uptime ($want)"; else bad "console.uptime_s '$v' vs $want"; fi
    sleep 2
    n="$(sys_key console.uptime_s)"
    [ "${n:-0}" -ge $(( ${v:-0} + 1 )) ] && ok "the live value moves between calls ($v -> $n)" || bad "console.uptime_s did not move ($v -> $n)"

    # Processor
    want="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
    v="$(sys_key cpu.model)"; [ "$v" = "$want" ] && ok "cpu.model is '$v'" || bad "cpu.model '$v' vs '$want'"
    want="$(grep -c '^processor' /proc/cpuinfo)"
    v="$(sys_key cpu.threads)"; [ "$v" = "$want" ] && ok "cpu.threads is $v" || bad "cpu.threads '$v' vs $want"
    if command -v lscpu >/dev/null; then
        want="$(lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l)"
        v="$(sys_key cpu.cores)"; [ "$v" = "$want" ] && ok "cpu.cores is $v (lscpu)" || bad "cpu.cores '$v' vs $want (lscpu)"
    fi

    # Memory
    want=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))
    v="$(sys_key memory.total_bytes)"; [ "$v" = "$want" ] && ok "memory.total_bytes matches MemTotal ($v)" || bad "memory.total_bytes '$v' vs $want"
    want=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) * 1024 ))
    v="$(sys_key memory.available_bytes)"
    if near "${v:-0}" "$want" 5; then ok "memory.available_bytes ($v) is within 5 % of MemAvailable ($want)"; else bad "memory.available_bytes '$v' vs $want"; fi
    # used + available = total within one GetInfo reply (two calls see memory move in between).
    snap="$(busctl --system call "$svc" "$path" "$sysi" GetInfo 2>/dev/null)"
    snap_key() { echo "$snap" | grep -o "\"$1\" [stb] [0-9]*" | head -1 | sed 's/^"[^"]*" [stb] //'; }
    n="$(snap_key memory.used_bytes)"; a="$(snap_key memory.available_bytes)"; t="$(snap_key memory.total_bytes)"
    [ -n "$t" ] && [ $(( ${n:-0} + ${a:-0} )) = "$t" ] && ok "used + available = total" || bad "used $n + available $a is not the total $t"
    want=$(( $(awk '/^SwapTotal:/ {print $2}' /proc/meminfo) * 1024 ))
    v="$(sys_key memory.swap_total_bytes)"
    if [ "$want" = 0 ]; then
        [ -z "$v" ] && ok "no swap: memory.swap_total_bytes is absent, not 0" || bad "memory.swap_total_bytes '$v' on a machine without swap"
    else
        [ "$v" = "$want" ] && ok "memory.swap_total_bytes matches SwapTotal ($v)" || bad "memory.swap_total_bytes '$v' vs $want"
    fi

    # Graphics: the first cardN that has a PCI device (virtio-gpu is card1 when simpledrm took card0).
    gcard=""; for c in /sys/class/drm/card[0-9]*; do [ -e "$c/device/vendor" ] && { gcard="$c"; break; }; done
    if [ -n "$gcard" ]; then
        want="$(sed 's/^0x//' ${gcard}/device/vendor):$(sed 's/^0x//' ${gcard}/device/device)"
        v="$(sys_key graphics.pci_id)"; [ "$v" = "$want" ] && ok "graphics.pci_id is $v" || bad "graphics.pci_id '$v' vs $want"
        want="$(basename "$(readlink -f ${gcard}/device/driver 2>/dev/null)")"
        v="$(sys_key graphics.driver)"; [ "$v" = "$want" ] && ok "graphics.driver is $v" || bad "graphics.driver '$v' vs '$want'"
        if command -v lspci >/dev/null; then
            slot="$(basename "$(readlink -f ${gcard}/device)")"
            echo "compare by eye: lspci: $(lspci -s "${slot#0000:}" 2>/dev/null) / graphics.vendor+model: $(sys_key graphics.vendor) $(sys_key graphics.model)"
        fi
    else
        [ -z "$(sys_key graphics.model)" ] && ok "no GPU in /sys: graphics.model is absent" || bad "graphics.model without a GPU"
    fi

    # Storage: every internal disk lsblk knows is a record (its size appears in the reply)
    sizes="$(lsblk -dbn -o SIZE,RM,TRAN,TYPE 2>/dev/null | awk '$4 == "disk" && $2 == 0 && $3 != "usb" {print $1}')"
    vols="$(busctl --system call "$svc" "$path" "$sysi" GetInfo)"
    n=0
    for s in $sizes; do
        if echo "$vols" | grep -q "\"size_bytes\" t $s"; then n=$((n + 1)); else bad "internal disk of $s bytes is not in storage.drives"; fi
    done
    if [ -z "$sizes" ]; then echo "lsblk lists no internal disk"; else ok "$n internal disk(s) found in storage.drives (lsblk sizes)"; fi

    # Network
    want="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    v="$(sys_key network.interface)"
    if [ -n "$want" ]; then
        [ "$v" = "$want" ] && ok "network.interface is the default route's ($v)" || bad "network.interface '$v' vs $want"
        want="$(cat "/sys/class/net/$want/address")"
        v="$(sys_key network.mac)"; [ "$v" = "$want" ] && ok "network.mac matches /sys ($v)" || bad "network.mac '$v' vs $want"
    else
        [ -z "$v" ] && ok "no default route: network.interface is absent" || bad "network.interface '$v' without a default route"
    fi

    # Bluetooth: none in the VM
    if ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
        echo "bluetooth.chipset: $(sys_key bluetooth.chipset) / address: $(sys_key bluetooth.address)"
    else
        [ -z "$(sys_key bluetooth.chipset)" ] && ok "no Bluetooth adapter: bluetooth.chipset is absent" || bad "bluetooth.chipset without an adapter"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the System calls" || bad "ruya-devices not active"

    echo "--- report to USB (T-226): Devices1.Storage.SaveReport"
    out="$(busctl --system call "$svc" "$path" "$stor" SaveReport 'sa{ss}' "/no/such/volume" 1 "RuyaOS-system-report.txt" "x")"
    [ "$out" = 'ss "unknown-volume" ""' ] && ok "an unknown volume is refused" || bad "SaveReport unknown volume: $out"
    for name in "../evil.txt" "RuyaOS-x.sh" "autorun.inf" "RuyaOS-.txt" "/etc/passwd"; do
        out="$(busctl --system call "$svc" "$path" "$stor" SaveReport 'sa{ss}' "/no/such/volume" 1 "$name" "x")"
        [ "$out" = 'ss "invalid" ""' ] && ok "file name '$name' is invalid" || bad "SaveReport '$name': $out"
    done
    out="$(busctl --system call "$svc" "$path" "$stor" SaveReport 'sa{ss}' "/no/such/volume" 0)"
    [ "$out" = 'ss "invalid" ""' ] && ok "no file is invalid" || bad "SaveReport without files: $out"
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$stor" SaveReport 'sa{ss}' "/x" 1 "RuyaOS-a.txt" "x" 2>&1)"; then
        bad "nobody could call SaveReport: $out"
    else
        echo "$out"; ok "SaveReport from nobody refused"
    fi
    # The first REMOVABLE, mounted, writable volume, not the first listed (an internal volume may come
    # first). T-296: the reply is read as JSON and each volume by its keys; the old split at the "drive"
    # key broke when the dictionary's key order changed (the service sorts them, a BTreeMap).
    id=""; mp=""
    if pick="$(busctl --system --json=short call "$svc" "$path" "$stor" ListVolumes | pick_removable_volume)"; then
        { IFS= read -r id; IFS= read -r mp; } <<< "$pick"
    else
        bad "ListVolumes did not answer parsable JSON (busctl --json=short | python3)"
    fi
    if [ -n "$id" ]; then
        out="$(busctl --system call "$svc" "$path" "$stor" SaveReport 'sa{ss}' "$id" 2 "RuyaOS-system-report.txt" "report text" "RuyaOS-system-report.json" "{}")"
        echo "SaveReport on $id ($mp): $out"
        case "$out" in
            'ss "ok" '*)
                [ "$(cat "$mp/RuyaOS-system-report.txt" 2>/dev/null)" = "report text" ] && ok "the report text is on the stick" || bad "no report text at $mp"
                [ -f "$mp/RuyaOS-system-report.json" ] && ok "the JSON is on the stick" || bad "no JSON at $mp"
                # RUY-42: ListFiles and ReadFile (importing a controller profile) on the same stick.
                out="$(busctl --system call "$svc" "$path" "$stor" ListFiles ss "$id" .json)"
                case "$out" in *'"ok"'*'"RuyaOS-system-report.json"'*) ok "ListFiles lists the JSON file";; *) bad "ListFiles: $out";; esac
                case "$out" in *'RuyaOS-system-report.txt'*) bad "ListFiles .json listed the .txt";; *) ok "ListFiles keeps to the suffix";; esac
                out="$(busctl --system call "$svc" "$path" "$stor" ReadFile ssu "$id" RuyaOS-system-report.json 65536)"
                [ "$out" = 'ss "ok" "{}"' ] && ok "ReadFile reads it back" || bad "ReadFile: $out"
                out="$(busctl --system call "$svc" "$path" "$stor" ReadFile ssu "$id" RuyaOS-system-report.json 1)"
                [ "$out" = 'ss "too-large" ""' ] && ok "ReadFile refuses a file over max_bytes unread" || bad "ReadFile cap: $out"
                ln -sf /etc/passwd "$mp/vm-check-link.json" 2>/dev/null
                if [ -L "$mp/vm-check-link.json" ]; then
                    out="$(busctl --system call "$svc" "$path" "$stor" ReadFile ssu "$id" vm-check-link.json 65536)"
                    [ "$out" = 'ss "not-found" ""' ] && ok "ReadFile never follows a symlink" || bad "ReadFile of a symlink: $out"
                    rm -f "$mp/vm-check-link.json"
                else
                    echo "SKIP: the stick's filesystem has no symlinks (vfat/exfat); ReadFile's O_NOFOLLOW is tested in Rust only"
                fi
                out="$(busctl --system call "$svc" "$path" "$stor" ReadFile ssu "$id" ../etc/passwd 65536)"
                [ "$out" = 'ss "invalid" ""' ] && ok "ReadFile refuses a path" || bad "ReadFile ../etc/passwd: $out"
                rm -f "$mp/RuyaOS-system-report.txt" "$mp/RuyaOS-system-report.json";;
            *) bad "SaveReport on a mounted stick answered $out";;
        esac
    else
        echo "SKIP: no mounted removable volume in the VM (attach a USB stick, see the T-226 Outcome)"
    fi
}

# T-451: Devices1.System.GetPerformance. perf_get <json> <metric> state|value reads one entry of a
# `busctl --json=short` reply ({"data":[{"cpu_percent":["supported",12.5],...}]}).
perf_call() { busctl --system --json=short call "$svc" "$path" "$sysi" GetPerformance; }
perf_get() {
    python3 -c 'import json,sys; d=json.loads(sys.argv[1])["data"][0]; e=d.get(sys.argv[2]); print("" if e is None else (e[0] if sys.argv[3]=="state" else e[1]))' "$1" "$2" "$3" 2>/dev/null
}
performance_check() {
    echo "--- performance (T-451): Devices1.System.GetPerformance"
    local first second a b m v st want total avail sensor
    # The service keeps the reading before for 10 s: wait that out, so this call is a first reading.
    sleep 11
    if ! first="$(perf_call)"; then bad "GetPerformance failed: $first"; return; fi
    echo "first: $first"
    case "$first" in *'"type":"a{s(sd)}"'*) ok "GetPerformance answers a{s(sd)}";; *) bad "GetPerformance's type is not a{s(sd)}";; esac
    for m in cpu_percent ram_used ram_total gpu_percent vram_used vram_total cpu_temp gpu_temp power_w; do
        st="$(perf_get "$first" "$m" state)"
        case "$st" in supported|unsupported|unavailable|stale) ok "$m has the state $st";; *) bad "$m: state '$st'";; esac
    done
    st="$(perf_get "$first" cpu_percent state)"
    [ "$st" = unavailable ] && ok "cpu_percent is unavailable at a first reading (a rate)" || bad "cpu_percent at a first reading: $st"
    sleep 1
    second="$(perf_call)"
    st="$(perf_get "$second" cpu_percent state)"; v="$(perf_get "$second" cpu_percent value)"
    if [ "$st" = supported ] && awk -v v="$v" 'BEGIN { exit !(v >= 0 && v <= 100) }'; then ok "cpu_percent is supported at the next reading ($v %)"; else bad "cpu_percent at the next reading: $st $v"; fi
    total=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))
    avail=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) * 1024 ))
    v="$(perf_get "$second" ram_total value)"
    awk -v v="$v" -v t="$total" 'BEGIN { exit !(v == t) }' && ok "ram_total is MemTotal ($total)" || bad "ram_total $v vs $total"
    v="$(perf_get "$second" ram_used value)"
    # Doubles may come as 1.39e+09: whole bytes through awk.
    if near "$(awk -v v="$v" 'BEGIN { printf "%.0f", v }')" "$((total - avail))" 5; then ok "ram_used ($v) is within 5 % of MemTotal - MemAvailable"; else bad "ram_used $v vs $((total - avail))"; fi
    a="$(perf_call)"; b="$(perf_call)"
    [ "$a" = "$b" ] && ok "two calls inside 250 ms answer the same" || bad "two quick calls differ: $a / $b"
    sensor=0
    grep -qsxE 'coretemp|k10temp|zenpower' /sys/class/hwmon/hwmon*/name && sensor=1
    grep -qsx x86_pkg_temp /sys/class/thermal/thermal_zone*/type && sensor=1
    st="$(perf_get "$second" cpu_temp state)"
    if [ "$sensor" = 1 ]; then want=supported; else want=unsupported; fi
    [ "$st" = "$want" ] && ok "cpu_temp is $st (processor sensor in /sys: $sensor)" || bad "cpu_temp is $st, want $want"
    for m in gpu_percent vram_used vram_total gpu_temp power_w; do
        st="$(perf_get "$second" "$m" state)"
        [ "$st" = unsupported ] && ok "$m is unsupported here (virtio-gpu, the service is not root)" || bad "$m is $st, want unsupported in QEMU"
    done
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$sysi" GetPerformance 2>&1)"; then
        bad "nobody could call GetPerformance: $out"
    else
        echo "$out"; ok "GetPerformance from nobody refused"
    fi
}

# T-454: Devices1.Display.GetBrightness / SetBrightness. QEMU's virtual GPU has no backlight device, so the
# service must answer (su) "unsupported" 0 and refuse a set with "unsupported" (a laptop panel is by hand, see the T-454 Outcome).
brightness_check() {
    echo "--- brightness (T-454): Devices1.Display.GetBrightness"
    local disp=org.ruyaos.Devices1.Display out
    if ls /sys/class/backlight/* >/dev/null 2>&1; then
        echo "WARN: this machine has a backlight device (/sys/class/backlight); the unsupported check applies to QEMU"
        out="$(busctl --system call "$svc" "$path" "$disp" GetBrightness)" || { bad "GetBrightness failed: $out"; return; }
        echo "GetBrightness: $out"
        case "$out" in '(su) "supported" '*) ok "GetBrightness is supported with a backlight";; *) bad "a backlight is there but GetBrightness says: $out";; esac
        return
    fi
    if ! out="$(busctl --system call "$svc" "$path" "$disp" GetBrightness)"; then bad "GetBrightness failed: $out"; return; fi
    echo "GetBrightness: $out"
    case "$out" in '(su) "unsupported" 0') ok "Brightness is unsupported in QEMU (no backlight device)";; *) bad "Brightness in QEMU: $out, want (su) \"unsupported\" 0";; esac
    out="$(busctl --system call "$svc" "$path" "$disp" SetBrightness u 50)" || { bad "SetBrightness failed: $out"; return; }
    case "$out" in 's "unsupported"') ok "SetBrightness 50 is refused as unsupported";; *) bad "SetBrightness 50 answered: $out";; esac
    out="$(busctl --system call "$svc" "$path" "$disp" SetBrightness u 0)" || { bad "SetBrightness 0 failed: $out"; return; }
    case "$out" in 's "invalid"') ok "SetBrightness 0 is invalid";; *) bad "SetBrightness 0 answered: $out";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$disp" GetBrightness 2>&1)"; then
        bad "nobody could call GetBrightness: $out"
    else
        echo "$out"; ok "GetBrightness from nobody refused"
    fi
}

# T-296: the first removable, mounted, writable volume of a `busctl --json=short call ... ListVolumes`
# reply on stdin, printed as two lines (the id, then the mount point); nothing when there is none, exit 1
# when the input is not that JSON. {"type":"aa{sv}","data":[[{"id":{"type":"s","data":".."}, ...}, ...]]}
volume_pick_py='
import json, sys
vols = json.load(sys.stdin)["data"][0]
def get(v, k):
    return v.get(k, {}).get("data")
for v in vols:
    if get(v, "removable") is True and get(v, "mounted") is True and get(v, "read_only") is False:
        if get(v, "id") and get(v, "mount_point"):
            print(get(v, "id"))
            print(get(v, "mount_point"))
            break
'
pick_removable_volume() { python3 -c "$volume_pick_py"; }

thermal_check() {
    echo "--- thermal (T-200): Devices1.Thermal"
    local raw lvl svc_cpu sys_cpu d out
    raw="$(busctl --system call "$svc" "$path" "$therm" ListSensors)"
    echo "ListSensors: $raw" | cut -c1-300
    case "$raw" in 'aa{sv} '*) ok "ListSensors answers an array of dictionaries";; *) bad "ListSensors did not answer aa{sv}"; return;; esac
    lvl="$(thermal_level)"; echo "Level: $lvl"
    case "$lvl" in 's "normal"') ok "Level is normal";; 's "warm"'|'s "hot"'|'s "critical"') bad "Level is $lvl on an idle VM";; *) bad "Level did not answer a level: $lvl";; esac
    sys_cpu="$(thermal_sys_cpu)"; svc_cpu="$(thermal_cpu_value)"
    echo "processor: service='$svc_cpu' sysfs='$sys_cpu'"
    if [ -z "$sys_cpu" ]; then
        if [ -z "$svc_cpu" ]; then ok "no processor sensor in /sys (QEMU): no cpu entry (the list may be empty)"; else bad "a cpu entry ($svc_cpu) without a sensor in /sys"; fi
    elif [ -z "$svc_cpu" ]; then
        bad "/sys has a processor sensor ($sys_cpu) but ListSensors has no cpu entry"
    else
        d="$(awk -v a="$svc_cpu" -v b="$sys_cpu" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d <= 3) ? "ok" : "far" }')"
        if [ "$d" = ok ]; then ok "the cpu entry ($svc_cpu) is within 3 degrees of /sys ($sys_cpu)"; else bad "the cpu entry $svc_cpu is not within 3 degrees of /sys $sys_cpu"; fi
    fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$therm" ListSensors 2>&1)"; then
        bad "nobody could call ListSensors: $out"
    else
        echo "$out"; ok "ListSensors from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the thermal calls" || bad "ruya-devices not active"
}

# Waits up to $2 seconds for Level to read $1; prints how long it took.
thermal_wait_level() {
    local n=0
    while [ "$n" -le "$2" ]; do
        [ "$(thermal_level)" = "s \"$1\"" ] && { echo "$n"; return 0; }
        sleep 1; n=$((n + 1))
    done
    return 1
}

# T-200: the policy over D-Bus, with a made-up sysfs. /sys cannot be replaced, so the service is
# pointed at a tree under /var/lib (its unit has a private /tmp) through RUYA_THERMAL_SYSFS.
thermal_fake_check() {
    echo "--- thermal (T-200): a made-up sysfs walks a sensor through the levels"
    local root=/var/lib/ruyaos-fakesys mon took d signals=/var/tmp/thermal-signals.log
    local hw="$root/class/hwmon/hwmon9"
    rm -rf "$root"; mkdir -p "$hw"
    echo coretemp > "$hw/name"; echo 'Package id 0' > "$hw/temp1_label"
    echo 40000 > "$hw/temp1_input"; echo 100000 > "$hw/temp1_crit"
    echo 1820 > "$hw/fan1_input"
    chmod -R a+rX "$root"
    as_shell systemctl --user set-environment RUYA_THERMAL_SYSFS="$root"
    as_shell systemctl --user restart ruya-devices
    d=0; until [ "$(thermal_cpu_value)" = 40.0 ] || [ "$d" -ge 30 ]; do sleep 1; d=$((d + 1)); done
    if [ "$(thermal_cpu_value)" = 40.0 ]; then ok "the service reads the made-up tree (cpu 40.0)"; else bad "the service did not pick up RUYA_THERMAL_SYSFS (cpu='$(thermal_cpu_value)')"; fi
    if [ "$(thermal_level)" = 's "normal"' ]; then ok "Level is normal at 40"; else bad "Level at 40: $(thermal_level)"; fi
    busctl --system --json=short monitor "$svc" > "$signals" 2>&1 &
    mon=$!
    sleep 1
    echo 92000 > "$hw/temp1_input"
    if took="$(thermal_wait_level hot 40)"; then ok "Level became hot after about $took s"; else bad "Level did not become hot at 92 ($(thermal_level))"; took=0; fi
    # The 10 s debounce: a reading at 92 for less than that never counts (5 s polls, so at least 9).
    if [ "$took" -ge 9 ]; then ok "not before the debounce ($took s)"; else bad "hot after only $took s: no debounce"; fi
    echo 97000 > "$hw/temp1_input"
    if took="$(thermal_wait_level critical 40)"; then ok "Level became critical after about $took s"; else bad "Level did not become critical at 97 ($(thermal_level))"; fi
    echo 40000 > "$hw/temp1_input"
    if took="$(thermal_wait_level normal 40)"; then ok "Level is normal again after about $took s"; else bad "Level did not return to normal ($(thermal_level))"; fi
    sleep 1
    kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    if grep -q '"member":"LevelChanged"' "$signals"; then ok "LevelChanged was sent"; else bad "no LevelChanged was seen"; fi
    grep -o '"member":"LevelChanged"' "$signals" | wc -l | xargs echo "LevelChanged signals:"
    rm -f "$signals"
    as_shell systemctl --user unset-environment RUYA_THERMAL_SYSFS
    as_shell systemctl --user restart ruya-devices
    rm -rf "$root"
}

# T-213: the time zone. Everything it changes is put back at the end.
time_check() {
    local tm=org.ruyaos.Devices1.Time orig now out profiles active pid want
    echo "--- time zone (T-213): timedated behind Devices1.Time"
    orig="$(timedatectl show -p Timezone --value)"
    echo "timedatectl: $orig"
    now="$(busctl --system call "$svc" "$path" "$tm" GetTimezone)"
    echo "GetTimezone: $now"
    [ "$now" = "s \"$orig\"" ] && ok "GetTimezone matches timedatectl" || bad "GetTimezone differs from timedatectl ($orig)"
    out="$(busctl --system call "$svc" "$path" "$tm" ListTimezones)"
    echo "ListTimezones: $(echo "$out" | wc -w) words"
    echo "$out" | grep -q '"Europe/Istanbul"' && echo "$out" | grep -q '"UTC"' && ok "ListTimezones has Europe/Istanbul and UTC" || bad "ListTimezones misses Europe/Istanbul or UTC"
    out="$(busctl --system get-property "$svc" "$path" "$tm" NtpSynchronised)"
    echo "NtpSynchronised: $out"
    case "$out" in "b true"|"b false") ok "NtpSynchronised is a boolean";; *) bad "NtpSynchronised: $out";; esac

    for bad_name in "Mars/Olympus_Mons" "../../etc/passwd" "" "europe/istanbul"; do
        out="$(busctl --system call "$svc" "$path" "$tm" SetTimezone s "$bad_name")"
        [ "$out" = 's "invalid"' ] && ok "SetTimezone '$bad_name' is invalid" || bad "SetTimezone '$bad_name': $out"
    done
    [ "$(timedatectl show -p Timezone --value)" = "$orig" ] && ok "invalid names changed nothing" || bad "the zone changed after invalid names"

    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$tm" SetTimezone s Asia/Tokyo 2>&1)"; then
        bad "nobody could call SetTimezone: $out"
    else
        echo "$out"; ok "time call from nobody refused"
    fi

    out="$(busctl --system call "$svc" "$path" "$tm" SetTimezone s Asia/Tokyo)"
    [ "$out" = 's "ok"' ] && ok "root SetTimezone Asia/Tokyo is ok" || bad "root SetTimezone: $out"
    [ "$(timedatectl show -p Timezone --value)" = "Asia/Tokyo" ] && ok "timedatectl shows Asia/Tokyo" || bad "timedatectl: $(timedatectl show -p Timezone --value)"
    [ "$(readlink -f /etc/localtime)" = "/usr/share/zoneinfo/Asia/Tokyo" ] && ok "/etc/localtime points at Asia/Tokyo" || bad "/etc/localtime: $(readlink -f /etc/localtime)"
    [ "$(date +%Z)" = "JST" ] && ok "date prints JST" || bad "date prints $(date +%Z)"
    [ "$(busctl --system call "$svc" "$path" "$tm" GetTimezone)" = 's "Asia/Tokyo"' ] && ok "GetTimezone says Asia/Tokyo" || bad "GetTimezone after the set"

    # A zone set from outside (someone runs timedatectl) is followed through timedated's signal.
    timedatectl set-timezone Europe/Istanbul
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(busctl --system call "$svc" "$path" "$tm" GetTimezone)" = 's "Europe/Istanbul"' ] && break
        sleep 0.5
    done
    [ "$(busctl --system call "$svc" "$path" "$tm" GetTimezone)" = 's "Europe/Istanbul"' ] && ok "a zone set by timedatectl shows within 5 s" || bad "GetTimezone did not follow timedatectl"

    # The shell's own call: the caller rule depends on who is signed in. Expected: no profile at all
    # (first-boot setup) ok; nobody signed in forbidden; a signed-in standard profile forbidden; a
    # signed-in admin ok. The signed-in cases only run when the VM happens to be in that state (this
    # check never signs anyone in); the rule itself is time::tests::* on the host.
    plist="$(busctl --system call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles)"
    profiles="$(echo "$plist" | cut -d' ' -f2)"
    active="$(busctl --system get-property org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ActiveProfile | cut -d'"' -f2)"
    role=""
    [ -n "$active" ] && role="$(echo "$plist" | grep -o "\"$active\" \"[^\"]*\" \"[^\"]*\" \"[a-z]*\"" | grep -o '"[a-z]*"$' | tr -d '"')"
    out="$(as_shell busctl --system call "$svc" "$path" "$tm" SetTimezone s Pacific/Auckland 2>&1)"
    echo "profiles: $profiles, active: '$active', role: '$role', the shell's SetTimezone: $out"
    if [ "$profiles" = "0" ]; then want='s "ok"'
    elif [ -z "$active" ]; then want='s "forbidden"'
    elif [ "$role" = "admin" ]; then want='s "ok"'
    elif [ "$role" = "standard" ] || [ "$role" = "guest" ]; then want='s "forbidden"'
    else want="(unknown role '$role')"; fi
    [ "$out" = "$want" ] && ok "the shell's SetTimezone answers $out (profiles $profiles, active '$active', role '$role')" || bad "the shell's SetTimezone: $out, want $want"
    [ "$want" = 's "forbidden"' ] && [ "$(timedatectl show -p Timezone --value)" = "Europe/Istanbul" ] && ok "a forbidden call changed nothing"
    [ -z "$active" ] || [ "$profiles" = "0" ] || echo "note: a profile is signed in; the 'nobody signed in' case was not exercised"

    pid="$(pgrep -u ruya-shell -x ruya-devices | head -1)"
    if [ -n "$pid" ]; then
        polkit_expect org.freedesktop.timedate1.set-timezone "$pid" 0 "polkit allows ruya-devices: timedate1 set-timezone"
        for a in set-time set-ntp set-local-rtc; do
            polkit_expect "org.freedesktop.timedate1.$a" "$pid" 1 "polkit refuses ruya-devices: timedate1 $a"
        done
    else
        bad "no ruya-devices process for the polkit check"
    fi

    timedatectl set-timezone "$orig"
    [ "$(timedatectl show -p Timezone --value)" = "$orig" ] && ok "zone restored to $orig" || bad "could not restore $orig"
}

# T-337: ruya-inputd releases the keys a vanished pad held, and two pads share a key safely.
# Virtual gamepads come from /dev/uinput (python3 standard library only); the keys are read back from the
# "RuyaOS Navigation" device with the EVIOCGKEY ioctl. Prints PASS:/FAIL:/UNVERIFIED: lines.
inputd_py='
import fcntl, glob, os, struct, sys, time

EV_SYN, EV_KEY = 0, 1
BTN_SOUTH, BTN_DPAD_DOWN = 0x130, 0x221
KEY_ENTER, KEY_DOWN = 28, 108
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x5501, 0x5502
EVIOCGKEY = (2 << 30) | (96 << 16) | (0x45 << 8) | 0x18   # _IOR("E", 0x18, 96 bytes)
bad = False


def say(kind, text):
    global bad
    if kind == "FAIL":
        bad = True
    print(kind + ": " + text, flush=True)


def make_pad(tag):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in (BTN_SOUTH, BTN_DPAD_DOWN):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    name = ("ruya-test-pad-" + tag).encode().ljust(80, b"\0")
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, 0x1209, 0x0002, 1, name, 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def send(fd, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, EV_KEY, code, value))
    os.write(fd, struct.pack("llHHi", 0, 0, EV_SYN, 0, 0))


def nav_node():
    for name_file in glob.glob("/sys/class/input/input*/name"):
        with open(name_file) as f:
            if f.read().strip() == "RuyaOS Navigation":
                for ev in glob.glob(os.path.dirname(name_file) + "/event*"):
                    return "/dev/input/" + os.path.basename(ev)
    return None


def down(nav, code):
    buf = bytearray(96)
    fcntl.ioctl(nav, EVIOCGKEY, buf)
    return bool(buf[code // 8] & (1 << (code % 8)))


def wait_for(nav, code, want, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if down(nav, code) == want:
            return True
        time.sleep(0.1)
    return down(nav, code) == want


def picked_up(nav, fd):
    """The daemon rescans every 2 s and sees no state of a pad it opens late: press until it answers."""
    for _ in range(25):
        send(fd, BTN_DPAD_DOWN, 1)
        if wait_for(nav, KEY_DOWN, True, 0.4):
            send(fd, BTN_DPAD_DOWN, 0)
            return wait_for(nav, KEY_DOWN, False, 2)
        send(fd, BTN_DPAD_DOWN, 0)
    return False


try:
    probe = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    os.close(probe)
except OSError as err:
    say("UNVERIFIED", "no access to /dev/uinput as root (" + str(err) + "): the vanished-pad check did not run")
    sys.exit(0)

node = nav_node()
if node is None:
    say("FAIL", "no RuyaOS Navigation input device (ruya-inputd not running?)")
    sys.exit(0)
nav = os.open(node, os.O_RDONLY)

# 1. A pad that vanishes while holding Down and Accept leaves neither key down.
pad = make_pad("a")
if not picked_up(nav, pad):
    say("FAIL", "ruya-inputd did not take the virtual pad within 10 s")
    sys.exit(0)
send(pad, BTN_DPAD_DOWN, 1)
send(pad, BTN_SOUTH, 1)
if wait_for(nav, KEY_DOWN, True, 2) and wait_for(nav, KEY_ENTER, True, 2):
    say("PASS", "a held d-pad Down and A press KEY_DOWN and KEY_ENTER")
else:
    say("FAIL", "holding Down and A did not press KEY_DOWN and KEY_ENTER")
fcntl.ioctl(pad, UI_DEV_DESTROY)
os.close(pad)
if wait_for(nav, KEY_DOWN, False, 3) and wait_for(nav, KEY_ENTER, False, 3):
    say("PASS", "the pad vanished while holding Down and A: KEY_DOWN and KEY_ENTER are up")
else:
    say("FAIL", "a vanished pad left a key down: KEY_DOWN=%s KEY_ENTER=%s" % (down(nav, KEY_DOWN), down(nav, KEY_ENTER)))

# 2. Two pads hold Down; one lets go; the key stays down until the last one does.
p1, p2 = make_pad("b"), make_pad("c")
if not (picked_up(nav, p1) and picked_up(nav, p2)):
    say("FAIL", "ruya-inputd did not take both virtual pads")
    sys.exit(0)
send(p1, BTN_DPAD_DOWN, 1)
send(p2, BTN_DPAD_DOWN, 1)
time.sleep(0.5)
send(p2, BTN_DPAD_DOWN, 0)
time.sleep(1)
if down(nav, KEY_DOWN):
    say("PASS", "pad 2 let go of Down while pad 1 holds it: KEY_DOWN stays down")
else:
    say("FAIL", "pad 2 releasing Down released it for pad 1 too")
send(p1, BTN_DPAD_DOWN, 0)
if wait_for(nav, KEY_DOWN, False, 2):
    say("PASS", "pad 1 let go: KEY_DOWN is up")
else:
    say("FAIL", "KEY_DOWN stayed down after both pads let go")
for fd in (p1, p2):
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
'

inputd_check() {
    echo "--- ruya-inputd (T-337): a vanished pad releases its keys, two pads share a key"
    if systemctl is-active ruya-inputd >/dev/null; then ok "ruya-inputd is active"; else bad "ruya-inputd not active"; return; fi
    local line out
    out="$(python3 -c "$inputd_py" 2>&1)"
    while IFS= read -r line; do
        case "$line" in
        PASS:*) ok "${line#PASS: }" ;;
        FAIL:*) bad "${line#FAIL: }" ;;
        UNVERIFIED:*) echo "$line" ;;
        *) echo "$line"; bad "inputd check printed an unexpected line (traceback?)" ;;
        esac
    done <<<"$out"
    case "$out" in *UNVERIFIED:*) return ;; esac
    if journalctl -u ruya-inputd --no-pager -n 40 2>/dev/null | grep -q 'gone: .*; released'; then
        ok "ruya-inputd logged the vanished pad and what it released"
    else
        bad "no 'gone: ...; released ...' line in the ruya-inputd journal"
    fi
}

# scripts/lint-vm-checks.ps1 sources this file with the variable set to run its helpers on canned data.
if [ "${VM_CHECK_LIB_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

case "${1:-check}" in
security)
    as_shell systemd-analyze --user security ruya-devices --no-pager | tail -15
    ;;
check)
    echo "--- unit"
    if as_shell systemctl --user is-active ruya-devices; then ok "ruya-devices is active"; else bad "ruya-devices not active"; fi
    as_shell systemctl --user status ruya-devices --no-pager | head -12

    echo "--- name owner"
    owner="$(busctl --system status "$svc" 2>/dev/null | grep -E '^(UID|Comm)=' | tr '\n' ' ')"
    echo "$owner"
    case "$owner" in *"UID=$uid"*) ok "name owned by ruya-shell (uid $uid)";; *) bad "name not owned by ruya-shell";; esac

    echo "--- ListSinks"
    sinks="$(busctl --system call "$svc" "$path" "$ifc" ListSinks)"
    echo "$sinks"
    echo "$sinks" | grep -q '"is_default" b true' && ok "a default sink is listed" || bad "no default sink"
    echo "wpctl default:"
    as_shell wpctl status | sed -n '/Sinks:/,/Sources:/p' | head -8

    echo "--- MasterVolume write"
    busctl --system set-property "$svc" "$path" "$ifc" MasterVolume u 37
    sleep 1
    busctl --system get-property "$svc" "$path" "$ifc" MasterVolume
    vol="$(as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@)"
    echo "wpctl: $vol"
    case "$vol" in "Volume: 0.37"*) ok "wpctl sees 0.37";; *) bad "wpctl volume is not 0.37";; esac
    busctl --system set-property "$svc" "$path" "$ifc" Muted b true
    sleep 1
    as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -q MUTED && ok "mute reaches wpctl" || bad "mute not seen"
    busctl --system set-property "$svc" "$path" "$ifc" Muted b false
    busctl --system set-property "$svc" "$path" "$ifc" MasterVolume u 50

    echo "--- channels and errors"
    busctl --system call "$svc" "$path" "$ifc" SetChannelVolume su media 40
    busctl --system call "$svc" "$path" "$ifc" SetChannelVolume su bass 40
    busctl --system call "$svc" "$path" "$ifc" SetDefaultSink s nope
    busctl --system get-property "$svc" "$path" "$ifc" ChannelVolumes

    echo "--- another user is refused"
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListSinks 2>&1)"; then
        bad "nobody could call ListSinks: $out"
    else
        echo "$out"; ok "call from nobody refused"
    fi

    echo "--- network (T-132): NetworkManager behind Devices1.Network"
    if systemctl is-active NetworkManager; then ok "NetworkManager is active"; else bad "NetworkManager not active"; fi
    state="$(busctl --system get-property "$svc" "$path" "$net" State)"
    echo "State: $state"
    case "$state" in 's "connected"') ok "State is connected";; *) bad "State is not connected";; esac
    primary="$(busctl --system get-property "$svc" "$path" "$net" Primary)"
    echo "Primary: $primary"
    case "$primary" in *'"kind" s "ethernet"'*) ok "Primary is ethernet";; *) bad "Primary is not ethernet";; esac
    echo "$primary" | grep -Eq '"ip" s "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' && ok "Primary has an IPv4 address" || bad "Primary has no IPv4 address"
    echo "nmcli says:"
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device | head -5
    wifi="$(busctl --system call "$svc" "$path" "$net" ListWifi)"
    echo "ListWifi: $wifi"
    case "$wifi" in "aa{sv} "*) ok "ListWifi answers (empty is fine in the VM)";; *) bad "ListWifi did not answer aa{sv}";; esac
    scan="$(busctl --system call "$svc" "$path" "$net" Scan)"
    echo "Scan: $scan"
    case "$scan" in 's "ok"') ok "Scan answers ok";; *) bad "Scan did not answer ok";; esac
    unknown="$(busctl --system call "$svc" "$path" "$net" Connect ss nowhere secret)"
    echo "Connect(nowhere): $unknown"
    case "$unknown" in 's "unknown-network"') ok "Connect to an unknown network is refused";; *) bad "unexpected Connect status";; esac
    unknown="$(busctl --system call "$svc" "$path" "$net" Forget s nowhere)"
    case "$unknown" in 's "unknown-network"') ok "Forget of an unknown network is refused";; *) bad "unexpected Forget status";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$net" ListWifi 2>&1)"; then
        bad "nobody could call ListWifi: $out"
    else
        echo "$out"; ok "network call from nobody refused"
    fi
    # T-448: the Wi-Fi radio switch (the Quick Hub's Wi-Fi tile). The VM has no Wi-Fi adapter, so WifiEnabled
    # reads false and writing it is an error on the bus (never a silent success), and it stays false. On a
    # machine with an adapter (the Dell) it must flip, read back and flip again: set-property, get-property.
    wf="$(busctl --system get-property "$svc" "$path" "$net" WifiEnabled 2>&1)"
    echo "WifiEnabled: $wf"
    case "$wf" in
        'b true')
            if busctl --system set-property "$svc" "$path" "$net" WifiEnabled b false                && [ "$(busctl --system get-property "$svc" "$path" "$net" WifiEnabled)" = "b false" ]; then ok "WifiEnabled: off reads back"; else bad "WifiEnabled did not switch off"; fi
            if busctl --system set-property "$svc" "$path" "$net" WifiEnabled b true                && [ "$(busctl --system get-property "$svc" "$path" "$net" WifiEnabled)" = "b true" ]; then ok "WifiEnabled: on reads back"; else bad "WifiEnabled did not switch on"; fi ;;
        'b false')
            if nmcli -t -f TYPE device | grep -q '^wifi'; then
                bad "a Wi-Fi adapter exists but WifiEnabled reads false (radio off?): switch it on and run again"
            elif out="$(busctl --system set-property "$svc" "$path" "$net" WifiEnabled b true 2>&1)"; then
                bad "writing WifiEnabled without an adapter was accepted: $out"
            else
                echo "$out"; ok "no Wi-Fi adapter: WifiEnabled reads false and a write is a bus error"
            fi ;;
        *) bad "WifiEnabled is not a boolean: $wf" ;;
    esac
    if out="$(runuser -u nobody -- busctl --system set-property "$svc" "$path" "$net" WifiEnabled b false 2>&1)"; then
        bad "nobody could write WifiEnabled: $out"
    else
        echo "$out"; ok "WifiEnabled write from nobody refused"
    fi
    # T-180: polkit as the service's own process. pkcheck exit 0 = authorized without a prompt,
    # 1 = not authorized, 2 = would ask for a password. The allowed four are what network.rs
    # calls; everything else in the NetworkManager namespace is refused outright (exit 1), which
    # also overrides NetworkManager's own default for an active session.
    pid="$(pgrep -u ruya-shell -x ruya-devices | head -1)"
    if [ -z "$pid" ]; then bad "no ruya-devices process"; else
        for a in wifi.scan network-control settings.modify.system settings.modify.own enable-disable-wifi; do
            polkit_expect "org.freedesktop.NetworkManager.$a" "$pid" 0 "polkit allows ruya-devices: NetworkManager $a"
        done
        for a in enable-disable-network enable-disable-wwan enable-disable-connectivity-check enable-disable-statistics sleep-wake reload settings.modify.hostname settings.modify.global-dns checkpoint-rollback wifi.share.open wifi.share.protected; do
            polkit_expect "org.freedesktop.NetworkManager.$a" "$pid" 1 "polkit refuses ruya-devices: NetworkManager $a"
        done
    fi

    echo "--- batteries (T-161): UPower behind Devices1.Batteries"
    if command -v upower >/dev/null; then ok "upower is installed"; else bad "upower is not installed"; fi
    upower --version 2>/dev/null | head -2
    # UPower is D-Bus activated: the call below starts it if needed.
    if busctl --system call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower EnumerateDevices >/dev/null 2>&1; then ok "UPower answers on the system bus"; else bad "UPower does not answer"; fi
    if systemctl is-active upower; then ok "upower.service is active"; else bad "upower.service not active"; fi
    echo "UPower devices (type 12 = gaming input, none expected in the VM):"
    upower -d 2>/dev/null | grep -E "^Device:|  (model|native-path):" | head -12
    batt="$(busctl --system call "$svc" "$path" "$bat" ListBatteries)"
    echo "ListBatteries: $batt"
    case "$batt" in 'aa{sv} 0') ok "ListBatteries answers an empty list (no controller in the VM)";; *) bad "ListBatteries did not answer an empty aa{sv}";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$bat" ListBatteries 2>&1)"; then
        bad "nobody could call ListBatteries: $out"
    else
        echo "$out"; ok "batteries call from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the UPower calls" || bad "ruya-devices not active"

    bluetooth_check

    gamepads_check

    storage_usage_check

    thermal_check

    time_check

    sysinfo_check
    performance_check

    events_check "${IDLE:-60}"
    ;;
bluetooth)
    bluetooth_check
    ;;
twopads)
    bluetooth_two_pads_check
    ;;
gamepads)
    gamepads_check
    ;;
storage)
    storage_usage_check
    ;;
thermal)
    thermal_check
    ;;
thermal-fake)
    thermal_fake_check
    ;;
inputd)
    inputd_check
    ;;
time)
    time_check
    ;;
system)
    sysinfo_check
    performance_check
    brightness_check
    ;;
events)
    events_check "${IDLE:-0}"
    ;;
batteries)
    busctl --system call "$svc" "$path" "$bat" ListBatteries
    ;;
state)
    # For the link test: the host runs `set_link <name> off|on` in the QEMU monitor, this shows the result.
    busctl --system get-property "$svc" "$path" "$net" State
    busctl --system get-property "$svc" "$path" "$net" Primary
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
