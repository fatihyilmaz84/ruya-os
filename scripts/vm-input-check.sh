#!/usr/bin/env bash
# Checks Ruya Input (ruya-inputd, org.ruyaos.Input1, RUY-3 / T-367) inside a running VM, as root:
# the service runs as ruya-input, a uinput "physical" pad gets a virtual Xbox 360-style pad for
# the routed profile whose ACL names only that profile's user, other users are refused, the route
# switches what the pads reach (busctl cannot hold a route: a caller that leaves the bus locks it,
# so vm-input-probe.py holds its own bus connection), rumble is forwarded, and a killed service
# is back within 0.5 s. Copy and run (boot with plain smoke-test.ps1 -Keep):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-input-check.sh scripts/vm-input-probe.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-input-check.sh [check|restart|security]
# `check` runs all three. On an empty profile store it creates the admin "Check Admin" (PIN 1234)
# and a standard "Check Kid"; with one profile it adds "Check Other" with that admin's PIN 1234.
# Profiles that were there are used as they are; the ones the check made stay (a fresh disk).
set -u
svc=org.ruyaos.Input1
path=/org/ruyaos/Input1
ifc=org.ruyaos.Input1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
here="$(cd "$(dirname "$0")" && pwd)"
probe="$here/vm-input-probe.py"
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

profiles() { busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"'; }

# Two profile accounts: the signed-in one and another.
two_profiles() {
    local ids
    ids="$(profiles)"
    if [ -z "$ids" ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "" "" "Check Admin" admin 1234 >/dev/null
        ids="$(profiles)"
    fi
    if [ "$(echo "$ids" | wc -l)" -lt 2 ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$(echo "$ids" | head -1)" 1234 "Check Kid" standard "" >/dev/null
        ids="$(profiles)"
    fi
    me="$(echo "$ids" | head -1)"
    other="$(echo "$ids" | grep -v "^$me\$" | head -1)"
}

nav_input() {
    local d
    for d in /sys/class/input/input*; do
        [ "$(cat "$d/name" 2>/dev/null)" = "RuyaOS Navigation" ] && { basename "$d"; return; }
    done
}

unit_check() {
    echo "--- unit, user and bus policy"
    if systemctl is-active ruya-inputd >/dev/null; then ok "ruya-inputd is active"; else bad "ruya-inputd not active"; return 1; fi
    local pid user owner out
    pid="$(systemctl show -p MainPID --value ruya-inputd)"
    user="$(ps -o user= -p "$pid" | tr -d ' ')"
    [ "$user" = ruya-input ] && ok "it runs as ruya-input" || bad "it runs as '$user'"
    owner="$(busctl --system status "$svc" 2>/dev/null | grep -E '^UID=' | head -1)"
    [ "$owner" = "UID=$(id -u ruya-input)" ] && ok "ruya-input owns $svc" || bad "owner of $svc: '$owner'"
    out="$(busctl --system get-property "$svc" "$path" "$ifc" Route 2>&1)"
    echo "Route: $out"
    case "$out" in 's "shell"'|'s "locked"') ok "the Route property reads ($out)";; *) bad "Route: $out";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListDevices 2>&1)"; then
        bad "nobody could call ListDevices: $out"
    else
        ok "a call from nobody is refused"
    fi
    if out="$(runuser -u "ruya-$me" -- busctl --system call "$svc" "$path" "$ifc" SetRoute ssss app x org.x.Y "$me" 2>&1)"; then
        bad "a profile user could call SetRoute: $out"
    else
        ok "a call from the profile user ruya-$me is refused"
    fi
    [ "$(stat -c '%G %a' /dev/uinput)" = "ruya-input 660" ] && ok "/dev/uinput is ruya-input 0660" || bad "/dev/uinput: $(stat -c '%U %G %a' /dev/uinput)"
}

