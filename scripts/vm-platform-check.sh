#!/usr/bin/env bash
# modes: check clean identity deputy
# Checks ruya-platform (org.ruyaos.Platform1, the one door for sandboxed apps; ADR-022, RUY-157) inside a
# running VM, as root, with a profile signed in (vm-queue.ps1 signs one in). It builds a local Flatpak
# repository with two test apps whose only bus permission is --system-talk-name=org.ruyaos.Platform1 (and
# host-os:ro, to run the image's python3 with vm-platform-probe.py and vm_dbus.py), launches them through
# Session1 as ruya-shell, and checks:
#   - the unit is active and its exposure is printed (vm-security-check.sh holds it to the baseline);
#   - the identity helper (ADR-022 decision 4, RUY-1129; also mode `identity`): the door's CapBnd, CapEff,
#     CapPrm and CapAmb are 0; ruya-platform-identify.socket listens, 0600 root; the helper's bounding set
#     is exactly CAP_DAC_READ_SEARCH and CAP_SYS_PTRACE (configured, and measured on a live helper held by a
#     root request); a root request is answered, a profile user cannot connect;
#   - each app's Register through xdg-dbus-proxy answers "ok" (identity from the connection, the recipe of
#     RUY-157 step 1, the files read by the helper under its two capabilities and SELinux), and the
#     helper's journal shows the reads;
#   - the confused deputy (also mode `deputy`): as the profile user, /etc/shadow bound onto /.flatpak-info
#     (bwrap, an unprivileged user and mount namespace) in a matching transient scope: Register is
#     "not-an-app", the helper logs "not-owned, nothing read" and the door "flatpak-info not-owned";
#   - from inside the sandbox Manage (ListPermissions, SetPermission, NotifyLifecycle) is AccessDenied by
#     the bus policy, and Profiles1, Session1 and Input1 are not reachable at all;
#   - root's NotifyLifecycle "resume" reaches app A as a unicast Resume with the value, and app B hears
#     nothing; "stopping" reaches A, A's SaveDone settles it as "saved";
#   - ruya-session's own path (RUY-1099): a Freeze and Thaw of A through Session1 gives A a Resume, B none;
#   - an unsandboxed process of the profile user is "not-an-app"; the user nobody cannot call Manage;
#   - the player turns lifecycle off for A: NotifyLifecycle answers "not-registered", a new instance of A
#     is refused ("not-allowed"); turned back on at the end;
#   - Session1.Stop of A sends Stopping and A's SaveDone answers it (the stop waits for it).
# The helpers a profile user runs (vm-platform-probe.py, vm_dbus.py) are copied to a world-readable
# folder first ($work/helpers; /root is not readable for them, RUY-1128).
# `clean` removes the test apps and the remote. Copy and run (vm-queue.ps1 copies every vm-*/vm_* file):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-platform-check.sh scripts/vm-platform-probe.py scripts/vm_dbus.py root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-platform-check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
dest=org.ruyaos.Platform1
opath=/org/ruyaos/Platform1
manage=org.ruyaos.Platform1.Manage
ssvc=org.ruyaos.Session1
spath=/org/ruyaos/Session1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
rt=org.ruyaos.TestPlatformRuntime
appa=org.ruyaos.TestPlatformA
appb=org.ruyaos.TestPlatformB
remote=ruya-platform-test
work="${PLAT_WORK:-/var/tmp/ruya-platform-check}"
helpers="$work/helpers"
# Overridable for the host tests (test-vm-checks.sh).
proc="${PLAT_PROC:-/proc}"
sock="${PLAT_SOCK:-/run/ruya-platform-identify.sock}"
# CAP_DAC_READ_SEARCH (bit 2) and CAP_SYS_PTRACE (bit 19), as /proc/<pid>/status shows a set.
helper_caps=0000000000080004
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
as_shell() { runuser -u ruya-shell -- "$@"; }

