#!/usr/bin/env bash
# Checks ruya-session (org.ruyaos.Session1, T-162) inside a running VM, as root. It builds a tiny
# local Flatpak repository (one runtime made of the guest's own bash and sleep, two command-line
# apps: one that sleeps, one that exits 3), installs it system-wide,
# creates a profile through Profiles1 if there is none, and drives Launch / Stop over the system
# bus as ruya-shell. Copy and run (boot with plain smoke-test.ps1 -Keep):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-session-check.sh scripts/vm-session-probe.qml root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-session-check.sh [check|restart|security|display|display-clean|clean]
# `display` (T-164) checks the per-profile Wayland sockets and a profile's window in the app layer, and (T-376)
# that no ruya-shell PipeWire output stream exists with that window in front;
# it also needs vm-key-client.qml and vm-inject-key.py in /root (see the `display)` case).
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
wclient=org.ruyaos.TestWaylandClient
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
    # The Wayland test app (T-164): the key-logging test client (vm-key-client.qml, next to this
    # script) run by the image's own Qt, reached through --filesystem=host-os (no Qt in the test
    # runtime). --socket=wayland is what forwards the profile's socket into the sandbox. It prints
    # what it sees of the display first: the socket must be there, the directory of all sockets not.
    if [ -f /root/vm-key-client.qml ]; then
        id="$wclient"
        mkdir -p "$work/$id/files/bin" "$work/$id/files/share" "$work/$id/var"
        cp /root/vm-key-client.qml "$work/$id/files/share/key-client.qml" || return 1
        cat > "$work/$id/files/bin/run" <<'EOF'
#!/bin/sh
sock=no; [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && sock=yes
dir=no; [ -e /run/ruya-wayland ] && dir=yes
echo "test-wayland-client: uid=$UID WAYLAND_DISPLAY=$WAYLAND_DISPLAY socket=$sock socket-dir-visible=$dir"
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1
export QT_PLUGIN_PATH=/run/host/usr/lib64/qt6/plugins QML_IMPORT_PATH=/run/host/usr/lib64/qt6/qml
exec /run/host/usr/lib64/ld-linux-x86-64.so.2 --library-path /run/host/usr/lib64:/run/host/usr/lib64/pulseaudio:/run/host/usr/lib64/libproxy /run/host/usr/bin/ruya-shell --load /app/share/key-client.qml
EOF
        chmod 755 "$work/$id/files/bin/run"
        printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=run\n' "$id" "$rt" "$rt" > "$work/$id/metadata"
        flatpak build-finish --command=run --socket=wayland --filesystem=host-os:ro "$work/$id" >/dev/null 2>&1 || return 1
        flatpak build-export "$work/repo" "$work/$id" stable >/dev/null 2>&1 || return 1
    fi
}

# Can `$1` (a user) connect to the socket `$2`? Prints "connected" or the error.
probe_connect() {
    runuser -u "$1" -- python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("connected")
except OSError as e:
    print(type(e).__name__, e)' "$2" 2>&1 | tail -1
}
# The shell's journal since the unix second $1.
shell_log_since() { journalctl -b _UID="$uid" --since "@$1" --no-pager -o cat 2>/dev/null; }
# Waits for an extended-regex line $1 in the shell's journal since $2, up to $3 seconds.
wait_shell() {
    n=0
    while [ "$n" -lt "$3" ]; do
        shell_log_since "$2" | grep -a -E -q "$1" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}

