#!/usr/bin/env bash
# Checks Ruya Input (ruya-inputd, org.ruyaos.Input1, RUY-3 / T-367) inside a running VM, as root:
# the service runs as ruya-input, a uinput "physical" pad gets a virtual Xbox 360-style pad for
# the routed profile whose ACL names only that profile's user, other users are refused, the route
# switches what the pads reach (busctl cannot hold a route: a caller that leaves the bus locks it,
# so vm-input-probe.py holds its own bus connection), rumble is forwarded, and a killed service
# is back within 0.5 s. Copy and run (boot with plain smoke-test.ps1 -Keep):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-input-check.sh scripts/vm-input-probe.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-input-check.sh [check|restart|security|shell]
# `check` runs the first three. `shell` (RUY-409) checks that the running shell drives the route:
# sign-in routes `shell`, launching the Wayland test app (org.ruyaos.TestWaylandClient, which
# `vm-session-check.sh display` installs) routes `app` and makes a virtual pad for a test pad, the
# Guide opens the Hub and routes `overlay`, a kill -9 of the service gets the route again from the
# shell, and Lock routes `locked` and destroys the virtual pad. It also needs vm-inject-key.py in
# /root. Run it after `check` or alone; it signs in the first profile (no PIN, or PIN 1234). On an empty profile store it creates the admin "Check Admin" (PIN 1234)
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
    if lsmod | grep -qw '^joydev'; then bad "joydev is loaded (legacy js nodes, 06 section 3)"; else ok "joydev is not loaded"; fi
    if modprobe joydev >/dev/null 2>&1; then bad "modprobe joydev succeeded"; modprobe -r joydev; else ok "modprobe joydev is refused (blacklisted)"; fi
    if lsinitrd "/usr/lib/modules/$(uname -r)/initramfs.img" 2>/dev/null | grep -q 'joydev\.ko'; then bad "joydev is in the initramfs"; else ok "joydev is not in the initramfs"; fi
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

# The route as the service holds it: shell | app | overlay | locked.
route_now() { busctl --system get-property "$svc" "$path" "$ifc" Route 2>/dev/null | cut -d'"' -f2; }
# Waits up to $2 seconds for the Route property to read $1.
wait_route() {
    local n=0
    while [ "$n" -lt "$(( $2 * 10 ))" ]; do
        [ "$(route_now)" = "$1" ] && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
# The event node of a virtual pad (phys ruya-input/pad<n>), or "".
virtual_pad() {
    local d
    for d in /sys/class/input/input*; do
        case "$(cat "$d/phys" 2>/dev/null)" in ruya-input/pad*) basename "$(ls -d "$d"/event* 2>/dev/null | head -1)"; return;; esac
    done
}
wait_pad() {   # $1: present | gone, $2: seconds
    local n=0
    while [ "$n" -lt "$(( $2 * 10 ))" ]; do
        if [ -n "$(virtual_pad)" ]; then [ "$1" = present ] && return 0; else [ "$1" = gone ] && return 0; fi
        sleep 0.1; n=$((n + 1))
    done
    return 1
}

