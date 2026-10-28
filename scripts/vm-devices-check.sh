#!/usr/bin/env bash
# Checks the Devices service (audio T-128, network T-132) inside a running VM booted with sound. Copy and run as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-devices-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-devices-check.sh [check|events|security|state]
# check (default): unit active, name owned by ruya-shell, ListSinks, a MasterVolume write reaches
# PipeWire, a call from another user is refused; then the network part: State is connected, Primary is
# the ethernet link with an IPv4 address, ListWifi and Scan answer, unknown ids are refused, another
# user is refused. Needs the shell logged in (VM booted with -Audio).
# events: only the PipeWire event checks (T-133); IDLE=60 adds the idle-process count (also part of check; samples the process list for IDLE seconds).
# state: prints State and Primary (for the link test, see docs/dev-setup.md).
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
ifc=org.ruyaos.Devices1.Audio
net=org.ruyaos.Devices1.Network
uid="$(id -u ruya-shell)"
as_shell() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

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

    events_check "${IDLE:-60}"
    ;;
events)
    events_check "${IDLE:-0}"
    ;;
state)
    # For the link test: the host runs `set_link <name> off|on` in the QEMU monitor, this shows the result.
    busctl --system get-property "$svc" "$path" "$net" State
    busctl --system get-property "$svc" "$path" "$net" Primary
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