drop_apps() {
    for id in "$appa" "$appb" "$rt"; do
        flatpak info --system "$id" >/dev/null 2>&1 && flatpak uninstall --system -y --noninteractive "$id" >/dev/null 2>&1
    done
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
}

build_repo() {
    rm -rf "$work"; mkdir -p "$work/rt/files" "$work/rt/usr/bin" "$work/rt/usr/lib64"
    # The runtime's /usr: sh (bash) and the libraries it loads; python3 comes from the host through host-os.
    cp /usr/bin/bash "$work/rt/usr/bin/sh" || return 1
    for lib in $(ldd /usr/bin/bash | awk '/=> \//{print $3} /ld-linux/{print $1}' | sort -u); do
        cp "$lib" "$work/rt/usr/lib64/" || return 1
    done
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    flatpak build-export --runtime "$work/repo" "$work/rt" stable >/dev/null 2>&1 || return 1
    py="$(readlink -f /usr/bin/python3)"
    for id in "$appa" "$appb"; do
        mkdir -p "$work/$id/files/bin" "$work/$id/files/share" "$work/$id/var"
        cp "$here/vm-platform-probe.py" "$here/vm_dbus.py" "$work/$id/files/share/" || return 1
        # The image's python3, loaded by the host's loader from /run/host (the runtime has no python).
        cat > "$work/$id/files/bin/run" <<EOF
#!/bin/sh
export PYTHONHOME=/run/host/usr
exec /run/host/usr/lib64/ld-linux-x86-64.so.2 --library-path /run/host/usr/lib64 /run/host$py -I /app/share/vm-platform-probe.py app "\$XDG_DATA_HOME/platform.log"
EOF
        chmod 755 "$work/$id/files/bin/run"
        printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=run\n' "$id" "$rt" "$rt" > "$work/$id/metadata"
        flatpak build-finish --command=run --system-talk-name="$dest" --filesystem=host-os:ro "$work/$id" >/dev/null 2>&1 || return 1
        flatpak build-export "$work/repo" "$work/$id" stable >/dev/null 2>&1 || return 1
    done
}

# The probe and its client where a profile user can read them.
put_helpers() {
    install -d -m 0755 "$work" "$helpers" && install -m 0644 "$here/vm-platform-probe.py" "$here/vm_dbus.py" "$helpers/"
}
# The signed-in profile: sets pid, user and home.
signed_in() {
    pid="$(busctl --system get-property "$psvc" "$ppath" "$psvc" ActiveProfile 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p')"
    [ -n "$pid" ] && ok "profile $pid is signed in" || { bad "nobody is signed in (vm-queue.ps1 signs a profile in; or sign in first)"; return 1; }
    user="ruya-$pid"
    home="$(getent passwd "$user" | cut -d: -f6)"
}
# Field $2 (CapBnd, CapEff, ...) of /proc/<pid $1>/status.
cap_of() { awk -v k="$2:" '$1 == k {print $2}' "$proc/$1/status" 2>/dev/null; }

