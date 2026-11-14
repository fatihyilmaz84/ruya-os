#!/usr/bin/env bash
# X11 mode of ruya-session (ADR-034, RUY-435 on an image with RUY-434's xwayland-satellite and Xwayland) and
# the security point of ADR-034: an app's X server is reachable by that app alone. Runs in the VM as root, like
# the other vm-*-check.sh (the lead's queue copies vm-x11-client.py next to it):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-x11-check.sh scripts/vm-x11-client.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-x11-check.sh [check|clean]
# It builds a tiny local Flatpak repository (a runtime made of the guest's own bash and sleep; the test apps run
# the guest's python3 through --filesystem=host-os), installs it system-wide, and drives Session1 as ruya-shell.
# Like `vm-session-check.sh display` it needs a profile with no PIN or PIN 1234 that signs in (vm-goto.ps1 home
# makes "Player One"), and it creates a second profile ("Check Other") when there is only one (deleted by `clean`).
#   org.ruyaos.TestX11Client / TestX11Second  x11-only (--socket=x11, no wayland): vm-x11-client.py window, which
#                                             maps a window and stays until Stop
#   org.ruyaos.TestX11Both                    --socket=x11 and --socket=wayland, sleeps: must stay on Wayland
# Steps, all in `check`:
#   both       a game declaring x11 and wayland has no X server, no x11-run helper and its Wayland socket (RUY-457)
#   launch     the app runs under the x11-run helper; its display socket is 0700 and owned by the profile user;
#              Xwayland's parent is the satellite (RUY-457: readiness assumes it); no abstract and no TCP listener;
#              Xwayland has -auth and -nolisten local; its SELinux domain is recorded (xserver_t on the Dell)
#   window     the app's X window reaches the compositor as an app window of the profile user and its pid maps to the
#              app's instance (InstanceOfPid); the app saw no Wayland socket
#   isolation  an X11 setup request on the abstract name and the path socket, with and without the cookie, from
#              another profile's user, ruya-shell, nobody and a networked sandbox of the same profile: all refused;
#              the app's own user with its cookie: accepted; without it or with another instance's cookie: refused
#   two        a second app gets a second display, socket, cookie and window, mapped to its own instance
#   freeze     Freeze stops the X server and the satellite with the app, Thaw brings them back (the shell is held
#              with SIGSTOP meanwhile: stopped or crashed it would take the satellite's Wayland connection with it,
#              and its Hub sweep would thaw a Freeze it did not ask for)
#   stop       Stop ends the app, its satellite and Xwayland and leaves no socket, lock or cookie; the other app is
#              unaffected; the second Stop leaves nothing
# The standing form of the isolation assertions is vm-security-check.sh (x11 step). Host tests of the probe client
# and of the helpers below: scripts/test-vm-checks.sh. A FAIL makes the exit status 1.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
svc=org.ruyaos.Session1
path=/org/ruyaos/Session1
ifc=org.ruyaos.Session1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
rt=org.ruyaos.TestX11Runtime
xapp=org.ruyaos.TestX11Client
xapp2=org.ruyaos.TestX11Second
both=org.ruyaos.TestX11Both
remote=ruyaos-x11-test
work=/var/lib/ruya-x11-test
sdir=/tmp/.X11-unix
shell_unit=ruya-compositor@tty1
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

client_py=""
for c in "$here/vm-x11-client.py" /root/vm-x11-client.py; do
    [ -n "$client_py" ] || { [ -f "$c" ] && client_py="$c"; }
done
client_src="$( [ -n "$client_py" ] && cat "$client_py" )"

# --- verdicts on the probe client's one-line answers ("accepted", "refused: ...", "error: ...")
expect_refused() { # <what> <answer>: only a real refusal counts; "error: ..." (a wrong place, no python) never does
    case "$2" in refused:*) ok "$1: $2" ;; *) bad "$1: expected a refusal, got '$2'" ;; esac
}
expect_accepted() { # <what> <answer>
    case "$2" in accepted) ok "$1" ;; *) bad "$1: expected 'accepted', got '$2'" ;; esac
}
expect_prefix() { # <what> <answer> <prefix>
    case "$2" in "$3"*) ok "$1: $2" ;; *) bad "$1: expected '$3...', got '$2'" ;; esac
}

# The window pids the compositor logged ("ruya-compositor: app <id> <title> uid U pid P profile X") for uid $1,
# profile $2, out of a journal text on stdin. The title may be empty at first (an X11 window): match by uid/pid.
window_pids() {
    sed -n "s/.*ruya-compositor: app .* uid $1 pid \([0-9][0-9]*\) profile $2\$/\1/p"
}

