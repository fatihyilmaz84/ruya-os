#!/usr/bin/env bash
# Checks Ruya Input (ruya-inputd, org.ruyaos.Input1, RUY-3 / T-367) inside a running VM, as root:
# the service runs as ruya-input, a uinput "physical" pad gets a virtual Xbox 360-style pad for
# the routed profile whose ACL names only that profile's user, other users are refused, the route
# switches what the pads reach (busctl cannot hold a route: a caller that leaves the bus locks it,
# so vm-input-probe.py holds its own bus connection), rumble is forwarded, and a killed service
# is back within 0.5 s. The restart step (RUY-597) runs three kills and passes when the MEDIAN is at most
# 500 ms and the worst at most 1000 ms: the first run after heavy checks is slow (644 ms once; a lone re-run
# gave 190-426 ms), and the 1000 ms ceiling still catches a real regression. Copy and run (boot with plain smoke-test.ps1 -Keep):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-input-check.sh scripts/vm-input-probe.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-input-check.sh [check|restart|security|caps|profiles|shell|close|fallback|confirm|hold|twopads|guide|nodes|start|useractive|signals|players]
# `players` (RUY-121) with the shell stopped like `twopads`: three uinput pads; a second profile "Check Player" is made with
# CreateProfile (as the admin $me, PIN 1234) and removed at the end. Pad A presses, then the probe routes the profile: ListPlayers
# (busctl --json=short) has seat 1 = A; JoinPlayer(B, the second profile) answers ok 2; in the route app ruya-input/pad1 is A and
# pad2 is B (read as the profile user), the unseated third pad has no seat's number but, with the seat gate off (the image until
# RUY-122), a pad after the seats (pad5) that only its button reaches; LeavePlayer(2) removes pad2 and pad1 stays. Since RUY-121 only a
# seated pad gets a virtual pad: the other modes seat their pads (JoinPlayer, or a press before the sign-in), and `twopads`,
# `guide` and the probe's `twoprofiles` seat the second pad as the other profile.
# `useractive` (RUY-588) with the shell stopped like `twopads`: a uinput pad's press in route `app` makes ruya-inputd emit Input1.UserActive
# once (seen with busctl monitor), not for stick noise or in route `shell`, not again within 30 s, and once more after them.
# `signals` (RUY-594) with the shell stopped like `useractive`: Input1's broadcast signals reach only root and ruya-shell (the bus
# policy's receive rules). Plain bus clients (vm-input-probe.py listen) run as root and ruya-shell and must hear TestInput and
# UserActive while a pad is pressed; as nobody, the profile user, ruya-link and ruya-library they must hear none, and must hear the
# bus's own NameOwnerChanged (so their silence is the policy's). `vm-security-check.sh signals` runs this step.
# `confirm` (RUY-40) checks the family's confirm button with a uinput pad announcing Nintendo's vendor
# id: BTN_EAST gives KEY_ENTER and BTN_SOUTH KEY_ESC on RuyaOS Navigation, `south` swaps them back, `east`
# gives them to every family. Per controller (RUY-603): a second pad set to `south` while the first is `east`
# confirms with its bottom button and the first with its right one, GetConfirmButtons lists both, `family`
# removes each; the ConfirmButton property is the mode of the pad that pressed last; bad modes, bad device ids,
# accounts and the old two-argument call are refused. It stops
# ruya-compositor@tty1 for the block (an Accept must not reach a live Home, RUY-473) and starts it again; run
# it alone, not inside `check`.
# `hold` (RUY-479) checks StartTest(device_id, hold_left_stick) with the same pad and the same stopped compositor:
# without the flag the left stick sends Right/Left, with it no arrow key (the D-pad still sends Right), a stick
# held when the hold starts is released once, after StopTest a pushed stick stays quiet until it was neutral,
# and the old one-argument StartTest is refused. Run it alone, not inside `check`.
# `twopads` (RUY-540) checks the numbering of the virtual pads with two uinput pads: the pad that signed the profile in is
# ruya-input/pad1, created first (the lower event node, SDL index 0), whichever of the two it is; the profile user opens
# pad1 and hears that pad's button and not the idle pad's. It routes by its own bus connection and ends on `shell`.
# The journal must show, on each entry to `app`, pad2 made only after pad1 was ready (RUY-541: a one-pad game gets pad1).
# Then (RUY-545, probe `twoprofiles`) two slots assigned over Input1, the device's of one pad and the Nintendo family's
# for a pad with Nintendo's vendor id: each virtual pad emits its own pad's profile, and emptying the family's slot
# changes only that pad; a slot the profile's match does not name is refused. Afterwards each slot it used gets back the
# profile it held before (ListProfiles read first) and its own profiles are deleted.
# `guide` (RUY-11) with two uinput pads in route `app` (shell stopped like `twopads`): the Guide button of either pad, held
# 0.6 s, gives KEY_HOMEPAGE down and up on RuyaOS Navigation and no BTN_MODE on either virtual pad the profile user reads.
# `nodes` (RUY-446) checks the virtual pad node (phys ruya-input/pad<n>) the way 06 section 3 rule 3 says: ruya-input's,
# user rw and nothing for group and other (getfacl; stat's group bits show the ACL mask), no uaccess tag, no ACL entry for
# ruya-shell, the profile user's entry; a ruya-input/kbm* node keeps uaccess. Run it alone, not inside `check`.
# `start` (RUY-583) checks the chain inputd -> evdev -> xkb -> Qt for Start: with the shell running at Home, a uinput pad taps
# BTN_START; the shell must log "ruya-shell: options menu open (<card|pill|row>)" exactly once (the second tap closes the
# menu and logs nothing), and `vm-inject-key.py menu` (KEY_COMPOSE) must open it too. Needs Home with a focused card (a
# game installed) and vm-inject-key.py in /root. Run it alone, not inside `check`.
# `check` runs the first four, then `caps` and `profiles`. `profiles` (RUY-42) checks the controller
# profiles over busctl: the built-ins, validation (a bad file, 64 KiB + 1), storage in
# /var/lib/ruya-input/profiles/<profile>/ (0700 / 0600, ruya-input's, unreadable to the profile
# user), a restart keeps them, the bus policy; `check`'s probe also remaps South to East on a live
# virtual pad and reads East (the remap changes the virtual pad's output). `caps` (RUY-39 / T-368) lists the probe's uinput pad through ListDevices and
# checks its GetCapabilities descriptor (an unknown model: what the kernel shows, nothing inferred) and
# that StartTest answers; a test that busctl starts ends at once with reason "caller" (busctl leaves
# the bus), which the journal says. Since RUY-409 the shell drives the route itself, so `check` and `shell`
# first make their own state (RUY-430): they stop every running app through Session1, lock and sign
# $me in again, and wait for the route `shell` (Home). The probe takes the route over with its own bus
# connection and leaves the bus, which locks the route (that is part of the check); `check` then gives
# the route back by Lock and a new sign-in, so the shell sends its own route again. Where the shell is
# not running, `check` skips this and works as before. `shell` (RUY-409) checks that the running shell drives the route:
# sign-in routes `shell`, launching the Wayland test app (org.ruyaos.TestWaylandClient, which
# `vm-session-check.sh display` installs) routes `app` and makes a virtual pad for a test pad, the
# Guide opens the Hub and routes `overlay` (RUY-541: the Hub's Freeze and the Thaw keep the same virtual pad event
# node, the overlay names the app and inputd logs no pad destroyed or made meanwhile), a kill -9 of the service gets the route again from the
# shell, and Lock routes `locked` and destroys the virtual pad. It also needs vm-inject-key.py in
# /root. Run it after `check` or alone; it signs in the first profile (no PIN, or PIN 1234). On an empty profile store it creates the admin "Check Admin" (PIN 1234)
# and a standard "Check Kid"; with one profile it adds "Check Other" with that admin's PIN 1234.
# Profiles that were there are used as they are; the ones the check made stay (a fresh disk).
# `close` (RUY-611) closes a running game from the Hub the way a player does (Guide, Down, Right, Return on Close game, injected by
# vm-inject-key.py): the game's virtual pad must stay until its unit is gone (a game saves its controller choice on quit;
# LibreQuake saved joy_device -1 after its pads were destroyed under it), so the journal shows no "virtual pad ... destroyed"
# before the last journal line of the game's unit, the route stays overlay with the game's instance until the exit and is
# shell afterwards. Needs the shell running, the Wayland test app (see `shell`), vm-input-probe.py and vm-inject-key.py.
# `fallback` (RUY-410) checks the compositor's emergency pad reader: it masks ruya-inputd
# (systemctl mask --runtime --now), waits for the shell's journal line "ruya-shell: input fallback on"
# (3 s without an owner of org.ruyaos.Input1), locks to the picker and lets a uinput pad
# (vm-input-probe.py navpad) tap the D-pad and A until the profile without a PIN is signed in
# (Profiles1 ActiveProfile), then unmasks and checks "input fallback off" and the service back. It
# needs the shell running and the probe next to this script; it creates the standard profile
# "Check Pad" (no PIN) when every profile has one.
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
    local i out ms spid fds node worst=0 times="" median
    for i in 1 2 3; do
        # vm-input-probe.py restart: kill -9, then polls sysfs every 5 ms for a new navigation node.
        out="$(python3 "$probe" restart)"
        ms="${out##* }"
        case "$out" in
        *" none "*|no-pid) bad "run $i: $out"; ms=5000 ;;
        *) echo "run $i: ${out% *} in $ms ms" ;;
        esac
        [ "$ms" -gt "$worst" ] && worst="$ms"
        times="$times$ms "
        sleep 2
    done
    # RUY-597: the median of the three must be <= 500 ms and the worst <= 1000 ms.
    median="$(printf '%s\n' $times | sort -n | sed -n 2p)"
    echo "restart times: $times(ms), median $median, worst $worst"
    if [ "$median" -gt 500 ]; then
        bad "navigation keyboard back: median $median ms is over 500 ms (runs: $times; target 0.5 s)"
    elif [ "$worst" -gt 1000 ]; then
        bad "navigation keyboard back: worst run $worst ms is over the 1000 ms ceiling (median $median ms; runs: $times)"
    else
        ok "navigation keyboard back: median $median ms (<= 500), worst $worst ms (<= 1000) (target 0.5 s)"
    fi
    spid="$(pgrep -u ruya-shell -x ruya-shell | head -1)"
    if [ -z "$spid" ]; then echo "UNVERIFIED: the shell is not running; cannot check that it opened the new node"; return; fi
    node="/dev/input/$(basename "$(ls -d /sys/class/input/"$(nav_input)"/event* 2>/dev/null | head -1)")"
    fds="$(ls -l /proc/"$spid"/fd 2>/dev/null | grep -c " $node\$")"
    [ "$fds" -ge 1 ] && ok "the shell has the new navigation node $node open: it stays navigable" || bad "the shell does not hold $node open"
    [ "$(systemctl show -p NRestarts --value ruya-inputd)" -ge 3 ] && ok "systemd restarted it (NRestarts $(systemctl show -p NRestarts --value ruya-inputd))" || bad "NRestarts too low"
}

