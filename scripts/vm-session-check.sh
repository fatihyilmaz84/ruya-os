#!/usr/bin/env bash
# Checks ruya-session (org.ruyaos.Session1, T-162) inside a running VM, as root. It builds a tiny
# local Flatpak repository (one runtime made of the guest's own bash and sleep, two command-line
# apps: one that sleeps, one that exits 3), installs it system-wide,
# creates a profile through Profiles1 if there is none, and drives Launch / Stop over the system
# bus as ruya-shell. Copy and run (boot with plain smoke-test.ps1 -Keep):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-session-check.sh scripts/vm-session-probe.qml root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-session-check.sh [check|restart|security|clean]
# `restart` (T-290) needs a profile (run `check` once on an empty store, or create one) and
# installs the test apps itself when they are missing.
# On an empty profile store the check creates the admin "Check Admin" (PIN 1234) and a standard
# profile "Check Kid", runs the apps as the kid and deletes it at the end (which also checks that a
# profile with a lingering manager and a running app can be deleted); the admin stays. Profiles
# that were there before are used as they are and not deleted.
set -u
svc=org.ruyaos.Session1
path=/org/ruyaos/Session1
ifc=org.ruyaos.Session1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
rt=org.ruyaos.TestRuntime
sleeper=org.ruyaos.TestSleeper
crasher=org.ruyaos.TestCrasher
remote=ruyaos-session-test
work=/var/lib/ruya-session-test
uid="$(id -u ruya-shell)"
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

as_shell() { runuser -u ruya-shell -- "$@"; }
launch() { as_shell busctl --system call "$svc" "$path" "$ifc" Launch ss "$1" "$2"; }
stop_app() { as_shell busctl --system call "$svc" "$path" "$ifc" Stop s "$1"; }
running() { as_shell busctl --system --json=short call "$svc" "$path" "$ifc" ListRunning; }
# The unit name out of 'ss "ok" "ruya-app-..."'.
unit_of() { sed -n 's/^ss "ok" "\(.*\)"$/\1/p'; }
# Waits for a line of the signal log (an extended-regex pattern), up to $2 seconds.
wait_sig() {
    n=0
    while [ "$n" -lt "$2" ]; do
        grep -E -q "$1" "$work/signals.log" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}
# Waits until `$1` (a command line) has no process of the profile user ($user, else ruya-p1) any more, up to 15 s.
gone() {
    n=0
    while pgrep -u "${user:-ruya-p1}" -f "$1" >/dev/null 2>&1; do
        [ "$n" -ge 15 ] && return 1
        sleep 1; n=$((n + 1))
    done
}

build_repo() {
    rm -rf "$work"; mkdir -p "$work/rt/usr/bin" "$work/rt/usr/lib64" "$work/rt/files" "$work/rt/var"
    # The runtime's /usr: bash as sh and bash, sleep, and the libraries they load.
    for b in bash sleep; do cp "/usr/bin/$b" "$work/rt/usr/bin/$b" || return 1; done
    cp "/usr/bin/bash" "$work/rt/usr/bin/sh"
    for lib in $(ldd /usr/bin/bash /usr/bin/sleep | awk '/=> \//{print $3} /ld-linux/{print $1}' | sort -u); do
        cp "$lib" "$work/rt/usr/lib64/" || return 1
    done
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    flatpak build-export --runtime "$work/repo" "$work/rt" stable >/dev/null 2>&1 || return 1
    for spec in "$sleeper|exec sleep 3000" \
                "$crasher|sleep 1; exit 3"; do
        id="${spec%%|*}"; body="${spec#*|}"
        mkdir -p "$work/$id/files/bin" "$work/$id/var"
        printf '#!/bin/sh\n%s\n' "$body" > "$work/$id/files/bin/run"; chmod 755 "$work/$id/files/bin/run"
        printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=run\n' "$id" "$rt" "$rt" > "$work/$id/metadata"
        flatpak build-finish --command=run "$work/$id" >/dev/null 2>&1 || return 1
        flatpak build-export "$work/repo" "$work/$id" stable >/dev/null 2>&1 || return 1
    done
}