# Lib mode: scripts/test-vm-checks.sh sources the helpers above and below on canned data.
if [ "${VM_CHECK_LIB_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

uid="$(id -u ruya-shell)"
as_shell() { runuser -u ruya-shell -- "$@"; }
launch() { as_shell busctl --system call "$svc" "$path" "$ifc" Launch ss "$1" "$2"; }
stop_app() { as_shell busctl --system call "$svc" "$path" "$ifc" Stop s "$1"; }
freeze_app() { as_shell busctl --system call "$svc" "$path" "$ifc" Freeze s "$1"; }
thaw_app() { as_shell busctl --system call "$svc" "$path" "$ifc" Thaw s "$1"; }
of_pid() { as_shell busctl --system call "$svc" "$path" "$ifc" InstanceOfPid u "$1"; }
unit_of() { sed -n 's/^ss "ok" "\(.*\)"$/\1/p'; }
# The cgroup freezer state of unit $2 in user $1's manager (2>&1 | cat: see vm-session-check.sh).
fstate() { systemctl --user -M "$1@.host" show -p FreezerState --value "$2" </dev/null 2>&1 | cat; }
# The app $2's loaded, active Flatpak scopes in user $1's manager.
app_scope_names() {
    systemctl --user -M "$1@.host" list-units --plain --no-legend "app-flatpak-$2-*.scope" </dev/null 2>&1 | cat \
        | awk '$3 == "active" { print $1 }' | grep -E "^app-flatpak-$2-[0-9]+[.]scope$"
}
# The pids in unit $2 (of user $1) whose process name starts with $3 (comm: Xwayland, xwayland-satell).
pids_named() {
    cg="$(systemctl --user -M "$1@.host" show -p ControlGroup --value "$2" </dev/null 2>&1 | cat)"
    for p in $(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null); do
        case "$(cat "/proc/$p/comm" 2>/dev/null)" in "$3"*) echo "$p" ;; esac
    done
}
frozen_cgroup() { grep -q '^frozen 1$' "/sys/fs/cgroup$(cut -d: -f3 "/proc/$1/cgroup" 2>/dev/null)/cgroup.events" 2>/dev/null; }
wait_sig() { # <extended regex> <seconds>: a line of the signal log
    n=0
    while [ "$n" -lt "$2" ]; do
        grep -E -q "$1" "$work/signals.log" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}
shell_log_since() { journalctl -b _UID="$uid" --since "@$1" --no-pager -o cat 2>/dev/null; }
user_log_since() { journalctl -b _UID="$2" --since "@$1" --no-pager -o cat 2>/dev/null; }
wait_user_log() { # <since> <uid> <extended regex> <seconds>: the profile user's journal (the app's stdout)
    n=0
    while [ "$n" -lt "$4" ]; do
        user_log_since "$1" "$2" | grep -a -E -q "$3" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}
wait_shell() { # <extended regex> <since> <seconds>
    n=0
    while [ "$n" -lt "$3" ]; do
        shell_log_since "$2" | grep -a -E -q "$1" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}
gone() { # <pattern> <user>: no process of that user matches `pgrep -f`, within 15 s
    n=0
    while pgrep -u "$2" -f "$1" >/dev/null 2>&1; do
        [ "$n" -ge 15 ] && return 1
        sleep 1; n=$((n + 1))
    done
}
sign_in() { # <profile>
    out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$1" "")"
    case "$out" in 'suu "ok"'*) ;; *) out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$1" 1234)" ;; esac
    case "$out" in 'suu "ok"'*) return 0 ;; *) echo "SwitchTo $1: $out"; return 1 ;; esac
}

# --- the probes: vm-x11-client.py probe <address> <auth>, one answer line each
probe_as() { # <user> <address> <auth>: on this host, as that user
    runuser -u "$1" -- python3 -I -c "$client_src" probe "$2" "$3" 2>&1 | tail -1
}
probe_sandbox() { # <user> <address> <auth>: in a new Flatpak sandbox of the user with network and no x11 permission
    systemd-run --user --machine="$1@.host" --quiet --pipe --wait --collect -- \
        flatpak run --nosocket=x11 --nosocket=fallback-x11 --share=network --command=run "$xapp" probe "$2" "$3" \
        </dev/null 2>&1 | tail -1
}
cookie_hex() { python3 -I -c "$client_src" cookie "$1"; }