# Controller profiles (RUY-42, 06 section 7) over busctl: built-ins, validation and its hostile cases,
# storage in the StateDirectory (0700 / 0600, owned by ruya-input), a restart keeps them, the bus
# policy. The remap on a live virtual pad is in `check` (vm-input-probe.py).
profiles_check() {
    echo "--- controller profiles (RUY-42)"
    local out dir file big
    dir="/var/lib/ruya-input/profiles/$me"
    file="$dir/vm-check-keep.json"
    out="$(busctl --system call "$svc" "$path" "$ifc" ListProfiles s "$me" 2>&1)"
    case "$out" in *'"ok"'*'"default"'*'"nintendo"'*) ok "ListProfiles lists the built-ins default and nintendo" ;; *) bad "ListProfiles: $out" ;; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" ListProfiles s shell 2>&1)"
    case "$out" in *'"unknown-profile"'*) ok "ListProfiles for ruya-shell: unknown-profile" ;; *) bad "ListProfiles shell: $out" ;; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" ValidateProfile s '{"schema_version":2,"id":"x","name":"x","scope":{"type":"global"},"script":"rm -rf /"}' 2>&1)"
    case "$out" in
    *'"invalid"'*'/schema_version: must be 1'*|*'"invalid"'*'unknown field script'*)
        echo "$out" | grep -q '/schema_version: must be 1' && echo "$out" | grep -q '/: unknown field script'             && ok "ValidateProfile refuses a bad file with path: message lines" || bad "ValidateProfile: $out" ;;
    *) bad "ValidateProfile: $out" ;;
    esac
    big="$(python3 -c 'import json; print(json.dumps({"schema_version": 1, "id": "big", "name": "B", "scope": {"type": "global"}}) + " " * 65536)')"
    out="$(busctl --system call "$svc" "$path" "$ifc" ValidateProfile s "$big" 2>&1)"
    case "$out" in *'"invalid"'*'larger than 65536 bytes'*) ok "ValidateProfile refuses more than 64 KiB" ;; *) bad "ValidateProfile of 64 KiB + 1: ${out:0:200}" ;; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" SaveProfile ss "$me" '{"schema_version":1,"id":"vm-check-keep","name":"VM check","scope":{"type":"global"},"inherits":"nintendo"}' 2>&1)"
    case "$out" in *'"ok" "vm-check-keep"'*) ok "SaveProfile: ok" ;; *) bad "SaveProfile: $out" ;; esac
    [ "$(stat -c '%U %a' "$dir" 2>/dev/null)" = "ruya-input 700" ] && ok "$dir is ruya-input's, 0700" || bad "$dir: $(stat -c '%U %a' "$dir" 2>&1)"
    [ "$(stat -c '%U %a' "$file" 2>/dev/null)" = "ruya-input 600" ] && ok "the profile file is ruya-input's, 0600" || bad "$file: $(stat -c '%U %a' "$file" 2>&1)"
    runuser -u "ruya-$me" -- cat "$file" >/dev/null 2>&1 && bad "ruya-$me can read the stored profile" || ok "the profile user cannot read the stored file"
    out="$(busctl --system call "$svc" "$path" "$ifc" DeleteProfile ss "$me" nintendo 2>&1)"
    case "$out" in *'"not-allowed"'*) ok "DeleteProfile of a built-in: not-allowed" ;; *) bad "DeleteProfile nintendo: $out" ;; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" SaveProfile ss "$me" '{"schema_version":1,"id":"vm-check-orphan","name":"O","scope":{"type":"global"},"inherits":"ghost"}' 2>&1)"
    case "$out" in *'"invalid"'*'no profile'*) ok "SaveProfile with a parent that does not exist: invalid" ;; *) bad "SaveProfile orphan: $out" ;; esac
    systemctl restart ruya-inputd
    sleep 1
    out="$(busctl --system call "$svc" "$path" "$ifc" ListProfiles s "$me" 2>&1)"
    case "$out" in *'"vm-check-keep"'*) ok "the profile survives a restart of the service" ;; *) bad "after the restart: $out" ;; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" GetEffectiveProfile sss "$me" "" "" 2>&1)"
    case "$out" in *'"ok"'*'inner_deadzone'*) ok "GetEffectiveProfile answers the merged profile" ;; *) bad "GetEffectiveProfile: ${out:0:200}" ;; esac
    out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListProfiles s "$me" 2>&1)" && bad "nobody could call ListProfiles: $out" || ok "nobody cannot call ListProfiles"
    out="$(busctl --system call "$svc" "$path" "$ifc" DeleteProfile ss "$me" vm-check-keep 2>&1)"
    case "$out" in *'"ok"'*) ok "DeleteProfile: ok" ;; *) bad "DeleteProfile: $out" ;; esac
    [ ! -e "$file" ] && ok "the file is gone" || bad "$file is still there"
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
# How many running apps Session1 reports frozen (the form vm-app-check.sh greps for).
frozen_count() {
    runuser -u ruya-shell -- busctl --system --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning 2>/dev/null \
        | grep -o '"frozen":{"type":"b","data":true}' | wc -l
}
wait_pad() {   # $1: present | gone, $2: seconds
    local n=0
    while [ "$n" -lt "$(( $2 * 10 ))" ]; do
        if [ -n "$(virtual_pad)" ]; then [ "$1" = present ] && return 0; else [ "$1" = gone ] && return 0; fi
        sleep 0.1; n=$((n + 1))
    done
    return 1
}