# Items 1 and 2 of RUY-1129: the door holds no capability, the helper exactly its two.
check_identity() {
    local dpid hpid v inst n out holder
    echo "--- the identity helper (ADR-022 decision 4)"
    dpid="$(systemctl show -p MainPID --value ruya-platform.service 2>/dev/null)"
    if [ -n "$dpid" ] && [ "$dpid" != 0 ]; then
        for k in CapBnd CapEff CapPrm CapAmb; do
            v="$(cap_of "$dpid" "$k")"
            [ "$v" = 0000000000000000 ] && ok "the door's $k is 0" || bad "the door's $k is '$v', want 0000000000000000"
        done
    else
        bad "ruya-platform.service has no main process"
    fi
    [ "$(systemctl is-active ruya-platform-identify.socket 2>/dev/null)" = active ] && ok "ruya-platform-identify.socket is active" \
        || bad "ruya-platform-identify.socket is not active"
    v="$(stat -c '%a %U %F' "$sock" 2>&1)"
    [ "$v" = "600 root socket" ] && ok "$sock is 0600 root" || bad "$sock: '$v', want '600 root socket'"
    v="$(systemctl show -p CapabilityBoundingSet --value ruya-platform-identify@check.service 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"
    [ "$v" = "cap_dac_read_search cap_sys_ptrace " ] && ok "the helper's unit bounds it to CAP_DAC_READ_SEARCH and CAP_SYS_PTRACE" \
        || bad "the helper's configured bounding set is '$v'"
    # A live helper: the probe connects as root and waits 2 s before it sends, so the helper waits too.
    # It asks for nobody's uid (65534): no app is root, and a request for uid 0 is refused (below).
    python3 -I "$here/vm-platform-probe.py" helper "$sock" 65534 > "$work/helper.out" 2>&1 &
    holder=$!
    inst=""; n=0
    while [ -z "$inst" ] && [ "$n" -lt 15 ]; do
        inst="$(systemctl list-units --plain --no-legend --full --state=active 'ruya-platform-identify@*.service' 2>/dev/null | awk '{print $1}' | head -1)"
        [ -n "$inst" ] || sleep 0.1
        n=$((n + 1))
    done
    hpid=""
    [ -n "$inst" ] && hpid="$(systemctl show -p MainPID --value "$inst" 2>/dev/null)"
    if [ -n "$hpid" ] && [ "$hpid" != 0 ]; then
        v="$(cap_of "$hpid" CapBnd)"
        [ "$v" = "$helper_caps" ] && ok "a live helper's CapBnd is exactly the two ($v)" || bad "a live helper's CapBnd is '$v', want $helper_caps"
        v="$(cap_of "$hpid" CapEff)"
        [ "$v" = "$helper_caps" ] && ok "a live helper's CapEff is the two" || bad "a live helper's CapEff is '$v', want $helper_caps"
    else
        bad "no live ruya-platform-identify@ instance while a request was held ('$inst')"
    fi
    wait "$holder"
    out="$(cat "$work/helper.out")"
    [ "$out" = "helper files pid $holder info missing" ] && ok "a root request is answered (root's own / has no .flatpak-info)" \
        || bad "the helper's answer to root: '$out', want 'helper files pid $holder info missing'"
    out="$(python3 -I "$here/vm-platform-probe.py" helper "$sock" 0 2>&1)"
    [ "$out" = "helper refused bad-request" ] && ok "a request for uid 0 is refused" || bad "a request for uid 0: '$out', want 'helper refused bad-request'"
    if [ -n "${user:-}" ]; then
        out="$(runuser -u "$user" -- python3 -I "$helpers/vm-platform-probe.py" helper "$sock" 65534 2>&1)"
        [ "$out" = "helper error PermissionError" ] && ok "$user cannot connect to the helper" || bad "$user and the helper's socket: '$out'"
    fi
}

# Item 4 of RUY-1129: code running unsandboxed as the profile binds a file it cannot read onto
# /.flatpak-info in a matching scope; the helper must not read it for the door.
check_deputy() {
    local inst t0 out door helper
    echo "--- the confused deputy: /etc/shadow on /.flatpak-info"
    inst="9$(date +%s | tail -c 7)"
    t0="$(date +%s)"
    out="$(systemd-run --machine="$user@.host" --user --wait --pipe --quiet --collect --no-ask-password -- \
        systemd-run --user --scope --quiet --collect --unit="app-flatpak-$appa-$inst" -- \
        bwrap --ro-bind /usr /usr --symlink usr/lib64 /lib64 --symlink usr/bin /bin --proc /proc --dev /dev \
            --ro-bind /etc /etc --bind /run/dbus /run/dbus --ro-bind "$helpers" "$helpers" \
            --ro-bind /etc/shadow /.flatpak-info -- \
            /usr/bin/python3 -I "$helpers/vm-platform-probe.py" register </dev/null 2>&1 | tail -1)"
    [ "$out" = "register not-an-app" ] && ok "a bound /etc/shadow in app-flatpak-$appa-$inst.scope: not-an-app" \
        || bad "Register with /etc/shadow on /.flatpak-info: '$out', want 'register not-an-app'"
    sleep 1
    door="$(journalctl -b -u ruya-platform.service --since "@$t0" -o cat --no-pager 2>&1)"
    helper="$(journalctl -b -t ruya-platform-identify --since "@$t0" -o cat --no-pager 2>&1)"
    echo "$helper" | grep -q '\.flatpak-info not-owned, nothing read' && ok "the helper read nothing of it (not-owned)" \
        || bad "no 'not-owned, nothing read' in the helper's journal: $(echo "$helper" | tail -3 | tr '\n' ' ')"
    echo "$door" | grep -q 'is not an app: flatpak-info not-owned' && ok "the door logged flatpak-info not-owned" \
        || bad "no 'flatpak-info not-owned' in the door's journal: $(echo "$door" | tail -3 | tr '\n' ' ')"
    if echo "$door" | grep -q 'bad flatpak-info'; then
        bad "the door was given bytes of the bound file (bad flatpak-info)"
    else
        ok "the door was given no bytes of it"
    fi
}