case "${1:-check}" in
security)
    systemd-analyze security ruya-session --no-pager | tail -14
    ls -Zd /var/lib/ruya-session /var/lib/ruya-session/usage 2>&1
    ;;
restart)
    echo "--- a profile and the test apps"
    pid="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tail -1 | tr -d '"')"
    [ -n "$pid" ] && ok "profile $pid" || { bad "no profile: run 'check' on an empty store first"; exit 1; }
    user="ruya-$pid"
    if ! flatpak info --system "$sleeper" >/dev/null 2>&1; then
        build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
        flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" || { bad "remote-add"; exit 1; }
        flatpak install --system -y --noninteractive "$remote" "$rt" "$sleeper" "$crasher" >/dev/null 2>&1             && ok "test apps installed" || { bad "flatpak install of the test apps failed"; exit 1; }
    fi
    mkdir -p "$work"
    systemctl --user -M "$user@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null
    pkill -u "$user" -f "sleep 3000" 2>/dev/null
    : > "$work/signals.log"
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2

    echo "--- Launch, then restart ruya-session while the app runs"
    out="$(launch "$sleeper" "$pid")"; echo "$out"
    inst="$(echo "$out" | unit_of)"
    [ -n "$inst" ] && ok "Launch answered ok ($inst)" || { bad "Launch: $out"; exit 1; }
    wait_sig "\"member\":\"AppStarted\".*$sleeper" 30 && ok "AppStarted arrived" || bad "no AppStarted within 30 s"
    pgrep -u "$user" -f "sleep 3000" >/dev/null && ok "the app runs" || bad "no sleep process of $user"
    kill "$mon" 2>/dev/null
    systemctl restart ruya-session && ok "ruya-session restarted" || bad "restart failed"
    n=0
    until running >/dev/null 2>&1 || [ "$n" -ge 60 ]; do sleep 1; n=$((n + 1)); done
    run="$(running)"; echo "$run"
    echo "$run" | grep -q "$inst" && echo "$run" | grep -q '"running"'         && ok "ListRunning still lists it as running (name back after about $n s)" || bad "ListRunning after the restart: $run"
    echo "$run" | grep -q "\"$pid\"" && ok "ListRunning names the profile $pid" || bad "profile missing after the restart"
    echo "$run" | grep -q "\"$sleeper\"" && ok "ListRunning names the app" || bad "app id missing after the restart"
    pgrep -u "$user" -f "sleep 3000" >/dev/null && ok "the app was not touched by the restart" || bad "the app died with the restart"
    journalctl -u ruya-session -b --no-pager | grep -a "adopted $inst" | tail -1
    journalctl -u ruya-session -b --no-pager | grep -a -q "adopted $inst" && ok "the journal says it was adopted" || bad "no 'adopted' line in the journal"
    case "$(launch "$sleeper" "$pid")" in 'ss "already-running" ""') ok "a relaunch: already-running";; *) bad "relaunch after the restart";; esac

    : > "$work/signals.log"
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2
    echo "--- Stop an adopted app"
    t0="$(date +%s)"
    case "$(stop_app "$inst")" in 's "ok"') ok "Stop answered ok";; *) bad "Stop after the restart";; esac
    wait_sig "\"member\":\"AppExited\".*$sleeper" 30         && ok "AppExited arrived after $(( $(date +%s) - t0 )) s" || bad "no AppExited within 30 s"
    grep -E "\"member\":\"AppExited\".*$sleeper" "$work/signals.log" | head -1
    grep -E "\"member\":\"AppExited\".*$sleeper" "$work/signals.log" | grep -q '"quit"' && ok "reason quit" || bad "reason is not quit"
    gone "sleep 3000" && ok "the app's process is gone" || bad "the app is still running after Stop"
    running | grep -q "$inst" && bad "ListRunning still lists it" || ok "ListRunning is empty again"
    out="$(launch "$sleeper" "$pid")"; inst2="$(echo "$out" | unit_of)"
    [ -n "$inst2" ] && ok "a new Launch works again ($inst2)" || bad "Launch after the stop: $out"
    stop_app "$inst2" >/dev/null
    n=0; until ! running | grep -q "$inst2" || [ "$n" -ge 20 ]; do sleep 1; n=$((n + 1)); done

    echo "--- an adopted app killed from outside (reason is informational)"
    out="$(launch "$sleeper" "$pid")"; inst3="$(echo "$out" | unit_of)"
    sleep 3
    if pgrep -u "$user" -f "sleep 3000" >/dev/null; then ok "the app to be adopted runs"; else
        bad "the third launch did not stay up"
        echo "$out"; journalctl -M "$user@.host" --no-pager -n 25 2>&1 | cut -c1-220; journalctl -u ruya-session -b --no-pager -n 12 | cut -c1-220
    fi
    systemctl restart ruya-session; n=0
    until running >/dev/null 2>&1 || [ "$n" -ge 60 ]; do sleep 1; n=$((n + 1)); done
    : > "$work/signals.log"
    kill "$mon" 2>/dev/null
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2
    systemctl --user -M "$user@.host" kill --signal=SIGKILL --kill-whom=all "app-flatpak-$sleeper-*.scope" </dev/null 2>&1 | cat
    wait_sig "\"member\":\"AppExited\".*$sleeper" 30 && ok "AppExited arrived for the adopted app that was killed" || bad "no AppExited for the killed adopted app"
    grep -E "\"member\":\"AppExited\".*$sleeper" "$work/signals.log" | head -1
    running | grep -q "$inst3" && bad "ListRunning still lists the killed app" || ok "the killed app is no longer listed"

    echo "--- unit security and the label of the state directory"
    systemd-analyze security ruya-session --no-pager | tail -14
    ls -Zd /var/lib/ruya-session /var/lib/ruya-session/usage 2>&1
    kill "$mon" 2>/dev/null
    flatpak uninstall --system -y "$sleeper" "$crasher" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    journalctl -u ruya-session -b --no-pager -p warning | tail -5
    ;;