# Stops every running app through Session1 (as ruya-shell) and waits until ListRunning is empty.
stop_all_apps() {
    local ssvc=org.ruyaos.Session1 spath=/org/ruyaos/Session1 list i n=0
    list="$(runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" ListRunning 2>/dev/null | grep -o 'ruya-app-[^"]*\.service' | sort -u)"
    for i in $list; do
        echo "stopping the running app $i"
        runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" Stop s "$i" >/dev/null 2>&1
    done
    while [ "$n" -lt 200 ]; do
        runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" ListRunning 2>/dev/null | grep -q 'ruya-app-' || return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
# Signs $me in with the PIN it has (none, or 1234). Returns 1 with a FAIL line when that fails.
sign_in_me() {
    local out
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$me" "")"
    case "$out" in 'suu "ok"'*) ;; *) out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$me" 1234)";; esac
    case "$out" in 'suu "ok"'*) return 0;; *) bad "SwitchTo $me: $out"; return 1;; esac
}
# Lock, then sign $me in: the shell sends Input1.SetRoute for each step, so the route ends as `shell`.
# Needs the shell. Returns 1 with a FAIL line when the route does not settle.
settle_route() {
    local n=0
    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
    # The route may read `locked` already (the probe left the bus), so wait for the picker instead, and
    # give the shell a second to send: it sends on changes only, and a sign-in right behind the Lock
    # would leave its last sent route (shell) unchanged and send nothing.
    until [ -z "$(active_profile)" ] || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    [ -z "$(active_profile)" ] || { bad "Lock left $(active_profile) signed in"; return 1; }
    sleep 1
    wait_route locked 5 || { bad "after Lock the route reads '$(route_now)'"; return 1; }
    sign_in_me || return 1
    wait_route shell 10 || { bad "signed in at Home: the route reads '$(route_now)', not shell"; return 1; }
}
# Own state for `check` (RUY-430): no app in front, $me at Home, the route shell.
prepare_state() {
    echo "--- own state: no running app, $me at Home, the route shell (RUY-430)"
    if ! pgrep -u ruya-shell -x ruya-shell >/dev/null; then
        echo "NOTE: the shell is not running: the route is left as it is"
        return
    fi
    stop_all_apps && ok "no app is running" || bad "an app is still running after Stop"
    settle_route && ok "$me is at Home and the route is shell"
}
# After the probe left the bus the route is locked; the shell does not know (it sends on changes only).
restore_state() {
    pgrep -u ruya-shell -x ruya-shell >/dev/null || return
    settle_route && ok "the route is given back: the shell routes shell again"
}