# The log the probe of app $1 writes in the profile's data of that app.
log_of() { echo "$home/.var/app/$1/data/platform.log"; }
# Waits up to $3 s until the log of app $1 has a line matching $2.
wait_line() {
    local n=0
    while ! grep -qE "$2" "$(log_of "$1")" 2>/dev/null; do
        [ "$n" -ge "$3" ] && return 1
        sleep 1; n=$((n + 1))
    done
}
# The Flatpak scope of the running instance of app $1 (one instance at a time here).
scope_of() {
    systemctl --user -M "$user@.host" list-units --state=active --plain --no-legend --full "app-flatpak-$1-*.scope" </dev/null 2>&1 \
        | awk '{print $1}' | head -1
}
launch() { as_shell busctl --system call "$ssvc" "$spath" "$ssvc" Launch ss "$1" "$pid" 2>&1; }
notify() { busctl --system call "$dest" "$opath" "$manage" NotifyLifecycle ssst "$pid" "$1" "$2" "$3" 2>&1; }
permit() { busctl --system call "$dest" "$opath" "$manage" SetPermission sssb "$pid" "$1" lifecycle "$2" 2>&1; }
stop_all() {
    systemctl --user -M "$user@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null
    for id in "$appa" "$appb"; do
        for sc in $(systemctl --user -M "$user@.host" list-units --plain --no-legend --full "app-flatpak-$id-*.scope" </dev/null 2>&1 | awk '{print $1}'); do
            systemctl --user -M "$user@.host" stop "$sc" </dev/null 2>&1 | cat >/dev/null
        done
    done
}

mode="${1:-check}"
case "$mode" in
clean)
    drop_apps; echo "removed the Platform1 test apps"; exit 0 ;;
identity)
    put_helpers; signed_in; check_identity
    echo; [ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"; exit "$fail" ;;
deputy)
    put_helpers; signed_in || exit 1; check_deputy
    echo; [ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"; exit "$fail" ;;
check) ;;
*) echo "usage: $0 [check|clean|identity|deputy]"; exit 2 ;;
esac

echo "--- the service"
[ "$(systemctl is-active ruya-platform.service)" = active ] && ok "ruya-platform.service is active" || { bad "ruya-platform.service is not active"; journalctl -b -u ruya-platform --no-pager -n 20; exit 1; }
echo "info: $(systemd-analyze security ruya-platform.service --no-pager 2>/dev/null | tail -1)"
for f in vm-platform-probe.py vm_dbus.py; do [ -f "$here/$f" ] || { bad "$f must be next to this script"; exit 1; }; done

signed_in || exit 1

echo "--- the test apps"
drop_apps
build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
put_helpers || { bad "cannot copy the helpers to $helpers"; exit 1; }
check_identity
flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" >/dev/null 2>&1 || { bad "remote-add"; exit 1; }
flatpak install --system -y --noninteractive "$remote" "$rt" "$appa" "$appb" >"$work/install.log" 2>&1 \
    && ok "test apps installed" || { tail -n 5 "$work/install.log"; bad "flatpak install of the test apps failed"; drop_apps; exit 1; }