# --- the test repository
build_repo() {
    rm -rf "$work"; mkdir -p "$work/rt/usr/bin" "$work/rt/usr/lib64" "$work/rt/files" "$work/rt/var"
    for b in bash sleep; do cp "/usr/bin/$b" "$work/rt/usr/bin/$b" || return 1; done
    cp /usr/bin/bash "$work/rt/usr/bin/sh"
    for lib in $(ldd /usr/bin/bash /usr/bin/sleep | awk '/=> \//{print $3} /ld-linux/{print $1}' | sort -u); do
        cp "$lib" "$work/rt/usr/lib64/" || return 1
    done
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    flatpak build-export --runtime "$work/repo" "$work/rt" stable >/dev/null 2>&1 || return 1
    # The two x11-only apps: the guest's python3 (through host-os) runs the client; no wayland socket.
    for id in "$xapp" "$xapp2"; do
        mkdir -p "$work/$id/files/bin" "$work/$id/files/share" "$work/$id/var"
        cp "$client_py" "$work/$id/files/share/vm-x11-client.py" || return 1
        cat > "$work/$id/files/bin/run" <<'EOF'
#!/bin/sh
export PYTHONHOME=/run/host/usr
[ "$#" -gt 0 ] || set -- window
exec /run/host/usr/lib64/ld-linux-x86-64.so.2 --library-path /run/host/usr/lib64 /run/host/usr/bin/python3 /app/share/vm-x11-client.py "$@"
EOF
        chmod 755 "$work/$id/files/bin/run"
        printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=run\n' "$id" "$rt" "$rt" > "$work/$id/metadata"
        flatpak build-finish --command=run --socket=x11 --filesystem=host-os:ro "$work/$id" >/dev/null 2>&1 || return 1
        flatpak build-export "$work/repo" "$work/$id" stable >/dev/null 2>&1 || return 1
    done
    # The game that offers both: it prints what it was given and sleeps.
    id="$both"
    mkdir -p "$work/$id/files/bin" "$work/$id/var"
    cat > "$work/$id/files/bin/run" <<'EOF'
#!/bin/sh
echo "test-x11-both: DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} XAUTHORITY=${XAUTHORITY:-}"
exec sleep 3000
EOF
    chmod 755 "$work/$id/files/bin/run"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=run\n' "$id" "$rt" "$rt" > "$work/$id/metadata"
    flatpak build-finish --command=run --socket=x11 --socket=wayland "$work/$id" >/dev/null 2>&1 || return 1
    flatpak build-export "$work/repo" "$work/$id" stable >/dev/null 2>&1 || return 1
}

cleanup_all() {
    flatpak uninstall --system -y "$xapp" "$xapp2" "$both" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
}

# X facts of a running X11 instance: xdir xn xcookie xwl xsat. Waits up to 30 s for the display file and
# for the socket to be 0700 (the helper makes it private once Xwayland is up).
x11_facts() { # <user> <app> <unit>
    xuid="$(id -u "$1")"; xdir="/run/user/$xuid/ruya-x11/$2"; xn=""; xcookie=""; xwl=""; xsat=""
    n=0
    while [ "$n" -lt 60 ]; do
        if [ -s "$xdir/display" ]; then
            xn="$(tr -d ' \n' < "$xdir/display")"
            [ -S "$sdir/X$xn" ] && [ "$(stat -c %a "$sdir/X$xn" 2>/dev/null)" = 700 ] && break
        fi
        sleep 0.5; n=$((n + 1))
    done
    [ -n "$xn" ] && [ -S "$sdir/X$xn" ] || return 1
    xcookie="$(cookie_hex "$xdir/Xauthority")"
    xwl="$(pids_named "$1" "$3" Xwayland | head -1)"
    xsat="$(pids_named "$1" "$3" xwayland-satell | head -1)"
}

case "${1:-check}" in
clean)
    cleanup_all
    read -r other created_other < /root/vm-x11-other 2>/dev/null
    if [ "${created_other:-0}" = 1 ] && [ -n "${other:-}" ]; then
        me="$(busctl --system get-property "$psvc" "$ppath" "$psvc" ActiveProfile | sed -n 's/^s "\(.*\)"$/\1/p')"
        busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$me" 1234 "$other"
    fi
    rm -f /root/vm-x11-other
    systemctl kill -s CONT "$shell_unit" 2>/dev/null
    ;;