# RUY-121: only a seated pad gets a virtual pad, and SwitchTo over busctl signs $me in without a pad (no press):
# the test pad of `vm-input-probe.py pad` ("Ruya VM Check Pad") joins as $me, which makes it player 1 (pad1).
seat_test_pad() {
    local id="" out n=0
    until [ -n "$id" ] || [ "$n" -ge 50 ]; do
        id="$(busctl --system --json=short call "$svc" "$path" "$ifc" ListDevices 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)["data"][0]
except (ValueError, KeyError, IndexError):
    rows = []
print(next((r["id"]["data"] for r in rows if r.get("name", {}).get("data") == "Ruya VM Check Pad"), ""))')"
        [ -n "$id" ] || { sleep 0.1; n=$((n + 1)); }
    done
    [ -n "$id" ] || { bad "the test pad is not in ListDevices"; return 1; }
    out="$(busctl --system call "$svc" "$path" "$ifc" JoinPlayer ss "$id" "$me")"
    case "$out" in 'su "ok" 1') ok "JoinPlayer: the test pad is player 1 ($id)" ;; *) bad "JoinPlayer $id $me: $out"; return 1 ;; esac
    test_pad="$id"
}
# Waits up to $1 seconds for a virtual pad with phys ruya-input/pad1 (player 1's).
wait_pad1() {
    local d n=0
    while [ "$n" -lt "$(( $1 * 10 ))" ]; do
        for d in /sys/class/input/input*; do
            [ "$(cat "$d/phys" 2>/dev/null)" = ruya-input/pad1 ] && return 0
        done
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

    # An app left by an earlier check (vm-session-check.sh display) would make Launch answer already-running.
    stop_all_apps && ok "no app is running before the test app starts" || { bad "an app is still running after Stop"; kill "$padpid"; return; }
    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
    wait_route locked 5 && ok "Lock: the shell routes locked" || bad "after Lock the route reads '$(route_now)'"
    sign_in_me && ok "$me signed in" || { kill "$padpid"; return; }
    wait_route shell 5 && ok "signed in at Home: the route is shell" || bad "after sign-in the route reads '$(route_now)'"
    [ -z "$(virtual_pad)" ] && ok "no virtual pad at Home" || bad "a virtual pad exists at Home: $(virtual_pad)"
    seat_test_pad || { kill "$padpid"; return; }

    out="$(runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" Launch ss "$wclient" "$me")"
    inst=""; case "$out" in 'ss "ok" '*) inst="$(echo "$out" | cut -d'"' -f4)";; esac
    [ -n "$inst" ] && ok "Launch $wclient as $me: $inst" || { bad "Launch: $out"; kill "$padpid"; return; }
    wait_route app 60 && ok "the test app in front: the route is app" || bad "with the app in front the route reads '$(route_now)'"
    wait_pad present 5 && ok "the test pad has a virtual pad for $me ($(virtual_pad))" || bad "no virtual pad with the app in front"

    # RUY-541: the Hub's Freeze keeps the app's virtual pad: the same event node under the Hub (frozen)
    # and after the Thaw, the overlay names the app, and inputd logs no pad destroyed or made meanwhile.
    local node_before hubsince n=0
    node_before="$(virtual_pad)"
    sleep 1                                      # journalctl --since has whole seconds
    hubsince="$(date '+%Y-%m-%d %H:%M:%S')"
    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    wait_route overlay 10 && ok "Guide opened the Hub: the route is overlay" || bad "with the Hub open the route reads '$(route_now)'"
    until [ "$(frozen_count)" -ge 1 ] || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    [ "$(frozen_count)" -ge 1 ] && ok "the Hub froze the app" || bad "the Hub did not freeze the app (Pause games in the Hub off?)"
    sleep 1                                      # an overlay without the instance would destroy the pad by now
    [ -n "$node_before" ] && [ "$(virtual_pad)" = "$node_before" ] && ok "the frozen app keeps its virtual pad ($node_before)" || bad "under the Hub the virtual pad is '$(virtual_pad)', before it was '$node_before'"
    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    wait_route app 10 && ok "Guide closed the Hub: the route is app again" || bad "after the Hub the route reads '$(route_now)'"
    n=0; until [ "$(frozen_count)" = 0 ] || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    [ "$(frozen_count)" = 0 ] && ok "the app was thawed" || bad "the app is still frozen after the Hub closed"
    [ "$(virtual_pad)" = "$node_before" ] && ok "after the Thaw the app has the same virtual pad ($node_before)" || bad "after the Thaw the virtual pad is '$(virtual_pad)', before the Hub '$node_before'"
    line="$(journalctl -u ruya-inputd --since "$hubsince" --no-pager -o cat | grep -E "virtual pad ruya-input/pad[0-9]+ (destroyed|created )|route overlay instance '' ")"
    [ -z "$line" ] && ok "journal: no virtual pad destroyed or made through the Hub, and the overlay named the app" || { echo "$line" | head -5; bad "journal: the Hub destroyed or made a virtual pad, or sent an overlay without the instance"; }

    # A restarted service starts in shell: the shell sends its route again (QDBusServiceWatcher).
    kill -9 "$(systemctl show -p MainPID --value ruya-inputd)"
    wait_route app 10 && ok "after kill -9 the shell routed app again" || bad "after kill -9 the route reads '$(route_now)'"
    # A new process knows no seats (RUY-121): the shell joins the players it knew again (Input replays them on the
    # new owner), so the test pad is player 1 and pad1 again. With the seat gate off (until RUY-122) an unseated pad
    # would get a virtual pad too (pad5), so this waits for pad1 and for seat 1 on the test pad, not for any pad.
    wait_pad1 5 && ok "... and the app has pad1 again" || bad "no ruya-input/pad1 after the restart: the shell did not join its players again"
    busctl --system call "$svc" "$path" "$ifc" ListPlayers | grep -q "\"$test_pad\"" \
        && ok "ListPlayers: the shell seated the test pad again ($test_pad)" \
        || bad "after the restart ListPlayers lacks the test pad: $(busctl --system call "$svc" "$path" "$ifc" ListPlayers)"

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