stop_all
rm -f "$(log_of "$appa")" "$(log_of "$appb")"
permit "$appa" true >/dev/null; permit "$appb" true >/dev/null

echo "--- Register through xdg-dbus-proxy"
reg_t0="$(date +%s)"
inst_of() { sed -n 's/^ss "ok" "\(.*\)"$/\1/p'; }
for id in "$appa" "$appb"; do
    out="$(launch "$id")"
    echo "$out" | grep -q '"ok"' && ok "Launch $id" || bad "Launch $id: $out"
    [ "$id" = "$appa" ] && inst_a="$(echo "$out" | inst_of)"
done
for id in "$appa" "$appb"; do
    if wait_line "$id" '^listening' 30; then
        grep -q '^register ok$' "$(log_of "$id")" && ok "$id: Register ok (identity from its connection)" \
            || bad "$id: $(grep '^register' "$(log_of "$id")") (journal: $(journalctl -b -u ruya-platform --no-pager -o cat -n 3 | tr '\n' ' '))"
    else
        bad "$id: the probe did not get to listening in 30 s: $(cat "$(log_of "$id")" 2>&1 | tr '\n' ' ')"
    fi
done

# The Registers went through the helper (ADR-022 decision 4): one answer with both files per app.
n="$(journalctl -b -t ruya-platform-identify --since "@$reg_t0" -o cat --no-pager 2>/dev/null | grep -cE '^ruya-platform-identify: pid [0-9]+: [.]flatpak-info [0-9]+ bytes; cgroup [0-9]+ bytes$')"
[ "${n:-0}" -ge 2 ] && ok "the helper read both apps' .flatpak-info and cgroup ($n answers)" || bad "the helper's journal has ${n:-0} answers with both files since the Registers, want 2 or more"

echo "--- what an app must not reach"
for what in Manage.ListCapabilities Manage.ListPermissions Manage.SetPermission Manage.NotifyLifecycle; do
    line="$(grep "^[A-Z]*[a-z]* $what " "$(log_of "$appa")")"
    [ "$line" = "refused $what org.freedesktop.DBus.Error.AccessDenied" ] && ok "$what is AccessDenied by the policy" || bad "$what: '$line', want AccessDenied"
done
for what in Profiles1.ListProfiles Session1.ListRunning Input1.ListPads; do
    line="$(grep " $what " "$(log_of "$appa")")"
    case "$line" in
    "refused $what org.freedesktop.DBus.Error."*) ok "$what is not reachable (${line##* })" ;;
    *) bad "$what from the sandbox: '$line'" ;;
    esac
done
out="$(runuser -u "$user" -- python3 -I "$helpers/vm-platform-probe.py" register 2>&1)"
[ "$out" = "register not-an-app" ] && ok "an unsandboxed process of $user is not-an-app" || bad "unsandboxed Register as $user: $out"
check_deputy
out="$(runuser -u nobody -- busctl --system call "$dest" "$opath" "$manage" ListPermissions s "$pid" 2>&1)"
echo "$out" | grep -qi "access denied\|AccessDenied" && ok "nobody cannot call Manage" || bad "nobody calling Manage.ListPermissions: $out"

out="$(busctl --system call "$dest" "$opath" "$manage" ListCapabilities 2>&1)"
[ "$out" = 'sa(sb) "ok" 1 "lifecycle" true' ] && ok "ListCapabilities as root: lifecycle, on by default" || bad "ListCapabilities as root: $out"