shell_check() {
    echo "--- the shell drives the route (RUY-409)"
    local wclient=org.ruyaos.TestWaylandClient ssvc=org.ruyaos.Session1 spath=/org/ruyaos/Session1
    local suid since out inst padpid line
    suid="$(id -u ruya-shell)"
    pgrep -u ruya-shell -x ruya-shell >/dev/null || { bad "the shell is not running"; return; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    [ -f /root/vm-inject-key.py ] || { bad "/root/vm-inject-key.py is missing: copy it there"; return; }
    flatpak info --system "$wclient" >/dev/null 2>&1 || { bad "$wclient is not installed: run 'vm-session-check.sh display' (then display-clean) first"; return; }
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    python3 "$probe" pad 300 > /var/tmp/ruya-input-pad.log 2>&1 &
    padpid=$!
    local n=0; until grep -q "^pad " /var/tmp/ruya-input-pad.log || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    grep -q "^pad ready" /var/tmp/ruya-input-pad.log && ok "a test pad is connected ($(cat /var/tmp/ruya-input-pad.log))" || { bad "no test pad: $(cat /var/tmp/ruya-input-pad.log)"; kill "$padpid"; return; }

    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
    wait_route locked 5 && ok "Lock: the shell routes locked" || bad "after Lock the route reads '$(route_now)'"
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$me" "")"
    case "$out" in 'suu "ok"'*) ;; *) out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$me" 1234)";; esac
    case "$out" in 'suu "ok"'*) ok "$me signed in";; *) bad "SwitchTo $me: $out"; kill "$padpid"; return;; esac
    wait_route shell 5 && ok "signed in at Home: the route is shell" || bad "after sign-in the route reads '$(route_now)'"
    [ -z "$(virtual_pad)" ] && ok "no virtual pad at Home" || bad "a virtual pad exists at Home: $(virtual_pad)"

    out="$(runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" Launch ss "$wclient" "$me")"
    inst=""; case "$out" in 'ss "ok" '*) inst="$(echo "$out" | cut -d'"' -f4)";; esac
    [ -n "$inst" ] && ok "Launch $wclient as $me: $inst" || { bad "Launch: $out"; kill "$padpid"; return; }
    wait_route app 60 && ok "the test app in front: the route is app" || bad "with the app in front the route reads '$(route_now)'"
    wait_pad present 5 && ok "the test pad has a virtual pad for $me ($(virtual_pad))" || bad "no virtual pad with the app in front"

    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    wait_route overlay 10 && ok "Guide opened the Hub: the route is overlay" || bad "with the Hub open the route reads '$(route_now)'"
    wait_pad gone 5 && ok "the Hub froze the app: its virtual pad is gone" || echo "NOTE: the virtual pad stays under the Hub (pause off?)"
    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    wait_route app 10 && ok "Guide closed the Hub: the route is app again" || bad "after the Hub the route reads '$(route_now)'"
    wait_pad present 5 && ok "after the Thaw the app has a virtual pad again" || bad "no virtual pad after the Hub closed"

    # A restarted service starts in shell: the shell sends its route again (QDBusServiceWatcher).
    kill -9 "$(systemctl show -p MainPID --value ruya-inputd)"
    wait_route app 10 && ok "after kill -9 the shell routed app again" || bad "after kill -9 the route reads '$(route_now)'"
    wait_pad present 5 && ok "... and the app has a virtual pad again" || bad "no virtual pad after the restart"

    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
    wait_route locked 5 && ok "Lock with the app in front: the route is locked" || bad "after Lock the route reads '$(route_now)'"
    wait_pad gone 5 && ok "Lock destroyed the virtual pad" || bad "a virtual pad still exists after Lock: $(virtual_pad)"

    runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" Stop s "$inst" >/dev/null 2>&1
    kill "$padpid" 2>/dev/null
    line="$(journalctl -u ruya-inputd --since "$since" --no-pager -o cat | grep -E "^ruya-inputd: route (shell|app|overlay|locked) ")"
    echo "$line" | head -8
    if echo "$line" | grep -q "^ruya-inputd: route app instance '$inst' app '$wclient' profile '$me'"; then
        ok "journal: the shell routed app with Session1's instance, the app id and $me"
    else
        bad "journal: no route app line for $inst, $wclient and $me"
    fi
    if journalctl -b _UID="$suid" --since "$since" --no-pager -o cat | grep -a -q "ruya-shell: Input1 SetRoute"; then
        journalctl -b _UID="$suid" --since "$since" --no-pager -o cat | grep -a "ruya-shell: Input1 SetRoute" | head -3
        bad "the shell logged a failed or refused SetRoute"
    else
        ok "the shell logged no failed SetRoute"
    fi
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
shell)
    two_profiles
    [ -n "$me" ] && ok "profile $me signs in" || { bad "need a profile"; exit 1; }
    shell_check
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