# RUY-611: Close game from the Hub keeps the game's virtual pads until its unit is gone. Needs the shell, the Wayland
# test app, the probe (a uinput pad) and vm-inject-key.py in /root, like shell_check.
close_check() {
    echo "--- Close game from the Hub keeps the pads until the game has exited (RUY-611)"
    local wclient=org.ruyaos.TestWaylandClient ssvc=org.ruyaos.Session1 spath=/org/ruyaos/Session1
    local out inst padpid node_before closets unit_ts destroyed_ts first n=0
    pgrep -u ruya-shell -x ruya-shell >/dev/null || { bad "the shell is not running"; return; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    [ -f /root/vm-inject-key.py ] || { bad "/root/vm-inject-key.py is missing: copy it there"; return; }
    flatpak info --system "$wclient" >/dev/null 2>&1 || { bad "$wclient is not installed: run 'vm-session-check.sh display' (then display-clean) first"; return; }
    python3 "$probe" pad 300 > /var/tmp/ruya-input-pad.log 2>&1 &
    padpid=$!
    until grep -q "^pad " /var/tmp/ruya-input-pad.log || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    grep -q "^pad ready" /var/tmp/ruya-input-pad.log && ok "a test pad is connected" || { bad "no test pad: $(cat /var/tmp/ruya-input-pad.log)"; kill "$padpid"; return; }
    stop_all_apps && ok "no app is running before the test app starts" || { bad "an app is still running after Stop"; kill "$padpid"; return; }
    settle_route || { kill "$padpid"; return; }
    seat_test_pad || { kill "$padpid"; return; }

    out="$(runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" Launch ss "$wclient" "$me")"
    inst=""; case "$out" in 'ss "ok" '*) inst="$(echo "$out" | cut -d'"' -f4)";; esac
    [ -n "$inst" ] && ok "Launch $wclient as $me: $inst" || { bad "Launch: $out"; kill "$padpid"; return; }
    wait_route app 60 && ok "the test app in front: the route is app" || bad "with the app in front the route reads '$(route_now)'"
    wait_pad present 5 && ok "the test pad has a virtual pad for $me ($(virtual_pad))" || bad "no virtual pad with the app in front"
    node_before="$(virtual_pad)"

    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    wait_route overlay 10 && ok "Guide opened the Hub: the route is overlay" || bad "with the Hub open the route reads '$(route_now)'"
    n=0; until [ "$(frozen_count)" -ge 1 ] || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    [ "$(frozen_count)" -ge 1 ] && ok "the Hub froze the app" || bad "the Hub did not freeze the app (Pause games in the Hub off?)"
    [ -n "$node_before" ] && [ "$(virtual_pad)" = "$node_before" ] && ok "the frozen app keeps its virtual pad ($node_before)" || bad "under the Hub the virtual pad is '$(virtual_pad)', before it was '$node_before'"

    # Resume is focused when the Hub opens: Down, then Right is Close game (it shares the row with Home), Return.
    closets="$(date +%s.%N)"
    python3 /root/vm-inject-key.py down right return >/dev/null 2>&1
    n=0
    until ! runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" ListRunning 2>/dev/null | grep -q "$inst" || [ "$n" -ge 100 ]; do
        sleep 0.1; n=$((n + 1))
    done
    if runuser -u ruya-shell -- busctl --system call "$ssvc" "$spath" "$ssvc" ListRunning 2>/dev/null | grep -q "$inst"; then
        bad "Close game from the Hub did not end $inst (did the key presses reach the Hub?)"
    else
        ok "Close game ended $inst"
    fi
    wait_route shell 10 && ok "after the exit the route is shell" || bad "after the exit the route reads '$(route_now)'"
    wait_pad gone 5 && ok "... and the virtual pad is gone" || bad "a virtual pad still exists after the exit: $(virtual_pad)"

    # The order, by the journal's own clock: the game's unit has no later line than the first destroyed pad.
    # The app's unit lives in the profile's user manager, so `-u` (system units) finds nothing: match the user-unit
    # fields (its own lines and the manager's Stopping/Stopped lines). Only numeric stamps count: an empty result
    # used to print "-- No entries --", whose "--" compared as 0 and passed (lead-20, 0.0.81 queue).
    unit_ts="$(journalctl _SYSTEMD_USER_UNIT="$inst" + USER_UNIT="$inst" --since "@${closets%.*}" --no-pager -o short-unix 2>/dev/null | awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {t = $1} END {print t}')"
    first="$(journalctl -u ruya-inputd --since "@${closets%.*}" --no-pager -o short-unix 2>/dev/null | grep -E "virtual pad ruya-input/pad[0-9]+ destroyed" | head -1)"
    destroyed_ts="${first%% *}"
    if [ -z "$destroyed_ts" ]; then
        bad "journal: no 'virtual pad ... destroyed' line after the Close"
    elif [ -z "$unit_ts" ]; then
        bad "journal: no line of $inst after the Close (was it run?)"
    elif awk -v d="$destroyed_ts" -v u="$unit_ts" 'BEGIN {exit !(d + 0 >= u + 0)}'; then
        ok "journal: the first pad destroyed ($destroyed_ts) is not before the game's unit ended ($unit_ts)"
    else
        echo "$first"
        bad "journal: a virtual pad was destroyed at $destroyed_ts, before the game's unit ended at $unit_ts"
    fi
    # The route changes only when the game is gone: the first `route shell` line after the Close is not before the unit's end.
    first="$(journalctl -u ruya-inputd --since "@${closets%.*}" --no-pager -o short-unix 2>/dev/null | grep -E "ruya-inputd: route (shell|locked) " | head -1)"
    if [ -n "$first" ] && [ -n "$unit_ts" ] && awk -v d="${first%% *}" -v u="$unit_ts" 'BEGIN {exit !(d + 0 >= u + 0)}'; then
        ok "journal: the route left the game only after its unit ended"
    else
        echo "$first"
        bad "journal: the route went to shell or locked before the game's unit ended (or no such line)"
    fi
    kill "$padpid" 2>/dev/null
    stop_all_apps >/dev/null 2>&1
}

