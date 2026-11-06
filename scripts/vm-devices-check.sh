#!/usr/bin/env bash
# Checks the Devices service (audio T-128, network T-132, controller batteries T-161, Bluetooth T-173) inside a running VM booted with sound. Copy and run as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-devices-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-devices-check.sh [check|events|security|state|batteries|bluetooth]
# check (default): unit active, name owned by ruya-shell, ListSinks, a MasterVolume write reaches
# PipeWire, a call from another user is refused; then the network part: State is connected, Primary is
# the ethernet link with an IPv4 address, ListWifi and Scan answer, unknown ids are refused, another
# user is refused, pkcheck as the service's process allows the four NetworkManager actions it needs and
# refuses twelve others (T-180); then the batteries part: upower is installed and answers on the bus, ListBatteries answers an
# empty list (no controller in the VM; a real controller's battery is NOT checked here), another user is
# refused; then the Bluetooth part: bluetooth.service is active and org.bluez is on the bus, Powered is false,
# ListDevices answers an empty list, StartScan/Pair/Connect answer unavailable (no adapter in the VM; a real
# adapter and controller are NOT checked here), unknown ids and empty ids are refused, another user is
# refused. Needs the shell logged in (VM booted with -Audio).
# events: only the PipeWire event checks (T-133); IDLE=60 adds the idle-process count (also part of check; samples the process list for IDLE seconds).
# state: prints State and Primary (for the link test, see docs/dev-setup.md).
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
ifc=org.ruyaos.Devices1.Audio
net=org.ruyaos.Devices1.Network
bat=org.ruyaos.Devices1.Batteries
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
        # Idle: sample the process list ten times a second; the 1 s poll started a pw-dump and a
        # wpctl every second (each lives some tens of ms), so it would be caught many times.
        monitor="$(pgrep -x pw-dump | head -1)"
        cpu0="$(as_shell systemctl --user show ruya-devices -p CPUUsageNSec --value)"
        seen=" "; samples=$((idle * 10)); i=0
        while [ "$i" -lt "$samples" ]; do
            for p in $(pgrep -x 'pw-dump|wpctl'); do
                [ "$p" = "$monitor" ] && continue
                case "$seen" in *" $p "*) ;; *) seen="$seen$p ";; esac
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
    r="$(busctl --system call "$svc" "$path" "$bt" Pair s AA:BB:CC:DD:EE:FF)"
    case "$r" in 's "unavailable"') ok "Pair answers unavailable";; *) bad "Pair answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Pair s "")"
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
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the Bluetooth calls" || bad "ruya-devices not active"
}

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
    # T-180: polkit as the service's own process. pkcheck exit 0 = authorized without a prompt,
    # 1 = not authorized, 2 = would ask for a password. The allowed four are what network.rs
    # calls; everything else in the NetworkManager namespace is refused outright (exit 1), which
    # also overrides NetworkManager's own default for an active session.
    pid="$(pgrep -u ruya-shell -x ruya-devices | head -1)"
    if [ -z "$pid" ]; then bad "no ruya-devices process"; else
        for a in wifi.scan network-control settings.modify.system settings.modify.own; do
            polkit_expect "org.freedesktop.NetworkManager.$a" "$pid" 0 "polkit allows ruya-devices: NetworkManager $a"
        done
        for a in enable-disable-network enable-disable-wifi enable-disable-wwan enable-disable-connectivity-check enable-disable-statistics sleep-wake reload settings.modify.hostname settings.modify.global-dns checkpoint-rollback wifi.share.open wifi.share.protected; do
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

    events_check "${IDLE:-60}"
    ;;
bluetooth)
    bluetooth_check
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