check)
    [ -n "$client_py" ] || { bad "vm-x11-client.py is missing: copy it next to this script"; exit 1; }
    paused=0
    resume_shell() { if [ "$paused" = 1 ]; then systemctl kill -s CONT "$shell_unit" && paused=0; fi; }
    trap resume_shell EXIT

    echo "--- the image has the X11 mode (RUY-434 + RUY-435)"
    systemctl is-active ruya-session >/dev/null && ok "ruya-session is active" || { bad "ruya-session is not active"; exit 1; }
    for f in /usr/bin/xwayland-satellite /usr/bin/Xwayland; do
        [ -x "$f" ] && ok "$f is installed" || { bad "$f is missing: this image has no RUY-434 (patched satellite and Xwayland)"; exit 1; }
    done
    grep -a -q 'x11-run' /usr/bin/ruya-session && ok "ruya-session has the x11-run helper" || { bad "ruya-session has no x11-run helper: this image has no RUY-435"; exit 1; }
    [ "$(stat -c %a "$sdir" 2>/dev/null)" = 1777 ] && ok "$sdir exists, mode 1777" || bad "$sdir: $(stat -c %a "$sdir" 2>&1) (the helper fails the launch without it)"
    command -v python3 >/dev/null && ok "python3 is there (the probes and the test apps)" || { bad "no python3"; exit 1; }

    echo "--- profiles: one signed in, a second one for the isolation probes"
    ids="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"')"
    me="$(echo "$ids" | head -1)"
    [ -n "$me" ] && ok "profile $me" || { bad "no profile: make one with vm-goto.ps1 home"; exit 1; }
    other="$(echo "$ids" | grep -v "^$me\$" | head -1)"
    created_other=0
    if [ -z "$other" ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$me" 1234 "Check Other" standard "" >/dev/null
        other="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"' | grep -v "^$me\$" | head -1)"
        created_other=1
    fi
    [ -n "$other" ] && ok "second profile $other (created by the check: $created_other)" || { bad "no second profile"; exit 1; }
    echo "$other $created_other" > /root/vm-x11-other
    user="ruya-$me"; ouser="ruya-$other"
    muid="$(id -u "$user")"; ouid="$(id -u "$ouser")"
    sign_in "$me" && ok "$me signed in" || { bad "cannot sign in $me"; exit 1; }
    sleep 3

    echo "--- the test repository: x11-only apps and one that offers both"
    flatpak uninstall --system -y "$xapp" "$xapp2" "$both" "$rt" >/dev/null 2>&1
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" || { bad "remote-add"; exit 1; }
    flatpak install --system -y --noninteractive "$remote" "$rt" "$xapp" "$xapp2" "$both" >/dev/null 2>&1 \
        && ok "test apps installed" || { bad "flatpak install of the test apps failed"; exit 1; }
    chmod 755 "$work"
    for app in "$xapp" "$xapp2" "$both"; do
        meta="/var/lib/flatpak/app/$app/current/active/metadata"
        sockets="$(sed -n 's/^sockets=//p' "$meta" 2>/dev/null | head -1)"
        echo "    $app sockets=$sockets"
    done
    for u in "$user" "$ouser"; do systemctl --user -M "$u@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null; done
    : > "$work/signals.log"
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2
    x_before="$(ls "$sdir" 2>/dev/null | grep -c '^X')"

    echo "--- a game that declares x11 and wayland stays on Wayland (ADR-034 point 2)"
    t0="$(date +%s)"
    out="$(launch "$both" "$me")"; ibo="$(echo "$out" | unit_of)"
    [ -n "$ibo" ] && ok "Launch $both: $ibo" || { bad "Launch $both: $out"; ibo=""; }
    if [ -n "$ibo" ]; then
        wait_user_log "$t0" "$muid" "test-x11-both:" 40 && ok "the game started" || bad "the game printed nothing in 40 s"
        line="$(user_log_since "$t0" "$muid" | grep -a "test-x11-both:" | head -1)"; echo "    $line"
        echo "$line" | grep -q "WAYLAND_DISPLAY=wayland-0" && ok "inside the sandbox: WAYLAND_DISPLAY=wayland-0" || bad "no Wayland display for the game: $line"
        echo "$line" | grep -q "DISPLAY= " && ok "no X display was given to it" || bad "the game got an X display: $line"
        env_="$(systemctl --user -M "$user@.host" show -p Environment "$ibo" </dev/null 2>&1 | cat)"
        echo "$env_" | tr ' ' '\n' | grep -q '^WAYLAND_DISPLAY=/run/ruya-wayland/' && ok "the unit has the profile's WAYLAND_DISPLAY" || bad "unit environment: $env_"
        echo "$env_" | tr ' ' '\n' | grep -q '^DISPLAY=' && bad "the unit has a DISPLAY" || ok "the unit has no DISPLAY"
        execs="$(systemctl --user -M "$user@.host" show -p ExecStart "$ibo" </dev/null 2>&1 | cat)"
        echo "$execs" | grep -q 'x11-run' && bad "the unit runs the x11-run helper: $execs" || ok "the unit does not run the x11-run helper"
        [ -e "/run/user/$muid/ruya-x11/$both" ] && bad "an X instance directory exists for $both" || ok "no X instance directory for $both"
        [ "$(ls "$sdir" 2>/dev/null | grep -c '^X')" = "$x_before" ] && ok "no X socket was made" || bad "an X socket appeared: $(ls "$sdir")"
        pgrep -u "$user" -x Xwayland >/dev/null 2>&1 && bad "an Xwayland runs for the Wayland game" || ok "no Xwayland runs"
        stop_app "$ibo" >/dev/null
        gone "sleep 3000" "$user" && ok "$both stopped" || bad "$both still runs"
    fi

    echo "--- Launch the x11-only app: the helper starts its X server"
    : > "$work/signals.log"
    t1="$(date +%s)"
    out="$(launch "$xapp" "$me")"; inst="$(echo "$out" | unit_of)"
    [ -n "$inst" ] && ok "Launch $xapp: $inst" || { bad "Launch $xapp: $out"; kill "$mon" 2>/dev/null; exit 1; }
    # ExecStart is empty until systemd has started the unit's process: poll up to 10 s.
    for _ in $(seq 1 20); do
        execs="$(systemctl --user -M "$user@.host" show -p ExecStart "$inst" </dev/null 2>&1 | cat)"
        case "$execs" in *path=*) break ;; esac
        sleep 0.5
    done
    echo "$execs" | grep -q 'x11-run' && ok "the unit's main process is the x11-run helper" || bad "the unit does not run x11-run: $execs"
    if x11_facts "$user" "$xapp" "$inst"; then
        ok "the X server of $xapp is display :$xn (socket $sdir/X$xn, 0700, cookie in $xdir)"
    else
        bad "no X display for $xapp within 30 s (journal: $(journalctl -u 'user@*' -b --no-pager -o cat 2>/dev/null | grep -a 'ruya-session\|x11' | tail -3 | tr '\n' '|'))"
        stop_app "$inst" >/dev/null; kill "$mon" 2>/dev/null; exit 1
    fi
    echo "    pids: satellite=${xsat:-none} Xwayland=${xwl:-none}"
    [ "$(stat -c '%a %U' "$sdir/X$xn")" = "700 $user" ] && ok "$sdir/X$xn: 0700, owned by $user" || bad "$sdir/X$xn: $(stat -c '%a %U' "$sdir/X$xn")"
    [ "$(stat -c '%a %U' "$xdir")" = "700 $user" ] && ok "$xdir: 0700, owned by $user" || bad "$xdir: $(stat -c '%a %U' "$xdir")"
    [ "$(stat -c '%a %U' "$xdir/Xauthority")" = "600 $user" ] && ok "the cookie file: 0600, owned by $user" || bad "Xauthority: $(stat -c '%a %U' "$xdir/Xauthority")"
    [ "$(printf '%s' "$xcookie" | wc -c)" = 32 ] && ok "the cookie is 16 bytes" || bad "cookie: '$xcookie'"
    [ -n "$xsat" ] && ok "xwayland-satellite $xsat runs in the app's unit" || bad "no xwayland-satellite in the unit's cgroup"
    [ -n "$xwl" ] && ok "Xwayland $xwl runs in the app's unit" || bad "no Xwayland in the unit's cgroup"
    # RUY-472: readiness is the satellite's READY=1, not a lock file; Xwayland is the satellite's child.
    xwppid="$(ps -o ppid= -p "${xwl:-0}" 2>/dev/null | tr -d ' ')"
    if [ -n "$xsat" ] && [ "$xwppid" = "$xsat" ]; then
        ok "Xwayland's parent is the satellite"
    else
        bad "Xwayland $xwl has parent '$xwppid', the satellite is '$xsat'"
    fi
    [ -S "$xdir/notify" ] && ok "the helper's notify socket $xdir/notify exists" || bad "no notify socket in $xdir"
    xrec="$(tr -d ' \n' < "$xdir/satellite" 2>/dev/null)"
    if [ -n "$xsat" ] && [ "$xrec" = "$xsat" ]; then
        ok "the instance directory records the satellite pid"
    else
        bad "satellite record '$xrec' is not the satellite '$xsat'"
    fi
    echo "    Xwayland: $(tr '\0' ' ' < "/proc/${xwl:-0}/cmdline" 2>/dev/null)"
    tr '\0' ' ' < "/proc/${xwl:-0}/cmdline" 2>/dev/null | grep -q -- ' -auth ' && ok "Xwayland runs with -auth" || bad "Xwayland has no -auth"
    tr '\0' ' ' < "/proc/${xwl:-0}/cmdline" 2>/dev/null | grep -q -- '-nolisten local' && ok "Xwayland runs with -nolisten local" || bad "Xwayland has no -nolisten local"
    xlabel="$(ps -o label= -p "${xwl:-0}" 2>/dev/null | tr -d ' ')"
    echo "    SELinux: Xwayland runs as $xlabel (the Dell spike: xserver_t; RUY-20 confines ruya-* services only)"
    case "$xlabel" in *:xserver_t:*) ok "Xwayland runs in xserver_t, as on the Dell spike" ;; *) bad "Xwayland's SELinux label is '$xlabel', expected xserver_t (update image/security-baseline.json xwayland_domains if this is intended)" ;; esac
    ss -H -xln 2>/dev/null | awk '{print $5}' | grep -q '^@/tmp/.X11-unix' && bad "an abstract @/tmp/.X11-unix listener exists: $(ss -H -xln | awk '{print $5}' | grep '^@/tmp/.X11-unix')" || ok "no abstract @/tmp/.X11-unix listener"
    ss -H -tln 2>/dev/null | awk '{print $4}' | grep -q ":$((6000 + xn))\$" && bad "something listens on TCP $((6000 + xn))" || ok "no TCP listener on $((6000 + xn))"
    run_json="$(as_shell busctl --system --json=short call "$svc" "$path" "$ifc" ListRunning)"
    echo "$run_json" | grep -q "$inst" && echo "$run_json" | grep -q '"running"' && ok "ListRunning shows $inst as running" || bad "ListRunning: $run_json"

    echo "--- the window reaches the compositor and maps to its instance"
    wait_shell "ruya-compositor: app .* uid $muid pid [0-9]+ profile $me" "$t1" 60 \
        && ok "the app's X window is an app window of $user in the app layer" || bad "no app window of $user within 60 s (the satellite or the X client failed?)"
    shell_log_since "$t1" | grep -a "ruya-compositor: app " | head -3 | sed 's/^/    /'
    shell_log_since "$t1" | grep -a -q "ruya-compositor: refused" && bad "the compositor refused: $(shell_log_since "$t1" | grep -a 'ruya-compositor: refused' | head -1)" || ok "the compositor refused nothing"
    wpids="$(shell_log_since "$t1" | window_pids "$muid" "$me" | sort -u)"
    [ -n "$wpids" ] || bad "no window pid in the shell log"
    for wp in $wpids; do
        case "$(of_pid "$wp")" in
        "ss \"ok\" \"$inst\"") ok "InstanceOfPid of the window's client ($wp, $(cat "/proc/$wp/comm" 2>/dev/null)): $inst" ;;
        *) bad "InstanceOfPid $wp: $(of_pid "$wp") (want $inst)" ;;
        esac
    done
    wait_user_log "$t1" "$muid" "test-x11-client: .*mapped window" 40 && ok "the X client mapped its window" || bad "the X client printed no 'mapped window' line: $(user_log_since "$t1" "$muid" | grep -a 'test-x11-client' | head -2)"
    line="$(user_log_since "$t1" "$muid" | grep -a "test-x11-client:" | head -1)"; echo "    $line"
    echo "$line" | grep -q "uid=$muid " && ok "the app runs as $user" || bad "app uid: $line"
    echo "$line" | grep -q "WAYLAND_DISPLAY= " && ok "the app saw no WAYLAND_DISPLAY" || bad "the app has a Wayland display: $line"
    echo "$line" | grep -q "XAUTHORITY=/run/flatpak/Xauthority" && ok "the app's cookie is Flatpak's filtered /run/flatpak/Xauthority" || bad "XAUTHORITY: $line"

    echo "--- isolation: who reaches display :$xn (ADR-034 point 5; RUY-1's negative test)"
    P="$sdir/X$xn"; A="@$sdir/X$xn"; T="tcp:127.0.0.1:$((6000 + xn))"
    expect_accepted "$user with the app's cookie on the path socket (the control)" "$(probe_as "$user" "$P" "hex:$xcookie")"
    expect_refused "$user without the cookie on the path socket" "$(probe_as "$user" "$P" none)"
    expect_refused "$user with a wrong cookie on the path socket" "$(probe_as "$user" "$P" "hex:$(printf '%032d' 0)")"
    expect_refused "$user on the abstract socket" "$(probe_as "$user" "$A" "hex:$xcookie")"
    expect_refused "$user on TCP $((6000 + xn))" "$(probe_as "$user" "$T" none)"
    for u in "$ouser" ruya-shell nobody; do
        expect_refused "$u on the path socket, no cookie" "$(probe_as "$u" "$P" none)"
        expect_refused "$u on the path socket, with the cookie" "$(probe_as "$u" "$P" "hex:$xcookie")"
        expect_refused "$u on the abstract socket, no cookie" "$(probe_as "$u" "$A" none)"
        expect_refused "$u on the abstract socket, with the cookie" "$(probe_as "$u" "$A" "hex:$xcookie")"
    done
    expect_refused "a networked sandbox of $user on the abstract socket, no cookie" "$(probe_sandbox "$user" "$A" none)"
    expect_refused "a networked sandbox of $user on the abstract socket, with the cookie" "$(probe_sandbox "$user" "$A" "hex:$xcookie")"
    expect_refused "a networked sandbox of $user on TCP $((6000 + xn))" "$(probe_sandbox "$user" "$T" none)"
    expect_prefix "a networked sandbox of $user has no path to the socket (and ran the probe)" "$(probe_sandbox "$user" "$P" "hex:$xcookie")" "error: ENOENT"
    expect_refused "a networked sandbox of $ouser on the abstract socket, with the cookie" "$(probe_sandbox "$ouser" "$A" "hex:$xcookie")"
    expect_accepted "the control again after all the probes" "$(probe_as "$user" "$P" "hex:$xcookie")"

    echo "--- a second x11-only app at once: its own display, cookie, window and instance"
    : > "$work/signals.log"
    t2="$(date +%s)"
    out="$(launch "$xapp2" "$me")"; inst2="$(echo "$out" | unit_of)"
    [ -n "$inst2" ] && ok "Launch $xapp2: $inst2" || { bad "Launch $xapp2: $out"; }
    if [ -n "$inst2" ]; then
        xn1="$xn"; xdir1="$xdir"; xcookie1="$xcookie"; xwl1="$xwl"; xsat1="$xsat"
        if x11_facts "$user" "$xapp2" "$inst2"; then
            [ "$xn" != "$xn1" ] && ok "two launches, two displays: :$xn1 and :$xn" || bad "both apps are on display :$xn"
            [ "$xcookie" != "$xcookie1" ] && ok "two cookies" || bad "both apps have the same cookie"
            [ "$xwl" != "$xwl1" ] && [ "$xsat" != "$xsat1" ] && [ -n "$xwl" ] && ok "two X servers (Xwayland $xwl1 and $xwl) and two satellites ($xsat1 and $xsat)" || bad "the X servers are not separate: $xwl1/$xwl $xsat1/$xsat"
            expect_refused "app 1's cookie on app 2's display" "$(probe_as "$user" "$sdir/X$xn" "hex:$xcookie1")"
            expect_refused "app 2's cookie on app 1's display" "$(probe_as "$user" "$sdir/X$xn1" "hex:$xcookie")"
            expect_accepted "app 2's cookie on its own display" "$(probe_as "$user" "$sdir/X$xn" "hex:$xcookie")"
            expect_accepted "app 1's X server still answers" "$(probe_as "$user" "$sdir/X$xn1" "hex:$xcookie1")"
            wait_shell "ruya-compositor: app .* uid $muid pid [0-9]+ profile $me" "$t2" 60 && ok "the second app's window reaches the app layer" || bad "no window of the second app within 60 s"
            for wp in $(shell_log_since "$t2" | window_pids "$muid" "$me" | sort -u); do
                case "$(of_pid "$wp")" in
                "ss \"ok\" \"$inst2\"") ok "InstanceOfPid of the second window's client ($wp): $inst2" ;;
                *) bad "InstanceOfPid $wp: $(of_pid "$wp") (want $inst2)" ;;
                esac
            done
        else
            bad "no X display for $xapp2 within 30 s"
        fi
        # Back to the first app's facts for the Freeze and Stop sections.
        xn2="$xn"; xdir2="$xdir"; xcookie2="$xcookie"; xwl2="$xwl"; xsat2="$xsat"
        xn="$xn1"; xdir="$xdir1"; xcookie="$xcookie1"; xwl="$xwl1"; xsat="$xsat1"
    fi

    echo "--- the standing assertions (vm-security-check.sh, x11 step) while two X servers run"
    sec=""
    for c in "$here/vm-security-check.sh" /root/vm-security-check.sh; do [ -n "$sec" ] || { [ -f "$c" ] && sec="$c"; }; done
    if [ -n "$sec" ] && [ -n "${inst2:-}" ]; then
        secout="$(bash "$sec" check 2>&1)"
        echo "$secout" | grep -E "(X11|X socket|Xwayland)" | sed 's/^/    /'
        echo "$secout" | grep -q "^PASS: Xwayland .* has -auth and -nolisten local" \
            && ok "vm-security-check.sh saw a running Xwayland with -auth and -nolisten local" \
            || bad "vm-security-check.sh x11 step did not pass an Xwayland (is image/security-baseline.json next to it?)"
        echo "$secout" | grep -E "^FAIL: .*(X11|X socket|Xwayland)" >/dev/null && bad "vm-security-check.sh x11 step has a FAIL" || ok "vm-security-check.sh x11 step has no FAIL"
    else
        echo "    (vm-security-check.sh is not next to this script, or no second app: run its x11 step by hand)"
    fi

    echo "--- Freeze / Thaw take the X server and the satellite along"
    # The shell is held (SIGSTOP), not stopped: a stopped compositor closes the satellite's Wayland connection,
    # and the running shell's sweep thaws any Freeze it did not ask for. Held, its Wayland connections stay open.
    if systemctl kill -s STOP "$shell_unit"; then paused=1; ok "the shell is held (SIGSTOP) for the Freeze checks"; else bad "cannot hold $shell_unit"; fi
    scopes="$(app_scope_names "$user" "$xapp")"
    echo "    scopes: $(echo $scopes)"
    case "$(freeze_app "$inst")" in 's "ok"') ok "Freeze answered ok" ;; *) bad "Freeze: $(freeze_app "$inst")" ;; esac
    for u in "$inst" $scopes; do
        [ "$(fstate "$user" "$u")" = frozen ] && ok "$u is frozen" || bad "$u: FreezerState $(fstate "$user" "$u") after Freeze"
    done
    for p in $xsat $xwl; do
        frozen_cgroup "$p" && ok "pid $p ($(cat "/proc/$p/comm" 2>/dev/null)) is in a frozen cgroup" || bad "pid $p ($(cat "/proc/$p/comm" 2>/dev/null)) is not frozen"
    done
    cpid="$(pgrep -u "$user" -f 'vm-x11-client.py window' | head -1)"
    [ -n "$cpid" ] && frozen_cgroup "$cpid" && ok "the X client ($cpid) is frozen too" || bad "the X client is not frozen (pid '${cpid:-none}')"
    expect_prefix "a frozen X server does not answer a setup request" "$(probe_as "$user" "$sdir/X$xn" "hex:$xcookie")" "error: no answer"
    case "$(thaw_app "$inst")" in 's "ok"') ok "Thaw answered ok" ;; *) bad "Thaw: $(thaw_app "$inst")" ;; esac
    for u in "$inst" $scopes; do
        [ "$(fstate "$user" "$u")" = running ] && ok "$u runs again" || bad "$u: FreezerState $(fstate "$user" "$u") after Thaw"
    done
    expect_accepted "the X server answers again after the Thaw" "$(probe_as "$user" "$sdir/X$xn" "hex:$xcookie")"
    pgrep -u "$user" -f 'vm-x11-client.py window' >/dev/null && ok "the X client is still running" || bad "the X client died in the freeze"
    resume_shell
    [ "$paused" = 0 ] && ok "the shell runs again" || bad "cannot resume the shell"
    sleep 2
    shell_log_since "$t1" | grep -a -q "ruya-compositor: app gone" && bad "a window was closed by the freeze: $(shell_log_since "$t1" | grep -a 'app gone' | head -1)" || ok "no window went away during the freeze"

    echo "--- Stop ends the app and its X server and leaves nothing behind"
    t3="$(date +%s)"
    case "$(stop_app "$inst")" in 's "ok"') ok "Stop $inst answered ok" ;; *) bad "Stop: $(stop_app "$inst")" ;; esac
    wait_sig "\"member\":\"AppExited\".*$xapp" 30 && ok "AppExited for $xapp" || bad "no AppExited for $xapp within 30 s"
    grep -E "\"member\":\"AppExited\".*$xapp" "$work/signals.log" | head -1 | grep -q '"quit"' && ok "reason quit" || bad "AppExited for $xapp is not 'quit': $(grep -E "\"member\":\"AppExited\".*$xapp" "$work/signals.log" | head -1)"
    wait_shell "ruya-compositor: app gone" "$t3" 20 && ok "the window went away (app gone)" || bad "no 'app gone' after Stop"
    n=0; while [ "$n" -lt 20 ] && { kill -0 "$xwl" 2>/dev/null || kill -0 "$xsat" 2>/dev/null; }; do sleep 0.5; n=$((n + 1)); done
    kill -0 "$xwl" 2>/dev/null && bad "Xwayland $xwl survived Stop" || ok "Xwayland $xwl is gone"
    kill -0 "$xsat" 2>/dev/null && bad "the satellite $xsat survived Stop" || ok "the satellite $xsat is gone"
    gone "vm-x11-client.py window" "$user" >/dev/null 2>&1
    [ -e "$sdir/X$xn" ] && bad "the X socket $sdir/X$xn is left" || ok "no X socket $sdir/X$xn is left"
    [ -e "/tmp/.X$xn-lock" ] && bad "the lock /tmp/.X$xn-lock is left" || ok "no lock /tmp/.X$xn-lock is left"
    [ -e "$xdir" ] && bad "the instance directory $xdir (with the cookie) is left" || ok "no instance directory, no cookie"
    if [ -n "${inst2:-}" ]; then
        [ -S "$sdir/X$xn2" ] && ok "the second app's socket $sdir/X$xn2 is untouched" || bad "the second app's socket is gone"
        expect_accepted "the second app's X server is untouched by the first Stop" "$(probe_as "$user" "$sdir/X$xn2" "hex:$xcookie2")"
        pgrep -u "$user" -f 'vm-x11-client.py window' >/dev/null && ok "the second app still runs" || bad "the second app died"
        case "$(stop_app "$inst2")" in 's "ok"') ok "Stop $inst2 answered ok" ;; *) bad "Stop $inst2" ;; esac
        wait_sig "\"member\":\"AppExited\".*$xapp2" 30 && ok "AppExited for $xapp2" || bad "no AppExited for $xapp2"
        n=0; while [ "$n" -lt 20 ] && { kill -0 "$xwl2" 2>/dev/null || kill -0 "$xsat2" 2>/dev/null; }; do sleep 0.5; n=$((n + 1)); done
        kill -0 "$xwl2" 2>/dev/null || kill -0 "$xsat2" 2>/dev/null && bad "the second app's X server survived Stop" || ok "the second app's X server is gone"
        [ -e "$sdir/X$xn2" ] || [ -e "/tmp/.X$xn2-lock" ] || [ -e "$xdir2" ] && bad "the second app left a socket, a lock or a cookie" || ok "the second app left no socket, lock or cookie"
    fi
    pgrep -u "$user" -x Xwayland >/dev/null 2>&1 && bad "an Xwayland of $user still runs" || ok "no Xwayland of $user runs"
    pgrep -u "$user" -f xwayland-satellite >/dev/null 2>&1 && bad "an xwayland-satellite of $user still runs" || ok "no xwayland-satellite of $user runs"
    [ "$(ls "$sdir" 2>/dev/null | grep -c '^X')" = "$x_before" ] && ok "$sdir is as it was before the check" || bad "$sdir has leftovers: $(ls -A "$sdir")"
    ls /tmp/.X*-lock >/dev/null 2>&1 && bad "X lock files are left: $(ls /tmp/.X*-lock)" || ok "no /tmp/.X*-lock is left"
    [ -z "$(ls -A "/run/user/$muid/ruya-x11" 2>/dev/null)" ] && ok "/run/user/$muid/ruya-x11 is empty" || bad "left in /run/user/$muid/ruya-x11: $(ls -A "/run/user/$muid/ruya-x11")"
    kill "$mon" 2>/dev/null

    cleanup_all
    echo
    [ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
    echo "(the second profile, if the check made it, stays until: bash $0 clean)"
    exit "$fail"
    ;;
*)
    echo "usage: $0 [check|clean]"; exit 2
    ;;
esac