case "${1:-check}" in
security)
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
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

    echo "--- Stop, then Launch at once (T-340): no already-running, no taken unit name"
    out="$(launch "$sleeper" "$pid")"; inst4="$(echo "$out" | unit_of)"
    [ -n "$inst4" ] && ok "Launch answered ok ($inst4)" || bad "Launch before the quick relaunch: $out"
    sleep 3
    stop_app "$inst4" >/dev/null
    out="$(launch "$sleeper" "$pid")"; echo "$out"
    case "$out" in
    *already-running*) bad "a launch right after Stop answered already-running";;
    *'s "ok"'*|*'ss "ok"'*) ok "a launch right after Stop worked: $(echo "$out" | unit_of)";;
    *) bad "a launch right after Stop: $out";;
    esac
    inst4="$(echo "$out" | unit_of)"
    sleep 3
    stop_app "$inst4" >/dev/null
    n=0; until ! running | grep -q "$inst4" || [ "$n" -ge 20 ]; do sleep 1; n=$((n + 1)); done

    echo "--- an adopted app killed from outside (real exit status, T-340)"
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
    # While the adopted app runs, the service follows it over its connection to the user manager:
    # no `systemctl` process may be started for it (T-340; before it was one per unit every 2 s).
    # The Flatpak scope watcher's `show` of the unit and its app-flatpak-*.scope every 5 s (T-363,
    # scope.rs WATCH_EVERY) is a different poll and is not counted here.
    n=0; spawned=0
    while [ "$n" -lt 20 ]; do
        pgrep -af "systemctl.*ruya-app" | grep -v "app-flatpak-" | grep -q systemctl && spawned=$((spawned + 1))
        sleep 0.3; n=$((n + 1))
    done
    pgrep -u "$user" -f systemd-stdio-bridge >/dev/null && ok "the bridge to the manager of $user is running" || bad "no systemd-stdio-bridge of $user: the service has no connection to the manager"
    [ "$spawned" -eq 0 ] && ok "no systemctl process while following the adopted app (6 s)" || bad "systemctl ran $spawned times in 6 s while following"
    journalctl -u ruya-session -b --no-pager | grep -a "no connection to the manager" | tail -2
    systemctl --user -M "$user@.host" kill --signal=SIGKILL --kill-whom=all "app-flatpak-$sleeper-*.scope" </dev/null 2>&1 | cat
    wait_sig "\"member\":\"AppExited\".*$sleeper" 30 && ok "AppExited arrived for the adopted app that was killed" || bad "no AppExited for the killed adopted app"
    grep -E "\"member\":\"AppExited\".*$sleeper" "$work/signals.log" | head -1
    # The status comes from the manager's own signals now: a killed app is no clean `quit`.
    if grep -E "\"member\":\"AppExited\".*$sleeper" "$work/signals.log" | grep -q '"quit"'; then
        echo "NOTE: the killed adopted app was reported as quit (the old poll's default); look at the exit code above"
    else
        ok "the killed adopted app was not reported as a clean quit"
    fi
    running | grep -q "$inst3" && bad "ListRunning still lists the killed app" || ok "the killed app is no longer listed"

    echo "--- unit security and the label of the state directory"
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
    ls -Zd /var/lib/ruya-session /var/lib/ruya-session/usage 2>&1
    kill "$mon" 2>/dev/null
    flatpak uninstall --system -y "$sleeper" "$crasher" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    journalctl -u ruya-session -b --no-pager -p warning | tail -5
    ;;