routing_check() {
    echo "--- routing, ACLs, conformance and rumble (vm-input-probe.py)"
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    local since line dir
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    # The probe runs again as the profile users (the game, the refused opens): /root is 0700.
    dir="$(mktemp -d /var/tmp/ruya-input-check.XXXXXX)"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    while IFS= read -r line; do
        case "$line" in
        PASS:*) ok "${line#PASS: }" ;;
        FAIL:*) bad "${line#FAIL: }" ;;
        *) echo "$line"; bad "the probe printed an unexpected line (traceback?)" ;;
        esac
    done < <(cd "$dir" && python3 "$dir/vm-input-probe.py" check --user "ruya-$me" --profile "$me" --other "ruya-$other" 2>&1)
    rm -rf "$dir"
    local log
    log="$(journalctl -u ruya-inputd --since "$since" --no-pager -o cat)"
    echo "$log" | grep -q "ready for ruya-$me (/dev/input/event[0-9]*, udev add)" \
        && ok "journal: the virtual pad was announced after its udev add event" \
        || bad "journal: no 'ready for ruya-$me (..., udev add)' line"
    echo "$log" | grep -q "re-asserted after udev change" \
        && ok "journal: the ACL was re-asserted after the change event" \
        || bad "journal: no 're-asserted after udev change' line"
    echo "$log" | grep -q "no udev event in 2 s\|no udev monitor" \
        && bad "journal: the udev monitor did not deliver (fallback used)" \
        || ok "journal: the udev monitor delivered (no fallback)"
    echo "$log" | grep -q "the route's caller .* left the bus: route locked" \
        && ok "journal: the caller leaving locked the route" \
        || bad "journal: no 'left the bus: route locked' line"
}

restart_check() {
    echo "--- kill -9: the navigation keyboard is back within 0.5 s, the shell opens it"
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    local i out ms spid fds node worst=0
    for i in 1 2 3; do
        # vm-input-probe.py restart: kill -9, then polls sysfs every 5 ms for a new navigation node.
        out="$(python3 "$probe" restart)"
        ms="${out##* }"
        case "$out" in
        *" none "*|no-pid) bad "run $i: $out"; ms=5000 ;;
        *) echo "run $i: ${out% *} in $ms ms" ;;
        esac
        [ "$ms" -gt "$worst" ] && worst="$ms"
        sleep 2
    done
    [ "$worst" -le 500 ] && ok "navigation keyboard back after at most $worst ms (target 0.5 s)" || bad "navigation keyboard back after $worst ms (target 0.5 s)"
    spid="$(pgrep -u ruya-shell -x ruya-shell | head -1)"
    if [ -z "$spid" ]; then echo "UNVERIFIED: the shell is not running; cannot check that it opened the new node"; return; fi
    node="/dev/input/$(basename "$(ls -d /sys/class/input/"$(nav_input)"/event* 2>/dev/null | head -1)")"
    fds="$(ls -l /proc/"$spid"/fd 2>/dev/null | grep -c " $node\$")"
    [ "$fds" -ge 1 ] && ok "the shell has the new navigation node $node open: it stays navigable" || bad "the shell does not hold $node open"
    [ "$(systemctl show -p NRestarts --value ruya-inputd)" -ge 3 ] && ok "systemd restarted it (NRestarts $(systemctl show -p NRestarts --value ruya-inputd))" || bad "NRestarts too low"
}

security_check() {
    echo "--- systemd-analyze security ruya-inputd"
    local out level
    out="$(systemd-analyze security ruya-inputd --no-pager 2>&1)"
    echo "$out" | grep -E '✗|Overall' | tail -25
    level="$(echo "$out" | grep -o 'Overall exposure level for ruya-inputd.service: [0-9.]*' | grep -o '[0-9.]*$')"
    [ -n "$level" ] && ok "exposure $level (baseline in image/security-baseline.json, vm-security-check.sh)" || bad "no exposure level"
}

case "${1:-check}" in
check)
    two_profiles
    [ -n "$me" ] && [ -n "$other" ] && ok "profiles: $me signs in, $other is the other user" || { bad "need two profiles"; exit 1; }
    unit_check && routing_check
    restart_check
    security_check
    ;;
restart) restart_check ;;
security) security_check ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