# The first profile without a PIN, as "<index> <id>" in picker order (ListProfiles), or "".
profile_without_pin() {
    busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | python3 -c '
import re, sys
text = sys.stdin.read().split(" ", 2)[2]
rows = re.findall(r"\"([^\"]*)\" \"[^\"]*\" \"[^\"]*\" \"[^\"]*\" (true|false)", text)
for i, (pid, has_pin) in enumerate(rows):
    if has_pin == "false":
        print(i, pid, len(rows))
        break
'
}

active_profile() { busctl --system get-property "$psvc" "$ppath" "$psvc" ActiveProfile 2>/dev/null | cut -d'"' -f2; }

name_owned() { busctl --system status "$svc" >/dev/null 2>&1; }

# Waits up to $2 seconds for the shell's journal (since $since) to hold a line matching $1.
wait_shell_log() {
    local n=0
    while [ "$n" -lt "$(( $2 * 5 ))" ]; do
        journalctl -b _UID="$suid" --since "$since" --no-pager -o cat | grep -a -q "$1" && return 0
        sleep 0.2; n=$((n + 1))
    done
    return 1
}

fallback_restore() {
    systemctl unmask --runtime ruya-inputd >/dev/null 2>&1
    systemctl start ruya-inputd >/dev/null 2>&1
}

fallback_check() {
    echo "--- the emergency pad reader (RUY-410)"
    local row idx pid total ids padpid
    suid="$(id -u ruya-shell)"
    pgrep -u ruya-shell -x ruya-shell >/dev/null || { bad "the shell is not running"; return; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    systemctl is-active ruya-inputd >/dev/null || { bad "ruya-inputd is not active before the check"; return; }
    row="$(profile_without_pin)"
    if [ -z "$row" ]; then
        ids="$(profiles)"
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$(echo "$ids" | head -1)" 1234 "Check Pad" standard "" >/dev/null
        row="$(profile_without_pin)"
    fi
    [ -n "$row" ] || { bad "no profile without a PIN to sign in with"; return; }
    set -- $row; idx=$1; pid=$2; total=$3
    ok "the pad will sign in $pid (picker position $((idx + 1)) of $total)"

    since="$(date '+%Y-%m-%d %H:%M:%S')"
    trap fallback_restore EXIT
    systemctl mask --runtime --now ruya-inputd >/dev/null 2>&1
    sleep 0.5
    if name_owned; then bad "org.ruyaos.Input1 still has an owner after the mask"; fallback_restore; return; fi
    ok "ruya-inputd is masked and stopped: the name has no owner"
    if journalctl -b _UID="$suid" --since "$since" --no-pager -o cat | grep -a -q "ruya-shell: input fallback on"; then
        bad "the fallback was on at once (it waits 3 s)"
    else
        ok "not at once"
    fi
    wait_shell_log "ruya-shell: input fallback on" 6 && ok "journal: ruya-shell: input fallback on (within 6 s)" || bad "no 'input fallback on' line within 6 s"

    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
    local n=0; until [ -z "$(active_profile)" ] || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    [ -z "$(active_profile)" ] && ok "Lock: the picker is up" || bad "Lock left $(active_profile) signed in"
    sleep 1
    python3 "$probe" navpad --settle 3 --lefts "$total" --rights "$idx" > /var/tmp/ruya-input-navpad.log 2>&1 &
    padpid=$!
    n=0; until [ "$(active_profile)" = "$pid" ] || [ "$n" -ge 150 ]; do sleep 0.1; n=$((n + 1)); done
    if [ "$(active_profile)" = "$pid" ]; then
        ok "a uinput pad's D-pad and A moved the picker's focus and signed in $pid, with ruya-inputd masked"
    else
        bad "the pad did not sign in $pid (active '$(active_profile)'); probe: $(cat /var/tmp/ruya-input-navpad.log)"
    fi
    wait "$padpid" 2>/dev/null

    since="$(date '+%Y-%m-%d %H:%M:%S')"
    fallback_restore
    trap - EXIT
    n=0; until name_owned || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    name_owned && ok "unmask: ruya-inputd is back and owns org.ruyaos.Input1" || bad "the name has no owner after the unmask"
    wait_shell_log "ruya-shell: input fallback off" 5 && ok "journal: ruya-shell: input fallback off" || bad "no 'input fallback off' line within 5 s of the service's return"
    [ -n "$(nav_input)" ] && ok "the service's navigation keyboard is back" || bad "no RuyaOS Navigation device after the unmask"
    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
}

caps_check() {
    echo "--- capabilities and the button test (RUY-39)"
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    local padpid id caps out since n=0
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    python3 "$probe" pad 20 > /var/tmp/ruya-input-caps.log 2>&1 &
    padpid=$!
    # RUY-473: 15 s (the probe itself waits 3 s; right after restart_check's kill -9 of inputd 5 s was too short).
    until grep -q "^pad " /var/tmp/ruya-input-caps.log || [ "$n" -ge 150 ]; do sleep 0.1; n=$((n + 1)); done
    if ! grep -q "^pad ready" /var/tmp/ruya-input-caps.log; then
        bad "no test pad: $(cat /var/tmp/ruya-input-caps.log)"
        pgrep -af vm-input-probe
        ls -l /dev/uinput
        journalctl -u ruya-inputd --no-pager -n 20 2>&1
        kill "$padpid" 2>/dev/null
        return
    fi
    n=0
    until id="$(busctl --system --json=short call "$svc" "$path" "$ifc" ListDevices 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin)["data"][0]:
    if d.get("name", {}).get("data") == "Ruya VM Check Pad":
        print(d["id"]["data"])
')" && [ -n "$id" ] || [ "$n" -ge 30 ]; do sleep 0.1; n=$((n + 1)); done
    if [ -z "$id" ]; then bad "ListDevices does not list the uinput pad"; kill "$padpid" 2>/dev/null; return; fi
    ok "ListDevices lists the uinput pad as $id"
    caps="$(busctl --system --json=short call "$svc" "$path" "$ifc" GetCapabilities s "$id" 2>&1)"
    out="$(echo "$caps" | python3 -c '
import json, sys
status, caps = json.load(sys.stdin)["data"]
c = {name: (hw, drv, av, outp) for name, hw, drv, av, outp in caps}
want = {n: (True, True, True, True) for n in ("buttons", "sticks", "analog_triggers", "dpad", "rumble")}
want.update({n: (False, False, False, False) for n in ("gyro", "accelerometer", "touchpad", "trigger_rumble",
             "adaptive_triggers", "lightbar", "player_leds", "speaker", "microphone", "battery")})
bad = [f"{n} {c.get(n)} != {w}" for n, w in want.items() if c.get(n) != w]
print(status if not bad else status + ": " + "; ".join(bad))
' 2>&1)"
    [ "$out" = ok ] && ok "GetCapabilities: buttons, sticks, analog triggers, D-pad and rumble work and reach games; nothing else is claimed" || bad "GetCapabilities: $out ($caps)"
    out="$(busctl --system call "$svc" "$path" "$ifc" GetCapabilities s nope 2>&1)"
    case "$out" in *'"unknown-device"'*) ok "GetCapabilities of an unknown id: unknown-device" ;; *) bad "GetCapabilities nope: $out" ;; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" StartTest sb "$id" false 2>&1)"
    case "$out" in
    *'"ok"'*)
        sleep 1
        journalctl -u ruya-inputd --since "$since" --no-pager | grep -q "button test for $id ended: caller" \
            && ok "StartTest ok; the test ended when busctl left the bus" || bad "no 'button test for $id ended: caller' in the journal"
        ;;
    *'"not-allowed"'*) ok "StartTest: not-allowed (the route is $(busctl --system get-property "$svc" "$path" "$ifc" Route | cut -d'"' -f2))" ;;
    *) bad "StartTest: $out" ;;
    esac
    out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" StartTest sb "$id" true 2>&1)" && bad "nobody could call StartTest: $out" || ok "nobody cannot call StartTest"
    kill "$padpid" 2>/dev/null
    wait "$padpid" 2>/dev/null
}