display)
    # T-164 (ADR-023): per-profile Wayland sockets. Needs a profile with no PIN or PIN 1234 (the
    # first one listed signs in; vm-goto.ps1 makes "Player One", admin, PIN 1234) and leaves the
    # profile's test window open for a VM screenshot; `display-clean` ends it.
    # Also copy vm-key-client.qml and vm-inject-key.py next to this script.
    for f in /root/vm-key-client.qml /root/vm-inject-key.py; do
        [ -f "$f" ] || { bad "$f is missing: copy it next to this script"; exit 1; }
    done
    dir=/run/ruya-wayland
    # T-358: the patched linux-dmabuf plugin is loaded (v4 with a GPU render node, v3 without one,
    # as in a VM on llvmpipe); the line is logged once when the compositor starts.
    dmabuf="$(journalctl -b --no-pager -o cat | grep -a -m1 "linux-dmabuf: zwp_linux_dmabuf_v1 version")"
    [ -n "$dmabuf" ] && ok "the compositor serves linux-dmabuf: $dmabuf" || bad "no linux-dmabuf line from the compositor (T-358 plugin not loaded)"
    ids="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"')"
    me="$(echo "$ids" | head -1)"
    [ -n "$me" ] && ok "profile $me signs in" || { bad "no profile: make one with vm-goto.ps1 home"; exit 1; }
    other="$(echo "$ids" | grep -v "^$me\$" | head -1)"
    created_other=0
    if [ -z "$other" ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$me" 1234 "Check Other" standard "" >/dev/null
        other="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"' | grep -v "^$me\$" | head -1)"
        created_other=1
    fi
    [ -n "$other" ] && ok "second profile $other (created by the check: $created_other)" || { bad "no second profile"; exit 1; }
    echo "$other $created_other" > /root/vm-display-other
    user="ruya-$me"; ouser="ruya-$other"
    muid="$(id -u "$user")"; ouid="$(id -u "$ouser")"
    sock="$dir/$user"; osock="$dir/$ouser"

    echo "--- the sockets"
    n=0; until [ -S "$sock" ] && [ -S "$osock" ] || [ "$n" -ge 30 ]; do sleep 1; n=$((n + 1)); done
    stat -c '%A %U:%G %n' "$dir" "$sock" "$osock" 2>&1
    getfacl -p "$sock" 2>&1 | grep -v '^#'
    [ "$(stat -c '%a %U' "$dir")" = "711 ruya-shell" ] && ok "$dir: 0711, owned by ruya-shell" || bad "$dir mode/owner: $(stat -c '%a %U' "$dir")"
    [ -S "$sock" ] && [ "$(stat -c %U "$sock")" = ruya-shell ] && ok "$sock is a socket of ruya-shell" || bad "no socket $sock"
    [ -S "$osock" ] && ok "$osock exists too (a socket per profile)" || bad "no socket $osock"
    acl="$(getfacl -p "$sock" 2>/dev/null | grep -v '^#' | grep -v '^$' | tr '\n' ' ')"
    [ "$acl" = "user::rw- user:$user:rw- group::--- mask::rw- other::--- " ] && ok "ACL: only $user (and the owner) may write it" || bad "ACL of $sock: $acl"
    if runuser -u "$ouser" -- ls "$dir" >/dev/null 2>&1; then bad "$ouser can list $dir"; else ok "$ouser cannot list $dir"; fi
    out="$(probe_connect "$user" "$sock")"; [ "$out" = connected ] && ok "$user connects to its own socket" || bad "$user -> own socket: $out"
    out="$(probe_connect "$ouser" "$sock")"; echo "$ouser -> $sock: $out"
    case "$out" in PermissionError*) ok "$ouser cannot connect to $user's socket (permission denied)";; *) bad "$ouser -> $sock: $out";; esac
    out="$(probe_connect nobody "$sock")"; case "$out" in PermissionError*) ok "nobody cannot connect either";; *) bad "nobody -> $sock: $out";; esac
    out="$(probe_connect "$user" "/run/user/$uid/ruya-0")"; case "$out" in PermissionError*) ok "$user cannot reach the shell's own socket ruya-0";; *) bad "$user -> ruya-0: $out";; esac

    echo "--- the Wayland test app"
    flatpak uninstall --system -y "$wclient" "$sleeper" "$crasher" "$rt" >/dev/null 2>&1
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" || { bad "remote-add"; exit 1; }
    flatpak install --system -y --noninteractive "$remote" "$rt" "$wclient" >/dev/null 2>&1 \
        && ok "test app $wclient installed" || { bad "flatpak install of $wclient failed"; exit 1; }
    for u in "$user" "$ouser"; do systemctl --user -M "$u@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null; done
    : > "$work/signals.log"
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2

    echo "--- nobody signed in: the profile's own client is refused"
    busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null
    sleep 2
    t0="$(date +%s)"
    out="$(launch "$wclient" "$me")"; inst0="$(echo "$out" | unit_of)"
    [ -n "$inst0" ] && ok "Launch as $me while locked: $inst0" || bad "Launch while locked: $out"
    wait_shell "refused (surface|window) of uid $muid .*nobody-signed-in" "$t0" 40 && ok "the compositor refused it (nobody signed in)" || bad "no refusal while nobody is signed in"
    shell_log_since "$t0" | grep -a "ruya-compositor: refused" | head -2
    shell_log_since "$t0" | grep -a -q "ruya-compositor: app .* uid $muid " && bad "a window of $user was shown while nobody was signed in" || ok "no window was shown"
    wait_sig "\"member\":\"AppExited\".*$wclient" 30 && ok "the refused client ended (AppExited)" || { bad "the refused client is still running"; stop_app "$inst0" >/dev/null; }
    journalctl -b _UID="$muid" --since "@$t0" --no-pager -o cat | grep -a "test-wayland-client:" | head -1

    echo "--- $me signed in: its window is in the app layer"
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$me" "")"
    case "$out" in 'suu "ok"'*) ;; *) out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$me" 1234)";; esac
    case "$out" in 'suu "ok"'*) ok "$me signed in";; *) bad "SwitchTo $me: $out"; exit 1;; esac
    sleep 3
    : > "$work/signals.log"
    t1="$(date +%s)"
    out="$(launch "$wclient" "$me")"; inst="$(echo "$out" | unit_of)"; echo "$inst" > /root/vm-display-instance
    [ -n "$inst" ] && ok "Launch as $me: $inst" || { bad "Launch: $out"; exit 1; }
    wait_shell "ruya-compositor: app .* uid $muid profile $me" "$t1" 60 && ok "the window of $user is in the app layer" || bad "no window of $user within 60 s"
    shell_log_since "$t1" | grep -a -E "ruya-compositor: (app|refused|socket)" | head -3
    line="$(journalctl -b _UID="$muid" --since "@$t1" --no-pager -o cat | grep -a "test-wayland-client:" | head -1)"; echo "$line"
    echo "$line" | grep -q "WAYLAND_DISPLAY=wayland-0 socket=yes" && ok "inside the sandbox: WAYLAND_DISPLAY=wayland-0, the socket is there" || bad "sandbox display: $line"
    echo "$line" | grep -q "socket-dir-visible=no" && ok "the sandbox does not see $dir (no path to the other profiles' sockets)" || bad "the sandbox sees $dir"
    echo "$line" | grep -q "uid=$muid " && ok "the app runs as $user" || bad "app uid: $line"
    systemctl --user -M "$user@.host" show -p Environment "$inst" </dev/null 2>&1 | cat | tr ' ' '\n' | grep -E "WAYLAND_DISPLAY|SDL_VIDEODRIVER|PULSE_SERVER"

    echo "--- the profile's sound server (T-365, ADR-010)"
    pdir="/run/ruya-pulse/$user"; psock="$pdir/native"
    systemctl --user -M "$user@.host" show -p Environment "$inst" </dev/null 2>&1 | cat | grep -q "PULSE_SERVER=unix:$psock" \
        && ok "the app got PULSE_SERVER=unix:$psock" || bad "the app has no PULSE_SERVER for $psock"
    [ "$(systemctl --user -M ruya-shell@.host is-active "ruya-pulse@$user.service" </dev/null 2>&1 | cat)" = active ] \
        && ok "ruya-pulse@$user runs in ruya-shell's manager" || bad "ruya-pulse@$user is not active"
    [ "$(stat -c '%a %U' /run/ruya-pulse 2>&1)" = "711 ruya-shell" ] && ok "/run/ruya-pulse: 0711, owned by ruya-shell" || bad "/run/ruya-pulse: $(stat -c '%a %U' /run/ruya-pulse 2>&1)"
    pacl="$(getfacl -p "$pdir" 2>/dev/null | grep -v '^#' | grep -v '^$' | tr '\n' ' ')"
    [ "$pacl" = "user::rwx user:$user:--x group::--- mask::--x other::--- " ] && ok "$pdir: only $user may pass" || bad "ACL of $pdir: $pacl"
    out="$(probe_connect "$user" "$psock")"; [ "$out" = connected ] && ok "$user connects to its sound server" || bad "$user -> $psock: $out"
    out="$(probe_connect "$ouser" "$psock")"; case "$out" in PermissionError*) ok "$ouser cannot reach $user's sound server";; *) bad "$ouser -> $psock: $out";; esac
    ppid="$(systemctl --user -M ruya-shell@.host show -p MainPID --value "ruya-pulse@$user.service" </dev/null 2>&1 | cat)"
    tr '\0' ' ' < "/proc/$ppid/cmdline" 2>/dev/null | grep -q -- "-c ruya-profile-pulse.conf" \
        && grep -q "pulse.allow-module-loading = false" /usr/share/pipewire/ruya-profile-pulse.conf \
        && ok "the server runs ruya-profile-pulse.conf, which refuses module loading" || bad "the sound server's config (pid $ppid)"

    echo "--- nothing of the shell sounds behind the app (T-376)"
    # The ambient bed fades out over 800 ms and then stops its players, so the PipeWire output closes; a
    # paused player left a silent stream open. A cue is a stream for at most 1.5 s, hence the wait.
    sleep 4
    sid="$(id -u ruya-shell)"
    dump="$work/pw-dump.json"
    if ! runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$sid" pw-dump > "$dump" 2>/dev/null; then
        bad "pw-dump failed as ruya-shell (is PipeWire running?)"
    elif streams="$(python3 -I -c '