echo "--- unicast Lifecycle signals"
sa="$(scope_of "$appa")"; sb="$(scope_of "$appb")"
[ -n "$sa" ] && [ -n "$sb" ] && ok "scopes $sa and $sb" || bad "no scope for the test apps ('$sa' '$sb')"
out="$(notify "$sa" resume 4242)"
[ "$out" = 's "ok"' ] && ok "NotifyLifecycle resume: ok" || bad "NotifyLifecycle resume: $out"
wait_line "$appa" '^signal org.ruyaos.Platform1.Lifecycle.Resume 4242$' 5 && ok "A received Resume(4242)" || bad "A received no Resume(4242)"
out="$(notify "$sa" stopping 5000)"
[ "$out" = 's "saved"' ] && ok "NotifyLifecycle stopping: saved (A called SaveDone)" || bad "NotifyLifecycle stopping: $out"
grep -q '^savedone ok$' "$(log_of "$appa")" && ok "A's SaveDone: ok" || bad "A's SaveDone: $(grep '^savedone' "$(log_of "$appa")")"

echo "--- ruya-session's path (RUY-1099): Freeze and Thaw of A"
inst="${inst_a:-}"
before="$(grep -c 'Lifecycle.Resume' "$(log_of "$appa")")"
if [ -n "$inst" ]; then
    as_shell busctl --system call "$ssvc" "$spath" "$ssvc" Freeze s "$inst" >/dev/null 2>&1
    sleep 2
    as_shell busctl --system call "$ssvc" "$spath" "$ssvc" Thaw s "$inst" >/dev/null 2>&1
    n=0; while [ "$(grep -c 'Lifecycle.Resume' "$(log_of "$appa")")" -le "$before" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
    [ "$(grep -c 'Lifecycle.Resume' "$(log_of "$appa")")" -gt "$before" ] && ok "a Thaw through Session1 gives A a Resume ($(grep 'Lifecycle.Resume' "$(log_of "$appa")" | tail -1))" \
        || bad "no Resume in A after Freeze/Thaw of $inst"
else
    bad "Launch named no instance of A"
fi
grep -q '^signal org.ruyaos.Platform1' "$(log_of "$appb")" && bad "B heard A's signals: $(grep '^signal' "$(log_of "$appb")" | tr '\n' ' ')" || ok "B heard none of A's signals"

echo "--- the player turns lifecycle off for A"
out="$(permit "$appa" false)"
[ "$out" = 's "ok"' ] && ok "SetPermission lifecycle off: ok" || bad "SetPermission off: $out"
out="$(notify "$sa" resume 1)"
[ "$out" = 's "not-registered"' ] && ok "A's registration ended: not-registered" || bad "NotifyLifecycle after the withdrawal: $out"
out="$(systemd-run --machine="$user@.host" --user --wait --pipe --quiet --collect --no-ask-password flatpak run --command=sh "$appa" -c "PYTHONHOME=/run/host/usr /run/host/usr/lib64/ld-linux-x86-64.so.2 --library-path /run/host/usr/lib64 /run/host$(readlink -f /usr/bin/python3) -I /app/share/vm-platform-probe.py register" 2>&1 | tail -1)"
[ "$out" = "register not-allowed" ] && ok "a new instance of A is refused: not-allowed" || bad "Register of a new instance of A after the withdrawal: $out"
permit "$appa" true >/dev/null

echo "--- Session1.Stop sends Stopping and waits for SaveDone"
stop_all; rm -f "$(log_of "$appa")"
out="$(launch "$appa")"; echo "$out" | grep -q '"ok"' || bad "Launch A again: $out"
wait_line "$appa" '^listening' 30 || bad "A did not get to listening again"
inst="$(echo "$out" | inst_of)"
saves="$(grep -c '^savedone ok' "$(log_of "$appa")")"
as_shell busctl --system call "$ssvc" "$spath" "$ssvc" Stop s "$inst" >/dev/null 2>&1
n=0; while [ "$(grep -c '^savedone ok' "$(log_of "$appa")")" -le "$saves" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
[ "$(grep -c '^savedone ok' "$(log_of "$appa")")" -gt "$saves" ] && ok "Stop of A: Stopping arrived, SaveDone ok" || bad "Stop of A: no SaveDone ($(grep '^signal' "$(log_of "$appa")" | tail -2 | tr '\n' ' '))"

stop_all
drop_apps
echo; [ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