# RUY-40: the family's own confirm button. A uinput pad announcing Nintendo's vendor id (0x057e) must
# give BTN_EAST = KEY_ENTER and BTN_SOUTH = KEY_ESC on RuyaOS Navigation; "south" swaps them back, "east"
# gives every family the right button; per controller since RUY-603 (a second pad keeps its own mode). An Accept must not reach a live Home (it launches an app,
# RUY-473), so the compositor (and with it the shell) is stopped for the block and restarted by the
# EXIT trap; the probe holds the route `shell` itself. Not part of `check` (it stops the screen).
confirm_restore() {
    systemctl start 'ruya-compositor@tty1' >/dev/null 2>&1
}

confirm_check() {
    echo "--- the family's confirm button, per controller (RUY-40, RUY-603)"
    stopped_shell_probe confirm
}

# RUY-479: StartTest's hold_left_stick, over the probe's own connection (a leaving caller ends a test).
hold_check() {
    echo "--- StartTest holds the left stick's arrow keys (RUY-479)"
    # The old one-argument call is refused: the signature is (s, b).
    local out
    out="$(busctl --system call "$svc" "$path" "$ifc" StartTest s nope 2>&1)" && bad "StartTest(s) was accepted: $out" || ok "StartTest(s) without the flag is refused"
    stopped_shell_probe hold
}

# ruya-inputd announces UserActive at most every 30 s, and the gate is one timestamp for the whole
# service; a check that counts UserActive restarts the service first, so a press of an earlier check
# (the queue runs `close` right before) cannot swallow its first announcement (lead-21, 0.0.83 queue).
fresh_activity_gate() {
    systemctl restart ruya-inputd || { bad "ruya-inputd did not restart"; return 1; }
    local n=0
    until busctl --system introspect org.ruyaos.Input1 /org/ruyaos/Input1 >/dev/null 2>&1 || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
    if [ "$n" -ge 50 ]; then bad "ruya-inputd is not on the bus 10 s after its restart"; return 1; fi
    ok "ruya-inputd restarted: the 30 s activity gate starts empty"
}

# The probe command $1 with the compositor (and the shell) stopped, so no Accept or arrow reaches Home.
stopped_shell_probe() {
    local what="$1"
    shift
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    systemctl is-active ruya-inputd >/dev/null || { bad "ruya-inputd is not active"; return; }
    trap confirm_restore EXIT
    systemctl stop 'ruya-compositor@tty1' >/dev/null 2>&1
    local n=0
    until ! pgrep -u ruya-shell -x ruya-shell >/dev/null || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
    if pgrep -u ruya-shell -x ruya-shell >/dev/null; then
        bad "the shell still runs: an Accept would reach Home"
        confirm_restore; trap - EXIT
        return
    fi
    ok "the compositor and the shell are stopped: no Accept can start anything"
    # The probe's lines are shown as they are; a FAIL: line, a traceback or a non-zero exit fails the check.
    local out rc=0
    out="$(cd "${probe_cwd:-.}" && python3 "${probe_py:-$probe}" "$what" "$@" --profile "$me" 2>&1)" || rc=$?
    [ -n "$out" ] && echo "$out"
    if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -qE '^(FAIL:|Traceback )'; then
        fail=1
    fi
    confirm_restore
    trap - EXIT
    ok "the compositor is started again"
}

# RUY-583: Start reaches the shell as Qt.Key_Menu (KEY_COMPOSE through xkb; KEY_MENU would be Qt.Key_MenuKB).
count_shell_log() {
    journalctl -b _UID="$suid" --since "$since" --no-pager -o cat | grep -a -c "$1"
}

# RUY-597: every path out of start_check closes a menu that may be open (Back; harmless on a closed menu).
start_check() {
    start_steps
    [ -f /root/vm-inject-key.py ] && python3 /root/vm-inject-key.py back >/dev/null 2>&1
    return 0
}