import json, sys
nodes = json.load(open(sys.argv[1], encoding="utf-8"))
for n in nodes:
    p = (n.get("info") or {}).get("props") or {}
    if (n.get("type") == "PipeWire:Interface:Node" and p.get("media.class") == "Stream/Output/Audio"
            and (p.get("application.process.binary") == "ruya-shell" or p.get("application.process.user") == "ruya-shell")
            and (n.get("info") or {}).get("state") == "running"):
        print(n.get("id"), (n.get("info") or {}).get("state"))
' "$dump")"; then
        [ -z "$streams" ] && ok "no ruya-shell output stream exists with the app in front" || { echo "$streams" | sed 's/^/    /'; bad "a ruya-shell output stream still exists with the app in front"; }
    else
        bad "could not parse the pw-dump output"
    fi

    echo "--- Guide over the app"
    t2="$(date +%s)"
    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    # The overlay takes the keys from the app (the focused item's name in the "focus" line is not
    # reliable: it was empty on 0.0.57 while the list had the focus; the screenshot shows the panel).
    wait_shell "ruya-compositor: app focus app:.* false" "$t2" 15 && ok "Guide took the keys from the app (the overlay)" || bad "Guide did not take the focus from the app"
    t3="$(date +%s)"
    python3 /root/vm-inject-key.py guide >/dev/null 2>&1
    wait_shell "ruya-compositor: app focus app:.* true" "$t3" 15 && ok "closing the overlay gave the focus back to the app" || bad "the app did not get the focus back"

    echo "--- the other profile's client (not signed in) is refused"
    t4="$(date +%s)"
    out="$(launch "$wclient" "$other")"; inst2="$(echo "$out" | unit_of)"
    [ -n "$inst2" ] && ok "Launch as $other: $inst2" || bad "Launch as $other: $out"
    wait_shell "refused (surface|window) of uid $ouid .*other-user" "$t4" 60 && ok "the compositor refused $ouser's client (not the signed-in profile)" || bad "no refusal for $ouser"
    shell_log_since "$t4" | grep -a -q "ruya-compositor: app .* uid $ouid " && bad "a window of $ouser was shown" || ok "no window of $ouser was shown"
    wait_sig "\"member\":\"AppExited\".*$wclient" 30 && ok "the refused client ended (AppExited)" || { bad "$ouser's client still runs"; stop_app "$inst2" >/dev/null; }
    kill "$mon" 2>/dev/null
    echo "The window of $user stays open: take the VM screenshot now (vm-screenshot.ps1 profile-app), then run '$0 display-clean'."
    ;;