clean)
    flatpak uninstall --system -y "$sleeper" "$crasher" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    ;;
check)
    echo "--- unit and bus name"
    systemctl is-active ruya-session && ok "ruya-session is active" || bad "ruya-session not active"
    busctl --system status "$svc" | grep -E '^(UID|Comm)='
    busctl --system status "$svc" | grep -q '^UID=0$' && ok "root owns the name" || bad "the name is not owned by root"

    echo "--- bus policy"
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListRunning 2>&1)"; then
        bad "nobody can call ListRunning: $out"
    else
        echo "$out"; ok "a caller other than ruya-shell is refused by the bus policy"
    fi
    as_shell busctl --system call "$svc" "$path" "$ifc" ListRunning >/dev/null 2>&1 && ok "ruya-shell may call it" || bad "ruya-shell cannot call ListRunning"

    echo "--- a profile to run apps as"
    created=0
    pid="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
    if [ -z "$pid" ]; then
        # An empty store: the first admin needs no credentials; the apps run as a standard
        # profile next to it, which the check deletes again (the last admin cannot be).
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "" "" "Check Admin" admin 1234
        admin="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$admin" 1234 "Check Kid" standard ""
        pid="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | grep -v "\"$admin\"" | head -1 | tr -d '"')"
        created=1
    fi
    [ -n "$pid" ] && ok "profile $pid (created by the check: $created)" || { bad "no profile"; exit 1; }
    user="ruya-$pid"

    echo "--- build and install the test apps"
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" || { bad "remote-add"; exit 1; }
    flatpak install --system -y --noninteractive "$remote" "$rt" "$sleeper" "$crasher" >/dev/null 2>&1 \
        && ok "test apps installed" || { bad "flatpak install of the test apps failed"; exit 1; }
    # Not as a lingering manager's guest: the first launch must work from a cold start.
    loginctl show-user "$user" -p Linger 2>/dev/null | grep -q yes && echo "(linger already on for $user)"

    # Apps left running by an earlier run (the service forgets them when it restarts).
    systemctl --user -M "$user@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null
    : > "$work/signals.log"
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2

    echo "--- Launch"
    out="$(launch "$sleeper" "$pid")"; echo "$out"
    inst="$(echo "$out" | unit_of)"
    [ -n "$inst" ] && ok "Launch answered ok with an instance ($inst)" || { bad "Launch: $out"; exit 1; }
    wait_sig "\"member\":\"AppStarted\".*$sleeper" 30 && ok "AppStarted arrived" || bad "no AppStarted within 30 s"
    run="$(running)"; echo "$run"
    echo "$run" | grep -q "$inst" && echo "$run" | grep -q '"running"' && ok "ListRunning shows it as running" || bad "ListRunning: $run"
    echo "$run" | grep -q "\"$pid\"" && ok "ListRunning names the profile $pid" || bad "profile missing from ListRunning"
    pgrep -u "$user" -f "sleep 3000" >/dev/null && ok "the app's process runs as $user" || bad "no sleep process of $user"
    pgrep -u ruya-shell -f "sleep 3000" >/dev/null && bad "an app process runs as ruya-shell" || ok "no app process runs as ruya-shell"
    pgrep -u root -f "sleep 3000" >/dev/null && bad "an app process runs as root" || ok "no app process runs as root"
    # 2>&1 into a pipe: a call over -M hands its stderr to PID 1, which SELinux lets write a pipe
    # of this shell but not the log file this script's output goes to (the call would hang).
    systemctl --user -M "$user@.host" is-active "$inst" </dev/null 2>&1 | grep -q '^active$' && ok "the unit is active in $user's manager" || bad "unit not active in the user manager"
    loginctl show-user "$user" -p Linger | grep -q yes && ok "the manager of $user lingers" || bad "no linger"
    if pgrep -u "$user" 'pipewire|wireplumber' >/dev/null; then bad "$user runs PipeWire or WirePlumber (ADR-010)"; ps -u "$user" -o args | head; else ok "$user runs no PipeWire or WirePlumber"; fi

    echo "--- the shell's own Session singleton (D-Bus backend)"
    cp /root/vm-session-probe.qml "$work/probe.qml" && chmod 755 "$work" && chmod 644 "$work/probe.qml"
    : > "$work/probe.log"; chmod 666 "$work/probe.log"
    as_shell env XDG_RUNTIME_DIR="/run/user/$uid" QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        timeout 100 ruya-shell --load "$work/probe.qml" > "$work/probe.log" 2>&1 &
    n=0
    until grep -a -q "session-probe: mock=false running=.*$sleeper/$pid/running" "$work/probe.log" || [ "$n" -ge 60 ]; do sleep 1; n=$((n + 1)); done
    grep -a "session-probe" "$work/probe.log" | tail -3
    grep -a -q "session-probe: mock=false running=.*$sleeper/$pid/running" "$work/probe.log" \
        && ok "the shell's Session.running follows the Launch (after about $n s)" || bad "the shell's Session did not show the running app"

    echo "--- Launch refusals"
    case "$(launch "$sleeper" "$pid")" in 'ss "already-running" ""') ok "a second Launch: already-running";; *) bad "second Launch";; esac
    case "$(launch org.ruyaos.NotInstalled "$pid")" in 'ss "unknown-app" ""') ok "unknown-app";; *) bad "unknown app";; esac
    case "$(launch "$sleeper" zz9)" in 'ss "unknown-profile" ""') ok "an unknown profile: unknown-profile";; *) bad "unknown profile";; esac
    case "$(launch "$sleeper" root)" in 'ss "unknown-profile" ""') ok "root is not a profile: unknown-profile";; *) bad "profile root";; esac
    case "$(launch "$sleeper" ruya-shell)" in 'ss "unknown-profile" ""') ok "ruya-shell is not a profile: unknown-profile";; *) bad "profile ruya-shell";; esac
    case "$(launch "x;y" "$pid")" in 'ss "invalid" ""') ok "a bad app id: invalid";; *) bad "invalid app id";; esac
    case "$(stop_app nope.service)" in 's "unknown-instance"') ok "Stop of an unknown instance: unknown-instance";; *) bad "unknown instance";; esac

    echo "--- Stop"
    t0="$(date +%s)"
    case "$(stop_app "$inst")" in 's "ok"') ok "Stop answered ok";; *) bad "Stop";; esac
    wait_sig "\"member\":\"AppExited\".*$sleeper.*\"quit\"" 20 && ok "AppExited with reason quit after $(( $(date +%s) - t0 )) s" || bad "no AppExited quit within 20 s"
    gone "sleep 3000" && ok "Stop ended the app itself, not only the unit (its scope is gone)" || bad "the app's process is still there after Stop"
    running | grep -q "$inst" && bad "ListRunning still lists it" || ok "ListRunning is empty again"
    grep -a -q "session-probe: appExited $sleeper 0 quit\|session-probe: appExited $sleeper -\?[0-9]* quit" "$work/probe.log" && ok "the shell saw appExited quit" || bad "the shell did not see appExited quit"

    echo "--- an app that exits non-zero"
    out="$(launch "$crasher" "$pid")"; inst2="$(echo "$out" | unit_of)"
    [ -n "$inst2" ] && ok "Launch of the crasher: $inst2" || bad "Launch crasher: $out"
    wait_sig "\"member\":\"AppExited\".*$crasher" 30 && ok "AppExited arrived" || bad "no AppExited for the crasher"
    line="$(grep -E "\"member\":\"AppExited\".*$crasher" "$work/signals.log" | head -1)"
    echo "$line" | grep -q '"crashed"' && echo "$line" | grep -q ',3,' && ok "reason crashed, exit code 3" || bad "crasher exit: $line"

    echo "--- an app killed from outside (SIGKILL to its scope)"
    out="$(launch "$sleeper" "$pid")"; inst3="$(echo "$out" | unit_of)"
    [ -n "$inst3" ] && ok "Launch: $inst3" || bad "Launch for the kill: $out"
    n0="$(grep -c "\"member\":\"AppStarted\"" "$work/signals.log")"
    n=0; while [ "$(grep -c "\"member\":\"AppStarted\"" "$work/signals.log")" -le "$n0" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
    systemctl --user -M "$user@.host" kill --signal=SIGKILL --kill-whom=all "app-flatpak-$sleeper-*.scope" </dev/null 2>&1 | cat
    n=0; while [ "$(grep -c "\"member\":\"AppExited\".*$sleeper" "$work/signals.log")" -lt 2 ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    line="$(grep -E "\"member\":\"AppExited\".*$sleeper" "$work/signals.log" | tail -1)"
    echo "$line" | grep -q '"killed"' && ok "a SIGKILL from the system: reason killed" || bad "killed exit: $line"
    gone "sleep 3000" && ok "its process is gone" || bad "the process survived"

    echo "--- Launch while the unit of an earlier run is gone: a fresh launch works again"
    out="$(launch "$sleeper" "$pid")"; inst4="$(echo "$out" | unit_of)"
    [ -n "$inst4" ] && ok "Launch again: $inst4" || bad "Launch again: $out"
    wait_sig "\"member\":\"AppStarted\".*$sleeper.*" 30 >/dev/null

    echo "--- deleting a profile whose manager lingers and whose app runs"
    if [ "$created" = 1 ]; then
        out="$(busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$admin" 1234 "$pid")"
        echo "$out"
        case "$out" in 'suu "ok"'*) ok "DeleteProfile answered ok";; *) bad "DeleteProfile: $out";; esac
        id "$user" >/dev/null 2>&1 && bad "the Unix user $user still exists" || ok "the Unix user $user is gone"
        [ -e "/var/lib/systemd/linger/$user" ] && bad "the linger file is still there" || ok "the linger file is gone"
    else
        echo "(the profile was there before the check: not deleted)"
        stop_app "$inst4" >/dev/null
    fi
    kill "$mon" 2>/dev/null
    pkill -f "probe[.]qml" 2>/dev/null
    flatpak uninstall --system -y "$sleeper" "$crasher" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    echo "--- journal of the service (warnings)"
    journalctl -u ruya-session -b --no-pager -p warning | tail -5
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