start_steps() {
    echo "--- Start opens the Options menu (RUY-583)"
    local padpid n
    suid="$(id -u ruya-shell)"
    pgrep -u ruya-shell -x ruya-shell >/dev/null || { bad "the shell is not running"; return; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; return; }
    [ -f /root/vm-inject-key.py ] || { bad "/root/vm-inject-key.py is missing: copy it there"; return; }
    stop_all_apps || { bad "an app is still running after Stop"; return; }
    settle_route || return
    sleep 2
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    # Open with the pad's Start, close with its second Start.
    python3 "$probe" navpad --settle 3 --start 2 > /var/tmp/ruya-input-start.log 2>&1 &
    padpid=$!
    wait "$padpid" 2>/dev/null
    grep -q "^pad ready" /var/tmp/ruya-input-start.log || { bad "no test pad: $(cat /var/tmp/ruya-input-start.log)"; return; }
    sleep 1
    n="$(count_shell_log 'ruya-shell: options menu open (')"
    if [ "$n" = 1 ]; then
        ok "pad Start: the shell logged one 'options menu open' line ($(journalctl -b _UID="$suid" --since "$since" --no-pager -o cat | grep -a 'options menu open' | head -1))"
    else
        bad "pad Start (two taps): $n 'options menu open' lines, expected 1 (0 means Start never reached the shell as Qt.Key_Menu, or Home had no focused card: the shell logs no signal for that, so install a game first)"
    fi
    # The second tap closed it: the keyboard path (KEY_COMPOSE) opens it again.
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    python3 /root/vm-inject-key.py menu >/dev/null 2>&1
    sleep 1
    n="$(count_shell_log 'ruya-shell: options menu open (')"
    [ "$n" = 1 ] && ok "KEY_COMPOSE from a keyboard opens it too" || bad "KEY_COMPOSE: $n 'options menu open' lines, expected 1"
}

case "${1:-check}" in
start)
    two_profiles
    [ -n "$me" ] && ok "profile $me signs in" || { bad "need a profile"; exit 1; }
    start_check
    ;;
confirm)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    confirm_check
    ;;
twopads)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; exit 1; }
    dir="$(mktemp -d /var/tmp/ruya-input-check.XXXXXX)"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    # With the compositor and the shell stopped (RUY-573): the shell's own SetRoute calls (its start,
    # a South press signing a no-PIN profile in) land between the probe's and fail it at random.
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe twopads --user "ruya-$me" --other "$other"
    # RUY-541: on each entry to `app` pad2 is made only after pad1 is ready (its ACL set), so a game that
    # opens the first pad it can open gets pad1. "<entries> <pad2 made before pad1 was ready>".
    order="$(journalctl -u ruya-inputd --since "$since" --no-pager -o cat \
        | grep -E 'virtual pad ruya-input/pad[12] (created|ready) ' \
        | awk '/pad1 created/ {r = 0} /pad1 ready/ {r = 1} /pad2 created/ {n++; if (!r) early++} END {print n + 0, early + 0}')"
    case "$order" in
        "0 "*) bad "journal: no pad2 was made during twopads" ;;
        *" 0") ok "journal: pad2 was made after pad1 was ready, ${order%% *} times" ;;
        *) bad "journal: pad2 was made before pad1 was ready (entries, early: $order)" ;;
    esac
    echo "--- a profile per pad (RUY-545)"
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe twoprofiles --user "ruya-$me" --other "$other"
    rm -rf "$dir"
    ;;
players)
    # RUY-121: the players' seats, with three uinput pads and a profile made for player 2 (removed at the end).
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; exit 1; }
    two_profiles
    [ -n "$me" ] && ok "profile $me signs in" || { bad "need a profile"; exit 1; }
    echo "--- the players' seats (RUY-121): a second profile for player 2"
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$me" 1234 "Check Player" standard "")"
    player2=""; case "$out" in 'ssuu "ok" '*) player2="$(echo "$out" | cut -d'"' -f4)" ;; esac
    [ -n "$player2" ] && ok "CreateProfile made $player2 (Check Player)" || { bad "CreateProfile Check Player: $out"; echo "SOME CHECKS FAILED"; exit 1; }
    dir="$(mktemp -d "${CHECK_TMP:-/var/tmp}/ruya-input-check.XXXXXX")"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe players --user "ruya-$me" --other "$player2"
    rm -rf "$dir"
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$me" 1234 "$player2")"
    case "$out" in 'suu "ok"'*) ok "DeleteProfile $player2: the check's profile is removed" ;; *) bad "DeleteProfile $player2: $out" ;; esac
    ;;
useractive)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; exit 1; }
    dir="$(mktemp -d /var/tmp/ruya-input-check.XXXXXX)"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    echo "--- pad input to a game is announced as activity, at most every 30 s (RUY-588)"
    fresh_activity_gate || exit 1
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe useractive
    rm -rf "$dir"
    ;;
signals)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; exit 1; }
    dir="$(mktemp -d /var/tmp/ruya-input-check.XXXXXX)"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    echo "--- Input1's signals reach only root and ruya-shell (RUY-594)"
    fresh_activity_gate || exit 1
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe signals --user "ruya-$me"
    rm -rf "$dir"
    ;;
guide)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    [ -f "$probe" ] || { bad "$probe is missing: copy it next to this script"; exit 1; }
    dir="$(mktemp -d /var/tmp/ruya-input-check.XXXXXX)"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    echo "--- Guide never reaches a game (RUY-11)"
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe guide --user "ruya-$me" --other "$other"
    rm -rf "$dir"
    ;;
nodes)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    dir="$(mktemp -d /var/tmp/ruya-input-check.XXXXXX)"
    chmod 0755 "$dir"
    install -m 0644 "$probe" "$dir/vm-input-probe.py"
    probe_cwd="$dir" probe_py="$dir/vm-input-probe.py" stopped_shell_probe nodes --user "ruya-$me"
    rm -rf "$dir"
    ;;
hold)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    hold_check
    ;;
check)
    two_profiles
    [ -n "$me" ] && [ -n "$other" ] && ok "profiles: $me signs in, $other is the other user" || { bad "need two profiles"; exit 1; }
    prepare_state
    unit_check && routing_check
    restore_state
    restart_check
    security_check
    caps_check
    profiles_check
    ;;
restart) restart_check ;;
caps) caps_check ;;
profiles)
    two_profiles
    [ -n "$me" ] && ok "profile $me" || { bad "need a profile"; exit 1; }
    profiles_check
    ;;
security) security_check ;;
fallback) fallback_check ;;
shell)
    two_profiles
    [ -n "$me" ] && ok "profile $me signs in" || { bad "need a profile"; exit 1; }
    shell_check
    ;;
close)
    two_profiles
    [ -n "$me" ] && ok "profile $me signs in" || { bad "need a profile"; exit 1; }
    close_check
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