display-clean)
    inst="$(cat /root/vm-display-instance 2>/dev/null)"
    [ -n "$inst" ] && { t0="$(date +%s)"; stop_app "$inst"; wait_shell "ruya-compositor: app gone" "$t0" 20 && ok "Stop closed the window (app gone)" || bad "no 'app gone' after Stop"; }
    read -r other created_other < /root/vm-display-other 2>/dev/null
    me="$(busctl --system get-property "$psvc" "$ppath" "$psvc" ActiveProfile | sed -n 's/^s "\(.*\)"$/\1/p')"
    if [ "${created_other:-0}" = 1 ] && [ -n "$other" ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$me" 1234 "$other"
        sleep 3
        [ -e "/run/ruya-wayland/ruya-$other" ] && bad "the socket of the deleted profile is still there" || ok "the deleted profile's socket is gone"
    fi
    flatpak uninstall --system -y "$wclient" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work" /root/vm-display-instance /root/vm-display-other
    ;;
clean)
    flatpak uninstall --system -y "$wclient" >/dev/null 2>&1
    flatpak uninstall --system -y "$sleeper" "$crasher" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    ;;
check)
    [ -f /root/vm-session-probe.qml ] || { bad "/root/vm-session-probe.qml is missing: copy it next to this script"; exit 1; }
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

    # Apps left running by an earlier run (the service takes them over when it restarts, T-290, but
    # this check starts from a clean slate).
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

    # T-363: the run follows the app's own Flatpak scope (the service logs the attach and the end).
    n=0; while ! journalctl -u ruya-session -b --no-pager -o cat 2>/dev/null | grep -a -q "$inst: attached app-flatpak-$sleeper-[0-9]*[.]scope" && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    [ "$n" -lt 20 ] && ok "the run attached the app's Flatpak scope (after about $n s)" || bad "no 'attached app-flatpak-$sleeper-N.scope' line for $inst in the journal"

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
    journalctl -u ruya-session -b --no-pager -o cat 2>/dev/null | grep -a -q "$inst: scope gone" \
        && ok "the run ended with its scope (journal: scope gone)" || bad "no 'scope gone' line for $inst in the journal"
    systemctl --user -M "$user@.host" list-units --no-legend --state=active "app-flatpak-$sleeper-*.scope" </dev/null 2>&1 | grep -q scope \
        && bad "an app-flatpak-$sleeper scope is still active after Stop" || ok "no app-flatpak-$sleeper scope is left after Stop"
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
