#!/usr/bin/env bash
# Host tests of the VM check scripts (T-296): the parts of scripts/vm-*-check.sh that can run without a
# VM, on canned data and with fake tools in front of PATH. Run by scripts/lint-vm-checks.ps1 (dev.ps1 test,
# CI); also directly:  bash scripts/test-vm-checks.sh
# It proves that a check FAILS when the thing it checks is broken, not only that it passes when fine:
#   - vm-devices-check.sh  picks the volume by its keys, whatever the order of the keys
#   - vm-storage-check.sh  a refused action is pkcheck exit 1 (not any non-zero); an error reply from
#                          ListVolumes is not "the volume left the list"
#   - vm-security-check.sh each step (exposure, port, SELinux, setuid, world-writable, account) can FAIL; a port
#                          is keyed with its scope (loopback or any), so a loopback listener on every address FAILs
#   - vm-sample-check.sh   an early failure still cleans up (trap on EXIT)
#   - vm-x11-check.sh      only a real refusal passes a negative probe; vm-x11-client.py against a fake X server
#                          (test-vm-x11-client.py); vm-security-check.sh's x11 step (abstract listener, socket
#                          mode and owner, Xwayland's -auth, -nolisten local and SELinux domain)
#   - vm-security-check.sh the busrecv step (a service's signals go to root and ruya-shell only: RUY-594) and the
#                          `signals` mode; vm-input-probe.py's signal listener (test-vm-input-probe.py)
#   - vm-profiles-check.sh the `guests` mode (RUY-125) against a fake Profiles1: each assertion can FAIL
#   - vm-input-check.sh    the `players` mode (RUY-121): no probe or a refused CreateProfile fails, the probe gets the
#                          second profile, which is removed afterwards (also after a FAIL); the probe's JoinPlayer
#                          reply and ListPlayers parsing (test-vm-input-probe.py); the `seathold` mode (RUY-627): the
#                          RUYA_SEAT_HOLD_SECS drop-in is there for the probe and gone afterwards (also after a FAIL), a
#                          missing journal line fails; the probe's udevadm-monitor and ListPlayers helpers; the
#                          `coop` mode (RUY-681): seathold's set-up for the probe's coop command; the `twopads`
#                          journal order (RUY-541, RUY-681): pad2 ready before pad1, or never, FAILs; the
#                          `join` mode (RUY-628): VerifyPin wrong then right before JoinPlayer, a wrong PIN that
#                          answers ok, a VerifyPin that signs in, a refused join and a missing seat each FAIL; the
#                          `forget` step of `profiles` (RUY-468): a directory left after ForgetConsoleProfile, a
#                          hostile id that is followed, a listed non-id and a stale listed id each FAIL
#   - vm-boot-check.sh     the `watchdog` mode (RUY-483): the unit's three settings, a restart or trip before the
#                          test, a missing start line, no restart, a second restart and a restart without systemd's
#                          trip line each FAIL; a shell that stays stopped is continued at exit
#   - vm-play-check.sh     (RUY-829) the `parse` mode reads busctl JSON by key (job state and status, statuses,
#                          ListSources paths, Library1 ids); the check never turns signature checks off, cleans
#                          up on exit and mounts its drive nosuid,nodev,noexec; `parse perms` (RUY-851) reads
#                          Flatpak permission sections in any order as the perms mode compares them, and an
#                          extra filesystem or bus name makes them differ from the mapped set
#   - vm-notifications-check.sh (RUY-730) against a fake Notifications1: each step (unit, exposure, Post and
#                          Added, MarkRead, a restart that loses items, ids or the setting, the shell's journal
#                          line and GetAll, the shell's Post, keyed replace, Withdraw, a switched-off source,
#                          nobody's Post) can FAIL; the exit trap locks again and puts the setting back
# Needs bash and python3 (python on Windows). Exit 0 = all pass.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "    ok   $*"; }
fail() { echo "    FAIL $*"; fails=$((fails + 1)); }
expect_contains() { # <name> <text> <needle>
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: no '$3' in: $2" ;; esac
}
expect_lacks() { # <name> <text> <needle>
    case "$2" in *"$3"*) fail "$1: found '$3' in: $2" ;; *) pass "$1" ;; esac
}

# The guest has python3; a Windows host may only have python.
shims="$tmp/shims"; mkdir -p "$shims"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import json' >/dev/null 2>&1; then
    py="$(command -v python)" || { echo "    FAIL no python3 or python on PATH"; exit 1; }
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$py" > "$shims/python3"; chmod +x "$shims/python3"
fi

# --- fake tools ---------------------------------------------------------------------------------
# busctl: prints $FAKE_BUSCTL_OUT and exits $FAKE_BUSCTL_RC. With $FAKE_STATE set it is a service that
# lists $FAKE_BEFORE until Eject has been called and answers with $FAKE_AFTER_OUT / $FAKE_AFTER_RC afterwards.
# sleep: does not wait. lsblk: no disk.
cat > "$shims/busctl" <<'SHIMEOF'
#!/bin/sh
if [ -n "${FAKE_STATE:-}" ]; then
    case "$*" in *Eject*) echo 's "ok"'; touch "$FAKE_STATE/ejected"; exit 0 ;; esac
    if [ -e "$FAKE_STATE/ejected" ]; then
        echo "${FAKE_AFTER_OUT:-}"; exit "${FAKE_AFTER_RC:-0}"
    fi
    cat "$FAKE_BEFORE"; exit 0
fi
printf '%s\n' "${FAKE_BUSCTL_OUT:-}"
exit "${FAKE_BUSCTL_RC:-0}"
SHIMEOF
# runuser -u <user> -- cmd: just runs cmd. systemctl, pkill: succeed. findmnt: nothing is mounted.
cat > "$shims/runuser" <<'SHIMEOF'
#!/bin/sh
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SHIMEOF
printf '#!/bin/sh\nexit 0\n' > "$shims/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$shims/pkill"
printf '#!/bin/sh\nexit 1\n' > "$shims/findmnt"
printf '#!/bin/sh\nexit 0\n' > "$shims/sleep"
printf '#!/bin/sh\nexit 0\n' > "$shims/lsblk"
printf '#!/bin/sh\nexit 0\n' > "$shims/pkaction"
printf '#!/bin/sh\nexit "${FAKE_PKCHECK_RC:-0}"\n' > "$shims/pkcheck"
# id: the scripts ask for the uid of the guest's ruya-shell user, which a host does not have.
printf '#!/bin/sh\nif [ "$2" = ruya-shell ]; then echo 1000; else exec /usr/bin/id "$@"; fi\n' > "$shims/id"
chmod +x "$shims"/*
export PATH="$shims:$PATH"

# --- vm-devices-check.sh: volumes are picked by key, not by position in the text --------------------
echo "vm-devices-check.sh: pick_removable_volume"
python3 -I - "$tmp" <<'PYEOF'
import json, sys
tmp = sys.argv[1]
def val(t, d):
    return {"type": t, "data": d}
def vol(**kw):
    kinds = {"drive": "o", "filesystem": "s", "free_bytes": "t", "id": "s", "label": "s", "mount_point": "s",
             "mounted": "b", "read_only": "b", "removable": "b", "size_bytes": "t"}
    # sorted keys, the order the service sends them (a BTreeMap): "drive" first
    return {k: val(kinds[k], kw[k]) for k in sorted(kw)}
volumes = [
    vol(drive="/d/int", filesystem="ext4", free_bytes=1, id="/org/internal", label="OS", mount_point="/var",
        mounted=True, read_only=False, removable=False, size_bytes=9),
    vol(drive="/d/ro", filesystem="exfat", free_bytes=1, id="/org/readonly", label="RO", mount_point="/run/media/ro",
        mounted=True, read_only=True, removable=True, size_bytes=9),
    vol(drive="/d/off", filesystem="exfat", free_bytes=1, id="/org/unmounted", label="OFF", mount_point="",
        mounted=False, read_only=False, removable=True, size_bytes=9),
    vol(drive="/d/usb", filesystem="exfat", free_bytes=1, id="/org/usb1", label="STICK", mount_point="/run/media/x/STICK",
        mounted=True, read_only=False, removable=True, size_bytes=9),
]
def doc(vs):
    return json.dumps({"type": "aa{sv}", "data": [vs]})
def reverse(vs):
    return [{k: v[k] for k in reversed(list(v))} for v in vs]
open(tmp + "/vols-sorted.json", "w").write(doc(volumes))
open(tmp + "/vols-reversed.json", "w").write(doc(reverse(volumes)))
open(tmp + "/vols-shuffled.json", "w").write(doc(reverse(volumes)[::-1]))
open(tmp + "/vols-none.json", "w").write(doc(volumes[:3]))
open(tmp + "/vols-empty.json", "w").write(doc([]))
PYEOF
(
    export VM_CHECK_LIB_ONLY=1
    # shellcheck disable=SC1090
    . "$here/vm-devices-check.sh"
    want=$'/org/usb1\n/run/media/x/STICK'
    for f in sorted reversed shuffled; do
        got="$(pick_removable_volume < "$tmp/vols-$f.json" | tr -d '\r')"   # Windows python prints CRLF
        [ "$got" = "$want" ] && pass "keys in $f order: the writable mounted removable volume" || fail "keys in $f order: got '$got'"
    done
    got="$(pick_removable_volume < "$tmp/vols-none.json")"
    [ -z "$got" ] && pass "no eligible volume: nothing picked" || fail "no eligible volume, got '$got'"
    got="$(pick_removable_volume < "$tmp/vols-empty.json")"
    [ -z "$got" ] && pass "empty list: nothing picked" || fail "empty list, got '$got'"
    if echo 'a{sv} 1 "x" s "y"' | pick_removable_volume >/dev/null 2>&1; then fail "text output (not JSON) was accepted"; else pass "not JSON: exit non-zero"; fi
) > "$tmp/devices.out" 2>&1
cat "$tmp/devices.out"
fails=$((fails + $(grep -c '^    FAIL' "$tmp/devices.out")))

# --- vm-storage-check.sh -------------------------------------------------------------------------
echo "vm-storage-check.sh: polkit_expect refuses only on exit 1"
(
    export VM_CHECK_LIB_ONLY=1
    # shellcheck disable=SC1090
    . "$here/vm-storage-check.sh"
    for rc in 1 0 2 127; do
        export FAKE_PKCHECK_RC=$rc
        out="$(fail=0; polkit_expect org.example.x 1 deny "refused" 2>&1; echo "fail=$fail")"
        case "$rc" in
        1) expect_contains "pkcheck exit 1 is a refusal" "$out" "PASS: refused (exit 1)" ;;
        *) expect_contains "pkcheck exit $rc is not a refusal" "$out" "FAIL:" ;;
        esac
    done
) > "$tmp/storage1.out" 2>&1
cat "$tmp/storage1.out"
fails=$((fails + $(grep -c '^    FAIL' "$tmp/storage1.out")))

echo "vm-storage-check.sh: a failed ListVolumes is not 'the volume left the list'"
# gone: the host detached the stick, wait until the service lists nothing. With busctl failing
# (service down, call refused) the old check printed PASS.
out="$(FAKE_BUSCTL_RC=1 FAKE_BUSCTL_OUT='Failed to call method: Access denied' bash "$here/vm-storage-check.sh" gone 2>&1)"
expect_contains "busctl error: FAIL" "$out" "FAIL: ListVolumes failed"
expect_lacks "busctl error: no PASS for an empty list" "$out" "PASS: the service lists no volume"
out="$(FAKE_BUSCTL_OUT='{"type":"aa{sv}","data":[[]]}' bash "$here/vm-storage-check.sh" gone 2>&1)"
expect_contains "an empty list: PASS" "$out" "PASS: the service lists no volume"
expect_lacks "an empty list: no FAIL" "$out" "FAIL"
out="$(FAKE_BUSCTL_OUT='{"type":"aa{sv}","data":[[{"label":{"type":"s","data":"RUYASTICK"}}]]}' bash "$here/vm-storage-check.sh" gone 2>&1)"
expect_contains "a listed volume: FAIL" "$out" "FAIL: the service still lists volumes"

echo "vm-storage-check.sh: eject and meject need a successful ListVolumes to call a volume gone"
printf '%s' '{"type":"aa{sv}","data":[[{"label":{"type":"s","data":"RUYASTICK"},"id":{"type":"s","data":"/org/stick"},"mount_point":{"type":"s","data":"/nonexistent-mnt"}},{"label":{"type":"s","data":"RUYAPART1"},"id":{"type":"s","data":"/org/p1"},"mount_point":{"type":"s","data":"/nonexistent-p1"}}]]}' > "$tmp/before.json"
for step in eject meject; do
    rm -rf "$tmp/state"; mkdir -p "$tmp/state"
    out="$(FAKE_STATE="$tmp/state" FAKE_BEFORE="$tmp/before.json" FAKE_AFTER_RC=1 FAKE_AFTER_OUT='Failed to call method: Access denied' bash "$here/vm-storage-check.sh" $step 2>&1)"
    expect_contains "$step: an error reply after the Eject is a FAIL" "$out" "FAIL: ListVolumes failed"
    expect_lacks "$step: an error reply is not 'left the list'" "$out" "PASS: the volume left the list"
    expect_lacks "$step: an error reply is not 'all three left'" "$out" "PASS: all three partitions left the list"
    rm -rf "$tmp/state"; mkdir -p "$tmp/state"
    out="$(FAKE_STATE="$tmp/state" FAKE_BEFORE="$tmp/before.json" FAKE_AFTER_OUT='{"type":"aa{sv}","data":[[]]}' bash "$here/vm-storage-check.sh" $step 2>&1)"
    case "$step" in
    eject) expect_contains "eject: an empty list after the Eject is a PASS" "$out" "PASS: the volume left the list" ;;
    meject) expect_contains "meject: an empty list after the Eject is a PASS" "$out" "PASS: all three partitions left the list" ;;
    esac
    expect_lacks "$step: an empty list is not 'ListVolumes failed'" "$out" "ListVolumes failed"
done

# --- vm-security-check.sh: every step can fail (T-424) ----------------------------------------------
echo "vm-security-check.sh: each step fails on a worse fixture"
sec="$tmp/sec"; mkdir -p "$sec/bin" "$sec/units"
touch "$sec/units/ruya-aaa.service" "$sec/units/ruya-bbb@.service"
cat > "$sec/baseline.json" <<'JSONEOF'
{"units": {"ruya-aaa.service": {"max_exposure": 1.1, "reason": "t"}, "ruya-bbb@.service": {"max_exposure": 2.0, "reason": "t"}},
 "ports": [{"port": "tcp:any:22", "reason": "sshd"}, {"port": "udp:any:68", "reason": "dhcp"}, {"port": "tcp:loopback:53", "reason": "stub"}, {"port": "udp:loopback:323", "reason": "chronyd"}],
 "unconfined": [{"process": "ruya-odd", "reason": "t"}, {"process": "ruya-notifications", "reason": "t"}],
 "setid": [{"path": "/usr/bin/passwd", "reason": "t"}],
 "accounts": [{"name": "root", "reason": "t"}],
 "xwayland_domains": [{"domain": "xserver_t", "reason": "t"}]}
JSONEOF
cat > "$sec/bin/systemd-analyze" <<'SHIMEOF'
#!/bin/sh
for a in "$@"; do u="$a"; done
case "$u" in
ruya-aaa.service) v="${FAKE_EXP_AAA:-1.1}" ;;
*) v=1.5 ;;
esac
echo "  NAME  DESCRIPTION  EXPOSURE"
echo "-> Overall exposure level for $u: $v OK"
SHIMEOF
cat > "$sec/bin/ss" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*-xln*)
    echo "u_str LISTEN 0 4096 /run/dbus/system_bus_socket 100 * 0"
    [ -n "${FAKE_ABSTRACT:-}" ] && echo "u_str LISTEN 0 4096 @/tmp/.X11-unix/X0 101 * 0"
    exit 0 ;;
esac
echo "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"
echo "tcp LISTEN 0 128 [::]:22 [::]:*"
echo "udp UNCONN 0 0 192.168.1.5:68 0.0.0.0:*"
echo "udp UNCONN 0 0 [::1]:323 [::]:*"
echo "udp UNCONN 0 0 127.0.0.1:323 0.0.0.0:*"
# the resolved stub: on loopback (127.0.0.53, bound to lo), or (FAKE_STUB_ANY) on every address
if [ -n "${FAKE_STUB_ANY:-}" ]; then echo "tcp LISTEN 0 4096 0.0.0.0:53 0.0.0.0:*"
else echo "tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*"; echo "tcp LISTEN 0 4096 [::ffff:127.0.0.54]:53 [::]:*"; fi
[ -n "${FAKE_EXTRA_PORT:-}" ] && echo "tcp LISTEN 0 5 0.0.0.0:$FAKE_EXTRA_PORT 0.0.0.0:*"
exit 0
SHIMEOF
printf '#!/bin/sh\necho "${FAKE_ENFORCE:-Enforcing}"\n' > "$sec/bin/getenforce"
cat > "$sec/bin/ps" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*pid=*)     # ps -e -o pid= -o label= -o comm= -o args=
    echo "1 system_u:system_r:init_t:s0 systemd /usr/lib/systemd/systemd"
    [ -n "${FAKE_XWL:-}" ] && echo "4242 system_u:system_r:${FAKE_XWL_DOMAIN:-xserver_t}:s0 Xwayland Xwayland :0 ${FAKE_XWL_ARGS--auth /run/user/1001/ruya-x11/a/Xauthority -nolisten local -terminate -rootless}"
    exit 0 ;;
esac
echo "system_u:system_r:init_t:s0 systemd"
echo "system_u:system_r:ruya_t:s0 ruya-aaa"
[ -n "${FAKE_UNCONFINED:-}" ] && echo "system_u:system_r:unconfined_service_t:s0 $FAKE_UNCONFINED"
exit 0
SHIMEOF
cat > "$sec/bin/find" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*-maxdepth*) [ -n "${FAKE_X11:-}" ] && echo "$FAKE_X11" ;;
*-4000*) echo /usr/bin/passwd; [ -n "${FAKE_SETUID:-}" ] && echo "$FAKE_SETUID" ;;
*-0002*) [ -n "${FAKE_WW:-}" ] && echo "$FAKE_WW" ;;
esac
exit 0
SHIMEOF
chmod +x "$sec"/bin/*
mkdir -p "$sec/x11"
printf 'root:x:0:0:root:/root:/bin/bash\nruya-shell:x:990:990::/var/lib/ruya-shell:/usr/sbin/nologin\n' > "$sec/passwd"
printf 'root:!locked:19000::::::\nruya-shell:!*:19000::::::\n' > "$sec/shadow"
busgood="$here/../image/rootfs/usr/share/dbus-1/system.d"   # the policies we ship are the good fixture
runsec() { # env assignments are inherited from the caller's prefix
    SEC_BUSPOLICY="${BUS:-$busgood}" SEC_BASELINE="$sec/baseline.json" SEC_X11DIR="$sec/x11" SEC_UNITDIRS="$sec/units" SEC_PASSWD="${PW:-$sec/passwd}" SEC_SHADOW="${SH:-$sec/shadow}" \
        PATH="${EXTRA_BIN:+$EXTRA_BIN:}$sec/bin:$PATH" bash "$here/vm-security-check.sh" "$@" 2>&1
}
out="$(runsec)"; rc=$?
expect_contains "a matching fixture: all pass" "$out" "ALL CHECKS PASSED"
expect_lacks "a matching fixture: no FAIL" "$out" "FAIL"
[ "$rc" = 0 ] && pass "exit 0 when all pass" || fail "exit $rc on a matching fixture"
out="$(FAKE_EXP_AAA=1.2 runsec)"; rc=$?
expect_contains "a higher exposure: FAIL" "$out" "FAIL: unit ruya-aaa.service: exposure 1.2 is above the baseline 1.1"
[ "$rc" = 1 ] && pass "a higher exposure: exit 1" || fail "a higher exposure: exit $rc"
out="$(FAKE_EXTRA_PORT=8080 runsec)"
expect_contains "an extra port: FAIL" "$out" "FAIL: unexpected listening sockets: tcp:any:8080"
# RUY-18: the scope is part of the key, so a loopback listener that moves to every address fails
out="$(runsec)"
expect_contains "loopback and any ports are keyed by scope" "$out" "PASS: listening sockets equal the baseline: tcp:any:22, tcp:loopback:53, udp:any:68, udp:loopback:323"
out="$(FAKE_STUB_ANY=1 runsec)"; rc=$?
expect_contains "a loopback port on every address: FAIL" "$out" "FAIL: unexpected listening sockets: tcp:any:53"
expect_contains "a loopback port on every address: the loopback one is missing" "$out" "FAIL: baseline sockets not listening: tcp:loopback:53"
[ "$rc" = 1 ] && pass "a loopback port on every address: exit 1" || fail "a loopback port on every address: exit $rc"
sed 's/"tcp:any:22"/"tcp:22"/' "$sec/baseline.json" > "$sec/baseline-oldports.json"
out="$(SEC_BASELINE="$sec/baseline-oldports.json" SEC_BUSPOLICY="$busgood" SEC_X11DIR="$sec/x11" SEC_UNITDIRS="$sec/units" SEC_PASSWD="$sec/passwd" SEC_SHADOW="$sec/shadow" PATH="$sec/bin:$PATH" bash "$here/vm-security-check.sh" 2>&1)"
expect_contains "a baseline port without a scope: FAIL" "$out" "FAIL: baseline ports not written as proto:scope:port (scope loopback or any): tcp:22"
out="$(SEC_BASELINE="$here/../image/security-baseline.json" SEC_BUSPOLICY="$busgood" SEC_X11DIR="$sec/x11" SEC_UNITDIRS="$sec/units" SEC_PASSWD="$sec/passwd" SEC_SHADOW="$sec/shadow" PATH="$sec/bin:$PATH" bash "$here/vm-security-check.sh" 2>&1)"
expect_lacks "the shipped baseline writes every port as proto:scope:port" "$out" "baseline ports not written"
expect_lacks "the shipped baseline has no LLMNR port (RUY-18)" "$out" ":5355"
out="$(runsec measure)"
expect_contains "measure keys ports by scope" "$out" '"port": "tcp:loopback:53"'
out="$(FAKE_ENFORCE=Permissive runsec)"
expect_contains "Permissive: FAIL" "$out" "FAIL: SELinux is 'Permissive'"
out="$(FAKE_UNCONFINED=ruya-evil runsec)"
expect_contains "an unconfined ruya process: FAIL" "$out" "ruya-evil"
out="$(FAKE_UNCONFINED=ruya-odd runsec)"
expect_lacks "a named unconfined process passes" "$out" "FAIL"
out="$(FAKE_UNCONFINED=ruya-notificati runsec)"
expect_lacks "a named process cut to 15 characters by ps passes" "$out" "FAIL"
out="$(FAKE_SETUID=/usr/bin/evil runsec)"
expect_contains "an extra setuid file: FAIL" "$out" "FAIL: setuid/setgid files not in the baseline: /usr/bin/evil"
out="$(FAKE_WW=/etc/evil.conf runsec)"
expect_contains "a world-writable file: FAIL" "$out" "FAIL: world-writable under /usr or /etc: /etc/evil.conf"
printf 'root:x:0:0:root:/root:/bin/bash\nmallory:x:1001:1001::/home/m:/bin/bash\n' > "$sec/passwd2"
out="$(PW="$sec/passwd2" runsec)"
expect_contains "an extra login shell: FAIL" "$out" "FAIL: accounts with a login shell or usable password not in the baseline: mallory"
printf 'root:!locked:19000::::::\nruya-shell:$6$abc:19000::::::\n' > "$sec/shadow2"
out="$(SH="$sec/shadow2" runsec)"
expect_contains "a usable password on a nologin account: FAIL" "$out" "ruya-shell"
mkdir -p "$sec/bin2"; printf '#!/bin/sh
exit 127
' > "$sec/bin2/ss"; chmod +x "$sec/bin2/ss"
out="$(EXTRA_BIN="$sec/bin2" runsec)"
expect_contains "a failing tool is a FAIL, not a skip" "$out" "FAIL: measuring: ss -H -tuln failed"
mkdir -p "$sec/bin3"; printf '#!/bin/sh
echo "Failed to connect"
exit 1
' > "$sec/bin3/systemd-analyze"; chmod +x "$sec/bin3/systemd-analyze"
out="$(EXTRA_BIN="$sec/bin3" runsec)"
expect_contains "systemd-analyze failing: FAIL, not a skip" "$out" "FAIL: measuring: systemd-analyze security ruya-aaa.service failed"
touch "$sec/units/ruya-new.service"
out="$(runsec)"
expect_contains "a unit missing from the baseline: FAIL" "$out" "FAIL: unit ruya-new.service is not in the baseline"
rm -f "$sec/units/ruya-new.service"
out="$(runsec measure)"
expect_contains "measure prints a draft baseline" "$out" '"max_exposure": 1.1'

# --- the bus receive rules (RUY-594) ---
echo "vm-security-check.sh: the bus policy's receive rules"
out="$(runsec)"
for n in Devices1 Input1 Library1 Profiles1 Session1 Store1 Update1; do
    expect_contains "the shipped $n policy: its signals go to root and ruya-shell only" "$out" "PASS: busrecv: org.ruyaos.$n signals go to root and ruya-shell only"
done
mkdir -p "$sec/bus"
mutate_bus() { # name, file, sed script: a copy of the shipped policies with one file changed
    rm -rf "$sec/bus/$1"; mkdir -p "$sec/bus/$1"; cp "$busgood"/org.ruyaos.*.conf "$sec/bus/$1/"
    sed -i -e "$3" "$sec/bus/$1/$2"
    grep -q "" "$sec/bus/$1/$2"
}
mutate_bus nodeny org.ruyaos.Input1.conf '/<deny receive_sender=/d'
out="$(BUS="$sec/bus/nodeny" runsec)"; rc=$?
expect_contains "no default deny receive_sender: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Input1.conf: no default-context deny receive_sender for org.ruyaos.Input1"
[ "$rc" = 1 ] && pass "no default deny receive_sender: exit 1" || fail "no default deny receive_sender: exit $rc"
mutate_bus noroot org.ruyaos.Session1.conf '/<policy user="root">/,/<\/policy>/{/receive_sender/d}'
out="$(BUS="$sec/bus/noroot" runsec)"
expect_contains "no receive allow for root: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Session1.conf: signals of org.ruyaos.Session1 are allowed to ruya-shell, want root and ruya-shell"
mutate_bus noshell org.ruyaos.Store1.conf '/<policy user="ruya-shell">/,/<\/policy>/{/receive_sender/d}'
out="$(BUS="$sec/bus/noshell" runsec)"
expect_contains "no receive allow for ruya-shell: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Store1.conf: signals of org.ruyaos.Store1 are allowed to root, want root and ruya-shell"
mutate_bus other org.ruyaos.Profiles1.conf 's|^</busconfig>|  <policy user="nobody"><allow receive_sender="org.ruyaos.Profiles1" receive_type="signal"/></policy></busconfig>|'
out="$(BUS="$sec/bus/other" runsec)"
expect_contains "a receive allow for another user: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Profiles1.conf: unexpected receive rule allow for org.ruyaos.Profiles1 in policy nobody"
mutate_bus notype org.ruyaos.Update1.conf 's| receive_type="signal"||'
out="$(BUS="$sec/bus/notype" runsec)"
expect_contains "a receive rule without receive_type: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Update1.conf: a receive rule for org.ruyaos.Update1 without receive_type=signal"
# RUY-616: a narrowed default deny closes nothing; a receive deny for root or ruya-shell cuts them off
for attr in 'receive_member="Nothing"' 'receive_interface="org.x.Nothing"' 'receive_path="/nothing"' 'receive_error="org.x.Nothing"' 'receive_requested_reply="true"' 'eavesdrop="true"'; do
    name="narrow_${attr%%=*}"
    mutate_bus "$name" org.ruyaos.Library1.conf "s|<deny receive_sender=\"org.ruyaos.Library1\" receive_type=\"signal\"|& $attr|"
    out="$(BUS="$sec/bus/$name" runsec)"; rc=$?
    expect_contains "a default receive deny narrowed by ${attr%%=*}: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Library1.conf: a narrowed receive deny does not close the default for org.ruyaos.Library1 (it also names ${attr%%=*})"
    expect_contains "... and the default is then missing (${attr%%=*})" "$out" "FAIL: busrecv: org.ruyaos.Library1.conf: no default-context deny receive_sender for org.ruyaos.Library1"
    [ "$rc" = 1 ] && pass "narrowed by ${attr%%=*}: exit 1" || fail "narrowed by ${attr%%=*}: exit $rc"
done
mutate_bus rootdeny org.ruyaos.Session1.conf 's|\(<policy user="root">\)|\1<deny receive_sender="org.ruyaos.Session1" receive_type="signal"/>|'
out="$(BUS="$sec/bus/rootdeny" runsec)"
expect_contains "a receive deny in the root policy: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Session1.conf: unexpected receive rule deny for org.ruyaos.Session1 in policy root (it would cut the shell or root off"
mutate_bus shelldeny org.ruyaos.Store1.conf 's|\(<policy user="ruya-shell">\)|\1<deny receive_sender="org.ruyaos.Store1" receive_type="signal"/>|'
out="$(BUS="$sec/bus/shelldeny" runsec)"
expect_contains "a receive deny in the ruya-shell policy: FAIL" "$out" "FAIL: busrecv: org.ruyaos.Store1.conf: unexpected receive rule deny for org.ruyaos.Store1 in policy ruya-shell (it would cut the shell or root off"
mkdir -p "$sec/bus/empty"
out="$(BUS="$sec/bus/empty" runsec)"
expect_contains "no policy files: FAIL, not a skip" "$out" "FAIL: busrecv: no org.ruyaos.*.conf to check"
# `signals` runs vm-input-check.sh from the same directory; its absence is a FAIL
out="$(SEC_INPUT_CHECK="$sec/nowhere/vm-input-check.sh" bash "$here/vm-security-check.sh" signals 2>&1)"; rc=$?
expect_contains "signals without vm-input-check.sh: FAIL" "$out" "FAIL: signals: vm-input-check.sh and vm-input-probe.py must be next to this script"
[ "$rc" = 1 ] && pass "signals without the scripts: exit 1" || fail "signals without the scripts: exit $rc"
mkdir -p "$sec/sig"; touch "$sec/sig/vm-input-probe.py"
printf '#!/bin/sh
echo "ran signals step: $*"
exit 3
' > "$sec/sig/vm-input-check.sh"
out="$(SEC_INPUT_CHECK="$sec/sig/vm-input-check.sh" bash "$here/vm-security-check.sh" signals 2>&1)"; rc=$?
expect_contains "signals runs vm-input-check.sh signals" "$out" "ran signals step: signals"
[ "$rc" = 3 ] && pass "signals passes the step's exit status on" || fail "signals: exit $rc, wanted 3"

# --- the X11 assertions (RUY-436, ADR-034 point 5) ---
echo "vm-security-check.sh: the X11 isolation assertions"
out="$(runsec)"
expect_contains "no Xwayland, no X socket: the abstract check passes" "$out" "PASS: no abstract @/tmp/.X11-unix listener"
expect_contains "no X socket: said so" "$out" "PASS: no X socket (X11 apps start one on demand)"
expect_contains "no Xwayland: said so" "$out" "PASS: no Xwayland is running"
out="$(FAKE_ABSTRACT=1 runsec)"; rc=$?
expect_contains "an abstract X11 listener: FAIL" "$out" "FAIL: abstract X11 listener(s) (any sandbox with network could connect): @/tmp/.X11-unix/X0"
[ "$rc" = 1 ] && pass "an abstract listener: exit 1" || fail "an abstract listener: exit $rc"
out="$(FAKE_X11='700 ruya-p1 s /tmp/.X11-unix/X0' runsec)"
expect_contains "a 0700 socket of a profile user passes" "$out" "PASS: 1 X socket(s), each 0700 and owned by a profile user"
expect_lacks "a 0700 socket of a profile user: no FAIL" "$out" "FAIL"
out="$(FAKE_X11='777 ruya-p1 s /tmp/.X11-unix/X0' runsec)"
expect_contains "a world-accessible X socket: FAIL" "$out" "FAIL: X socket /tmp/.X11-unix/X0 is mode 777 owned by ruya-p1"
out="$(FAKE_X11='700 root s /tmp/.X11-unix/X1' runsec)"
expect_contains "an X socket of root: FAIL" "$out" "FAIL: X socket /tmp/.X11-unix/X1 is mode 700 owned by root"
out="$(FAKE_X11='700 ruya-shell s /tmp/.X11-unix/X1' runsec)"
expect_contains "an X socket of ruya-shell is not a profile user's: FAIL" "$out" "FAIL: X socket /tmp/.X11-unix/X1 is mode 700 owned by ruya-shell"
out="$(FAKE_XWL=1 runsec)"
expect_contains "Xwayland with -auth and -nolisten local passes" "$out" "PASS: Xwayland 4242 has -auth and -nolisten local"
expect_contains "Xwayland in xserver_t passes" "$out" "PASS: Xwayland 4242 runs in xserver_t (named in the baseline)"
expect_lacks "a good Xwayland: no FAIL" "$out" "FAIL"
out="$(FAKE_XWL=1 FAKE_XWL_ARGS='-nolisten local -terminate' runsec)"
expect_contains "Xwayland without -auth: FAIL" "$out" "FAIL: Xwayland 4242 runs without -auth"
out="$(FAKE_XWL=1 FAKE_XWL_ARGS='-auth /x/Xauthority -terminate' runsec)"
expect_contains "Xwayland without -nolisten local: FAIL" "$out" "FAIL: Xwayland 4242 runs without -nolisten local"
out="$(FAKE_XWL=1 FAKE_XWL_ARGS='-auth /x/Xauthority -nolisten tcp' runsec)"
expect_contains "-nolisten tcp is not -nolisten local: FAIL" "$out" "FAIL: Xwayland 4242 runs without -nolisten local"
out="$(FAKE_XWL=1 FAKE_XWL_DOMAIN=unconfined_service_t runsec)"
expect_contains "Xwayland in an unnamed domain: FAIL" "$out" "FAIL: Xwayland 4242 runs in SELinux domain unconfined_service_t, not in the baseline (xserver_t)"
out="$(FAKE_XWL=1 runsec measure)"
expect_contains "measure lists the Xwayland domain" "$out" '"domain": "xserver_t"'

# --- vm-x11-check.sh (RUY-436): only a real refusal passes a negative probe; the probe client itself ----------
echo "vm-x11-check.sh: verdicts on the probe client's answers"
out="$(
    export VM_CHECK_LIB_ONLY=1
    # shellcheck disable=SC1090
    . "$here/vm-x11-check.sh"
    expect_refused "r1" "refused: ECONNREFUSED"
    expect_refused "r2" "refused: EACCES"
    expect_refused "r3" "refused: setup status 0 Authorization required"
    expect_refused "r4" "accepted"
    expect_refused "r5" "error: ENOENT No such file or directory"
    expect_refused "r6" ""
    expect_refused "r7" "Traceback (most recent call last):"
    expect_accepted "a1" "accepted"
    expect_accepted "a2" "refused: EACCES"
    expect_accepted "a3" "error: no answer to the setup request"
    expect_accepted "a4" ""
    expect_prefix "p1" "error: ENOENT No such file" "error: ENOENT"
    expect_prefix "p2" "refused: EACCES" "error: ENOENT"
)"
for t in r1 r2 r3 a1 p1; do expect_contains "$t passes" "$out" "PASS: $t"; done
for t in r4 r5 r6 r7 a2 a3 a4 p2; do expect_contains "$t fails" "$out" "FAIL: $t"; done
for t in r1 r2 r3 a1 p1; do expect_lacks "$t does not fail" "$out" "FAIL: $t"; done
printf '%s
'     'ruya-compositor: app  RuyaOS X11 test uid 1001 pid 4321 profile p1'     'ruya-compositor: app org.x.Y title uid 1002 pid 99 profile p2'     'ruya-compositor: refused window of uid 1001 pid 77 (other-user)'     'ruya-compositor: app x uid 1001 pid 555 profile (shell)'     'ruya-compositor: app org.a.B Some game uid 1001 pid 4400 profile p1'     'ruya-compositor: app gone app:x' > "$tmp/shell.log"
got="$( (export VM_CHECK_LIB_ONLY=1; . "$here/vm-x11-check.sh"; window_pids 1001 p1 < "$tmp/shell.log") | tr '
' ' ')"
[ "$got" = "4321 4400 " ] && pass "window_pids: the windows of one uid and profile, an empty title included" || fail "window_pids gave '$got'"
echo "vm-x11-client.py: against a fake X server"
out="$(python3 "$here/test-vm-x11-client.py" 2>&1)"; rc=$?
echo "$out"
fails=$((fails + $(echo "$out" | grep -c '^    FAIL')))
[ "$rc" = 0 ] && pass "test-vm-x11-client.py exit 0" || fail "test-vm-x11-client.py exit $rc"
echo "vm-input-probe.py: the signal listener (RUY-594)"
out="$(python3 "$here/test-vm-input-probe.py" 2>&1)"; rc=$?
echo "$out"
fails=$((fails + $(echo "$out" | grep -c '^    FAIL')))
[ "$rc" = 0 ] && pass "test-vm-input-probe.py exit 0" || fail "test-vm-input-probe.py exit $rc"

# --- vm-sample-check.sh: an early failure still cleans -----------------------------------------------
echo "vm-sample-check.sh: cleanup runs when a step fails early"
printf '#!/bin/sh\nexit 3\n' > "$shims/systemctl"
printf '#!/bin/sh\necho "$@" >> "$FAKE_LOG"\nexit 0\n' > "$shims/flatpak"
chmod +x "$shims/systemctl" "$shims/flatpak"
: > "$tmp/flatpak.log"
out="$(FAKE_LOG="$tmp/flatpak.log" bash "$here/vm-sample-check.sh" check 2>&1)"; rc=$?
expect_contains "the early failure is reported" "$out" "FAIL: ruya-session is not active"
[ "$rc" = 1 ] && pass "exit status 1 is kept" || fail "exit status $rc"
log="$(cat "$tmp/flatpak.log")"
expect_contains "the override is reset" "$log" "override --system --reset org.ruyaos.HelloGame"
expect_contains "the app is uninstalled" "$log" "uninstall --system -y --noninteractive org.ruyaos.HelloGame"
expect_contains "the remote is deleted" "$log" "remote-delete --system --force ruyaos-hello-test"

# --- vm-gaming-check.sh (RUY-525, RUY-527): each assertion can fail ---------------------------------
echo "vm-gaming-check.sh: ntsync and the two sysctls, each can fail"
gm="$tmp/gaming/bin"; mkdir -p "$gm"
cat > "$gm/lsmod" <<'SHIMEOF'
#!/bin/sh
echo "Module Size Used by"
[ -z "${FAKE_NO_NTSYNC:-}" ] && echo "ntsync 24576 0"
[ -z "${FAKE_NO_DRIVETEMP:-}" ] && echo "drivetemp 16384 0"
exit 0
SHIMEOF
cat > "$gm/sysctl" <<'SHIMEOF'
#!/bin/sh
case "$2" in
vm.max_map_count) echo "${FAKE_MAP_COUNT:-2147483642}" ;;
kernel.split_lock_mitigate) echo "${FAKE_SPLIT_LOCK:-0}" ;;
esac
SHIMEOF
printf '#!/bin/sh\ncase "$*" in *%%a*) echo "${FAKE_MODE:-666}" ;; *%%U*) echo root:root ;; *) echo system_u:object_r:device_t:s0 ;; esac\n' > "$gm/stat"
printf '#!/bin/sh\nexit 0\n' > "$gm/getent"
printf '#!/bin/sh\n[ -n "${FAKE_OPEN_FAIL:-}" ] && exit 1\nexit 0\n' > "$gm/python3"
chmod +x "$gm"/*
rungame() { NTSYNC_DEV="${DEVPATH:-/dev/null}" PATH="$gm:$PATH" bash "$here/vm-gaming-check.sh" "$@" 2>&1; }
out="$(rungame)"; rc=$?
expect_contains "all good: passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "all good: exit 0" || fail "all good: exit $rc"
out="$(FAKE_NO_NTSYNC=1 rungame)"; rc=$?
expect_contains "module not loaded fails" "$out" "FAIL: module ntsync is not loaded"
[ "$rc" = 1 ] && pass "module not loaded: exit 1" || fail "module not loaded: exit $rc"
out="$(FAKE_NO_DRIVETEMP=1 rungame)"; rc=$?
expect_contains "drivetemp not loaded fails" "$out" "FAIL: module drivetemp is not loaded"
[ "$rc" = 1 ] && pass "drivetemp not loaded: exit 1" || fail "drivetemp not loaded: exit $rc"
out="$(DEVPATH="$tmp/no-such-dev" rungame)"
expect_contains "no device fails" "$out" "FAIL: $tmp/no-such-dev is not a character device"
out="$(FAKE_MODE=660 rungame)"
expect_contains "mode 0660 fails" "$out" "FAIL: /dev/null mode is 660"
out="$(FAKE_OPEN_FAIL=1 rungame)"
expect_contains "a user who cannot open the device fails" "$out" "cannot open /dev/null read-write"
out="$(FAKE_MAP_COUNT=1048576 rungame)"
expect_contains "Fedora's max_map_count fails" "$out" "FAIL: vm.max_map_count = 1048576"
out="$(FAKE_SPLIT_LOCK=1 rungame)"
expect_contains "split_lock_mitigate 1 fails" "$out" "FAIL: kernel.split_lock_mitigate = 1"
# RUY-531: a fake /sys/block (vda none, sda flash, sdb rotational bfq)
sb="$tmp/sysblock"
mkblk() { mkdir -p "$sb/$1/queue"; echo "$2" > "$sb/$1/queue/scheduler"; echo "$3" > "$sb/$1/queue/rotational"; }
mkblk vda "[none] mq-deadline kyber bfq" 0
mkblk sda "none [mq-deadline] kyber bfq" 0
mkblk sdb "none mq-deadline kyber [bfq]" 1
out="$(SYS_BLOCK="$sb" rungame)"; rc=$?
expect_contains "scheduler: vda none passes" "$out" "PASS: vda keeps none"
expect_contains "scheduler: flash sda mq-deadline passes" "$out" "PASS: sda (flash) is mq-deadline"
case "$out" in *"sdb (rotational 0)"*) fail "a rotational disk must not be asserted" ;; *) pass "scheduler: rotational sdb is not asserted" ;; esac
[ "$rc" = 0 ] && pass "scheduler: all good exit 0" || fail "scheduler: all good exit $rc"
mkblk sda "none mq-deadline kyber [bfq]" 0
out="$(SYS_BLOCK="$sb" rungame)"; rc=$?
expect_contains "scheduler: flash disk still on bfq fails" "$out" "FAIL: sda (rotational 0) scheduler is none mq-deadline kyber [bfq]"
[ "$rc" = 1 ] && pass "scheduler: bfq on flash exit 1" || fail "scheduler: exit $rc"
mkblk sda "none [mq-deadline] kyber bfq" 0
mkblk vda "none [mq-deadline] kyber bfq" 0
out="$(SYS_BLOCK="$sb" rungame)"
expect_contains "scheduler: vda changed fails" "$out" "FAIL: vda scheduler is none [mq-deadline] kyber bfq"
out="$(rungame flatpak)"; rc=$?
expect_contains "flatpak without an app id is a usage error" "$out" "usage: vm-gaming-check.sh flatpak <app-id>"
[ "$rc" = 2 ] && pass "flatpak without an app id: exit 2" || fail "flatpak without an app id: exit $rc"

# --- vm-session-check.sh: the EXIT trap (RUY-404) -------------------------------------------------
# The trap logic is the block between the "restore trap" markers; a child bash runs it with fake
# systemctl/loginctl that log their calls, sets the flags the way the Freeze part does and exits.
trapsrc="$tmp/restore-trap.sh"
sed -n '/^# --- restore trap begin/,/^# --- restore trap end/p' "$here/vm-session-check.sh" > "$trapsrc"
[ -s "$trapsrc" ] && pass "vm-session-check.sh has the restore trap block" || fail "no restore trap block in vm-session-check.sh"
mkdir -p "$tmp/sess-bin"
for t in systemctl loginctl; do
    printf '#!/bin/sh\necho "%s $*" >> "$SESS_LOG"\nexit 0\n' "$t" >"$tmp/sess-bin/$t"; chmod +x "$tmp/sess-bin/$t"
done
runtrap() { # <flag setup commands>: runs them, then `exit 1` as an aborted run; prints the stub call log
    SESS_LOG="$tmp/sess.log"; : > "$SESS_LOG"
    SESS_LOG="$SESS_LOG" PATH="$tmp/sess-bin:$PATH" bash -c ". '$trapsrc'; $1" >/dev/null 2>&1
    cat "$SESS_LOG"
}
out="$(runtrap 'stopped_compositor=yes; enabled_linger=yes; exit 1')"
expect_contains "abort in the Freeze part starts the compositor" "$out" "systemctl start ruya-compositor@tty1"
expect_contains "abort in the Freeze part takes back the linger it enabled" "$out" "loginctl disable-linger ruya-shell"
out="$(runtrap 'stopped_compositor=yes; enabled_linger=no; exit 1')"
expect_contains "abort in the shell-restart step starts the compositor" "$out" "systemctl start ruya-compositor@tty1"
expect_lacks "a linger that was there before is left alone" "$out" "disable-linger"
out="$(runtrap 'stopped_compositor=yes; enabled_linger=yes; stopped_compositor=no; enabled_linger=no; exit 0')"
[ -z "$out" ] && pass "a clean run (flags cleared) calls neither systemctl nor loginctl" || fail "a clean run called: $out"
# RUY-404 round 2: with stdout closed (ssh with piped output that went away) the trap's echo raises
# SIGPIPE; the restore must still happen. The child's stdout is a pipe whose reader is already gone.
SESS_LOG="$tmp/sess.log"; : > "$SESS_LOG"
( SESS_LOG="$SESS_LOG" PATH="$tmp/sess-bin:$PATH" bash -c ". '$trapsrc'; stopped_compositor=yes; enabled_linger=yes; sleep 0.3; echo go; exit 1" 2>/dev/null | true ) 2>/dev/null
out="$(cat "$SESS_LOG")"
expect_contains "closed stdout: the compositor is still started" "$out" "systemctl start ruya-compositor@tty1"
expect_contains "closed stdout: the linger is still taken back" "$out" "loginctl disable-linger ruya-shell"

# --- vm-session-check.sh: drop_test_apps (RUY-679) -------------------------------------------------
# The cleanup removes what is installed with its output visible; a failed uninstall is a FAIL line and
# returns 1, so `drop_test_apps ... && flatpak remote-delete` keeps the remote (RUY-679: a number in
# $rt made the uninstall fail silently, and the remote-delete then orphaned the runtime).
dropsrc="$tmp/drop.sh"
{ sed -n '/^# --- drop_test_apps begin/,/^# --- drop_test_apps end/p' "$here/vm-session-check.sh"
  sed -n '/^# --- wait_fstate begin/,/^# --- wait_fstate end/p' "$here/vm-session-check.sh"
  sed -n '/^# --- refused_client_ends begin/,/^# --- refused_client_ends end/p' "$here/vm-session-check.sh"; } > "$dropsrc"
[ -s "$dropsrc" ] && pass "vm-session-check.sh has the drop_test_apps and refused_client_ends blocks" || fail "no drop_test_apps block"
mkdir -p "$tmp/drop-bin"
cat > "$tmp/drop-bin/flatpak" <<'SHIMEOF'
#!/bin/sh
echo "flatpak $*" >> "$DROP_LOG"
case "$1" in
    info) case " $DROP_INSTALLED " in *" $3 "*) exit 0;; *) exit 1;; esac;;
    uninstall) echo "error: uninstall output"; exit "${DROP_RC:-0}";;
    remote-delete) exit 0;;
    list) printf '%s
' "$DROP_LIST" | grep -v '^$'; exit 0;;
esac
exit 0
SHIMEOF
printf '#!/bin/sh\nexec grep -a "froze" "$DROP_JOURNAL" 2>/dev/null\n' > "$tmp/drop-bin/journalctl"
chmod +x "$tmp/drop-bin/flatpak" "$tmp/drop-bin/journalctl"
rundrop() { # <script text> (DROP_* env set by the caller): runs it with the blocks sourced; prints the output and the log
    DROP_LOG="$tmp/drop.log"; : > "$DROP_LOG"
    DROP_LOG="$DROP_LOG" PATH="$tmp/drop-bin:$PATH" bash -c "ok() { echo \"PASS: \$*\"; }; bad() { echo \"FAIL: \$*\"; }; wclient=org.ruyaos.TestWaylandClient; work='$tmp/drop-work'; REFUSED_WAIT=2; . '$dropsrc'; $1" 2>&1
    cat "$DROP_LOG"
}
mkdir -p "$tmp/drop-work"
out="$(DROP_INSTALLED="org.a org.rt" DROP_RC=1 rundrop 'drop_test_apps org.a org.b org.rt && flatpak remote-delete --system --force r; echo "rc=$?"')"
expect_contains "a failed uninstall is a FAIL line" "$out" "FAIL: flatpak uninstall org.a org.rt failed"
expect_contains "a failed uninstall shows flatpak's own output" "$out" "error: uninstall output"
expect_lacks "a failed uninstall does not delete the remote" "$out" "flatpak remote-delete"
expect_lacks "only installed ids are uninstalled" "$out" "uninstall --system -y org.a org.b"
out="$(DROP_INSTALLED="org.a org.rt" DROP_RC=0 rundrop 'drop_test_apps org.a org.b org.rt && flatpak remote-delete --system --force r; echo "rc=$?"')"
expect_contains "a good uninstall removes the installed ids" "$out" "flatpak uninstall --system -y org.a org.rt"
expect_contains "a good uninstall is followed by the remote-delete" "$out" "flatpak remote-delete --system --force r"
expect_lacks "a good uninstall is not a FAIL" "$out" "FAIL"
# The 0.0.84 orphan: a garbage id ("1794744702") is "not installed" for flatpak info, but the runtime from
# the remote is still there: the function must fail and the remote must stay.
out="$(DROP_INSTALLED="" DROP_LIST="org.rt r" rundrop 'remote=r; drop_test_apps 1794744702 && flatpak remote-delete --system --force r; echo "rc=$?"')"
expect_contains "a garbage id with the runtime still installed is a FAIL line" "$out" "FAIL: still installed from r: org.rt"
expect_lacks "a garbage id does not let the remote be deleted" "$out" "flatpak remote-delete"
out="$(DROP_INSTALLED="" DROP_LIST="org.other flathub" rundrop 'remote=r; drop_test_apps 1794744702; echo "rc=$?"')"
expect_contains "an app of another remote is not ours" "$out" "rc=0"
out="$(DROP_INSTALLED="" rundrop 'drop_test_apps org.a; echo "rc=$?"')"
expect_contains "nothing installed: nothing to do, success" "$out" "rc=0"
expect_lacks "nothing installed: no uninstall call" "$out" "flatpak uninstall"

# --- vm-session-check.sh display: the refused client (RUY-679) -------------------------------------
# Passes on AppExited, or on the unit frozen with "its profile is not signed in"; fails on neither.
echo '{"member":"AppExited","x":"org.ruyaos.TestWaylandClient"}' > "$tmp/drop-work/signals.log"
out="$(DROP_JOURNAL=/dev/null rundrop 'refused_client_ends ruya-app-1 0 "the client"; echo "rc=$?"')"
expect_contains "refused client: AppExited passes" "$out" "PASS: the client ended (AppExited)"
: > "$tmp/drop-work/signals.log"
echo "froze ruya-app-1: its profile is not signed in" > "$tmp/drop.journal"
out="$(DROP_JOURNAL="$tmp/drop.journal" rundrop 'refused_client_ends ruya-app-1 0 "the client"; echo "rc=$?"')"
expect_contains "refused client: the frozen unit passes" "$out" "PASS: the client is frozen by ruya-session"
expect_contains "refused client: the frozen unit returns 0" "$out" "rc=0"
out="$(DROP_JOURNAL="$tmp/drop.journal" rundrop 'refused_client_ends ruya-app-2 0 "the client"; echo "rc=$?"')"
expect_contains "refused client: another unit's frozen line does not count" "$out" "FAIL: the client neither ended nor was frozen"

# --- vm-session-check.sh check: the sweep's FreezerState wait (RUY-708) ----------------------------
# The first read caught the unit mid-thaw; the FAIL then printed `running`. wait_fstate waits, and
# prints the value it tested.
out="$(rundrop 'n=0; fstate() { n=$((n + 1)); [ "$n" -ge 2 ] && echo running || echo thawing; }; wait_fstate u unit running 5; echo "rc=$?"')"
expect_contains "wait_fstate: thawing, then running passes" "$out" "PASS: unit is running"
expect_contains "wait_fstate: thawing, then running returns 0" "$out" "rc=0"
out="$(rundrop 'fstate() { echo frozen; }; wait_fstate u unit running 1; echo "rc=$?"')"
expect_contains "wait_fstate: a stuck frozen unit fails, naming the value tested" "$out" "FAIL: unit: FreezerState frozen, not running"
expect_contains "wait_fstate: a stuck frozen unit returns 1" "$out" "rc=1"
# restart/check/kill clean up the display check's app too: it needs the runtime they remove. RUY-736:
# and the stubborn app of `kill` (installed from the same remote).
for c in 'vm-session-check.sh'; do
    [ "$(grep -c 'drop_test_apps "$wclient" "$sleeper" "$crasher" "$stubborn" "$rt"' "$here/$c")" -ge 5 ]         && pass "$c: every full cleanup also removes the display check's app and the stubborn app (RUY-708, RUY-736)" || fail "$c: a cleanup leaves $wclient or $stubborn, which keeps the runtime installed"
done
[ "$(grep -c 'drop_test_apps "$wclient" "$sleeper" "$crasher" "$rt"' "$here/vm-session-check.sh")" -eq 0 ] \
    && pass "vm-session-check.sh: no cleanup without the stubborn app (RUY-736)" || fail "vm-session-check.sh: a cleanup leaves the stubborn app installed"

# --- vm-session-check.sh kill: the timing windows (RUY-736) ---------------------------------------
# Kill must end the app within 2 s, the backstop 29-33 s after the Stop; judge_secs is the verdict.
judgesrc="$tmp/judge.sh"
sed -n '/^# --- judge_secs begin/,/^# --- judge_secs end/p' "$here/vm-session-check.sh" > "$judgesrc"
[ -s "$judgesrc" ] && pass "vm-session-check.sh has the judge_secs block" || fail "no judge_secs block in vm-session-check.sh"
runjudge() { bash -c "ok() { echo \"PASS: \$*\"; }; bad() { echo \"FAIL: \$*\"; }; . '$judgesrc'; $1; echo \"rc=\$?\"" 2>&1; }
out="$(runjudge 'judge_secs "the kill" 1 0 2')"
expect_contains "judge_secs: inside the window passes" "$out" "PASS: the kill after 1 s (window 0-2 s)"
expect_contains "judge_secs: inside the window returns 0" "$out" "rc=0"
out="$(runjudge 'judge_secs "the kill" 3 0 2')"
expect_contains "judge_secs: a slow kill fails" "$out" "FAIL: the kill after 3 s, outside the window 0-2 s"
expect_contains "judge_secs: a slow kill returns 1" "$out" "rc=1"
out="$(runjudge 'judge_secs "the backstop" 5 29 33')"
expect_contains "judge_secs: the old 5 s grace fails the backstop" "$out" "FAIL: the backstop after 5 s, outside the window 29-33 s"
out="$(runjudge 'judge_secs "the backstop" 31 29 33')"
expect_contains "judge_secs: 31 s passes the backstop" "$out" "PASS: the backstop after 31 s"
out="$(runjudge 'judge_secs "the kill" "" 0 2')"
expect_contains "judge_secs: no AppExited at all fails" "$out" "FAIL: the kill: no time measured"
expect_contains "judge_secs: no AppExited at all returns 1" "$out" "rc=1"
# The kill mode is wired: a Kill call, the stubborn app in the repository, both windows judged.
grep -q 'kill_app() { as_shell busctl --system call "$svc" "$path" "$ifc" Kill s "$1"; }' "$here/vm-session-check.sh" \
    && pass "vm-session-check.sh calls Session1.Kill (RUY-736)" || fail "vm-session-check.sh: no Kill call"
grep -q '"$stubborn|trap '"''"' TERM;' "$here/vm-session-check.sh" \
    && pass "vm-session-check.sh builds an app that ignores SIGTERM (RUY-736)" || fail "vm-session-check.sh: no SIGTERM-ignoring test app"
grep -q 'judge_secs "AppExited after the Kill" "$secs" 0 2' "$here/vm-session-check.sh" \
    && grep -q 'judge_secs "AppExited after the Stop (the backstop)" "$secs" 29 33' "$here/vm-session-check.sh" \
    && pass "vm-session-check.sh kill judges the Kill (0-2 s) and the backstop (29-33 s)" || fail "vm-session-check.sh kill: a window is not judged"
# vm-store-check.sh holds the install in a flatpak shim; no timing-dependent SIGSTOP.
grep -q 'zz-hold-install.conf' "$here/vm-store-check.sh" && ! grep -q 'pkill -STOP' "$here/vm-store-check.sh"     && pass "vm-store-check.sh holds the install with a shim, not a race against SIGSTOP (RUY-708)" || fail "vm-store-check.sh: the install is not held deterministically"
# ProtectSystem=strict: the drop-in must grant the shim's marker directory; an EXIT trap undoes the hold.
grep -q 'ReadWritePaths=%s.*"\$shim" "\$shim"' "$here/vm-store-check.sh" \
    && pass "vm-store-check.sh: the drop-in grants write access to the marker's directory (RUY-708)" || fail "vm-store-check.sh: the shim cannot write its marker under ProtectSystem=strict"
grep -q 'trap unhold EXIT' "$here/vm-store-check.sh" \
    && pass "vm-store-check.sh: an EXIT trap removes the hold (RUY-708)" || fail "vm-store-check.sh: a FAIL leaves the blocking PATH"

# --- vm-profiles-check.sh guests (RUY-125): each assertion can fail ---------------------------------
# A fake Profiles1 (busctl --json=short) and getent over one JSON state file; FAKE_BUG breaks one rule.
# The paths go in as arguments (a Windows python reads converted arguments, not MSYS paths in env).
echo "vm-profiles-check.sh guests: each assertion can fail"
cat > "$tmp/fake-profiles.py" <<'PYEOF'
import json, os, sys
state_path, homes, tool = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
bug = os.environ.get("FAKE_BUG", "")
try:
    with open(state_path) as f:
        st = json.load(f)
except FileNotFoundError:
    st = {"active": "", "next_id": 2, "next_uid": 50000, "guests": [], "users": {}}

def save():
    with open(state_path, "w") as f:
        json.dump(st, f)

def reply(sig, *data):
    print(json.dumps({"type": sig, "data": list(data)}))

def remove(gid):
    st["guests"] = [g for g in st["guests"] if g["id"] != gid]
    if bug != "keep_user":
        st["users"].pop(gid, None)
        try:
            os.rmdir(os.path.join(homes, "ruya-" + gid))
        except OSError:
            pass
    if bug == "reuse":
        st["next_uid"] = 50000

def wipe():
    for g in list(st["guests"]):
        remove(g["id"])

if tool == "getent":
    db, key = args[0], args[1]
    name = key[5:] if key.startswith("ruya-") else ""
    if db == "passwd" and name in st["users"]:
        uid = st["users"][name]
        gid = uid + 1 if bug == "gid" else uid
        print("ruya-%s:x:%d:%d:RuyaOS profile (guest):/var/home/ruya-%s:/usr/sbin/nologin" % (name, uid, gid, name))
        sys.exit(0)
    sys.exit(2)

a = [x for x in args if not x.startswith("--")]
if a[0] == "get-property":
    print(json.dumps({"type": "s", "data": st["active"]}))
    sys.exit(0)
method, rest = a[4], a[6:]
if method == "Lock":
    if bug != "no_wipe":
        wipe()
    st["active"] = ""
elif method == "SwitchTo":
    if rest == ["p1", "1234"]:
        if st["active"] != "p1":
            wipe()
        st["active"] = "p1"
        reply("suu", "ok", 0, 0)
    else:
        reply("suu", "wrong-pin", 4, 0)
elif method == "VerifyPin":
    if bug == "verify_switches":
        st["active"] = "p2"  # a VerifyPin that signs another profile in
    reply("suu", "ok" if rest == ["p1", "1234"] else "wrong-pin", 0, 0)
elif method == "CreateGuest":
    if not st["active"] or (len(st["guests"]) >= 3 and bug != "cap"):
        reply("ssu", "not-allowed", "", 0)
    else:
        number = 1
        while any(g["number"] == number for g in st["guests"]):
            number += 1
        st["next_id"] += 1
        gid = "p%d" % st["next_id"]
        uid = 1000 + st["next_id"] if bug == "range" else st["next_uid"]
        st["next_uid"] += 1
        st["users"][gid] = uid
        os.makedirs(os.path.join(homes, "ruya-" + gid), exist_ok=True)
        st["guests"].append({"id": gid, "number": number})
        if bug == "subuid":  # a guest that got a subordinate id range
            etc = os.path.join(os.path.dirname(homes), "etc")
            os.makedirs(etc, exist_ok=True)
            with open(os.path.join(etc, "subuid"), "a") as f:
                f.write("ruya-%s:100000:65536\n" % gid)
        reply("ssu", "ok", gid, number)
elif method == "RemoveGuest":
    if any(g["id"] == rest[0] for g in st["guests"]):
        remove(rest[0])
        reply("s", "ok")
    else:
        reply("s", "unknown-profile")
elif method == "ListProfiles":
    rows = [["p1", "Check Admin", "#3a5bd9", "admin", True]]
    if bug == "listed":
        rows += [[g["id"], "Guest", "#d9483a", "guest", False] for g in st["guests"]]
    reply("a(ssssb)", rows)
elif method == "ListGuests":
    reply("a(ssu)", [[g["id"], "#d9483a", g["number"]] for g in st["guests"]])
save()
PYEOF
mkdir -p "$tmp/prof-bin"
for t in busctl getent; do
    printf '#!/bin/sh\nexec python3 "$PROF_PY" "$PROF_STATE" "$PROF_HOMES" %s "$@"\n' "$t" > "$tmp/prof-bin/$t"
    chmod +x "$tmp/prof-bin/$t"
done
runprof() { # FAKE_BUG comes from the caller's prefix
    rm -rf "$tmp/prof"; mkdir -p "$tmp/prof/home"
    PROF_PY="$tmp/fake-profiles.py" PROF_STATE="$tmp/prof/state.json" PROF_HOMES="$tmp/prof/home" \
        RUYA_HOME_ROOT="$tmp/prof/home" RUYA_ETC_ROOT="$tmp/prof/etc" PATH="$tmp/prof-bin:$PATH" bash "$here/vm-profiles-check.sh" guests 2>&1
}
out="$(runprof)"; rc=$?
expect_contains "a good service passes" "$out" "ALL CHECKS PASSED"
expect_lacks "a good service: no FAIL" "$out" "FAIL"
[ "$rc" = 0 ] && pass "a good service: exit 0" || fail "a good service: exit $rc"
for case in \
    "cap|FAIL: a fourth CreateGuest" \
    "range|is no guest user in 50000-59999" \
    "listed|FAIL: ListProfiles lists the guest(s)" \
    "keep_user|FAIL: RemoveGuest left the user" \
    "no_wipe|FAIL: Lock left the guests" \
    "verify_switches|FAIL: VerifyPin changed ActiveProfile" \
    "gid|is not its uid"     "subuid|has a line in"     "reuse|is not greater than"; do
    bug="${case%%|*}"; needle="${case#*|}"
    out="$(FAKE_BUG="$bug" runprof)"; rc=$?
    expect_contains "guests, bug $bug: caught" "$out" "$needle"
    [ "$rc" = 1 ] && pass "guests, bug $bug: exit 1" || fail "guests, bug $bug: exit $rc"
done
# --- vm-input-check.sh players (RUY-121): the second profile is made and removed, the probe gets it ---------
echo "vm-input-check.sh players: the probe, the second profile and its removal"
pl="$tmp/players"; mkdir -p "$pl/bin" "$pl/alone" "$pl/with" "$pl/tmp"
# busctl as Profiles1 and Input1: ListProfiles has p1; CreateProfile answers $FAKE_CREATE; every call is logged.
cat > "$pl/bin/busctl" <<'SHIMEOF'
#!/bin/sh
echo "busctl $*" >> "$FAKE_LOG"
case "$*" in
*ListProfiles*) echo 'aa{sv} 1 2 "id" s "p1" "name" s "Check Admin"' ;;
*CreateProfile*) if [ -n "${FAKE_CREATE:-}" ]; then echo "$FAKE_CREATE"; else echo 'ssuu "ok" "p7" 0 0'; fi ;;
*DeleteProfile*) echo 'suu "ok" 0 0' ;;
*) echo '' ;;
esac
exit 0
SHIMEOF
cat > "$pl/bin/systemctl" <<'SHIMEOF'
#!/bin/sh
exit 0
SHIMEOF
# stat: the owners file (RUY-124) is 0600 ruya-input unless FAKE_STAT says otherwise.
cat > "$pl/bin/stat" <<'SHIMEOF'
#!/bin/sh
echo "${FAKE_STAT:-600 ruya-input}"
SHIMEOF
# pgrep: the shell is not running (stopped_shell_probe stops it).
cat > "$pl/bin/pgrep" <<'SHIMEOF'
#!/bin/sh
exit 1
SHIMEOF
chmod +x "$pl/bin"/*
cp "$here/vm-input-check.sh" "$pl/alone/"
cp "$here/vm-input-check.sh" "$pl/with/"
# A stand-in probe: logs its arguments, passes, or fails with FAKE_PROBE_FAIL.
cat > "$pl/with/vm-input-probe.py" <<'SHIMEOF'
import os, sys
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("probe " + " ".join(sys.argv[1:]) + "\n")
print("FAIL: stand-in probe" if os.environ.get("FAKE_PROBE_FAIL") else "PASS: stand-in probe")
SHIMEOF
runplayers() { # <dir>
    : > "$tmp/players.log"
    FAKE_LOG="$tmp/players.log" CHECK_TMP="$pl/tmp" PATH="$pl/bin:$PATH" bash "$1/vm-input-check.sh" players 2>&1
}
out="$(runplayers "$pl/alone")"; rc=$?
expect_contains "players without the probe: FAIL" "$out" "vm-input-probe.py is missing: copy it next to this script"
[ "$rc" = 1 ] && pass "players without the probe: exit 1" || fail "players without the probe: exit $rc"
expect_lacks "players without the probe: no profile is made" "$(cat "$tmp/players.log")" "CreateProfile"
out="$(FAKE_CREATE='ssuu "not-allowed" "" 0 0' runplayers "$pl/with")"; rc=$?
expect_contains "a refused CreateProfile: FAIL" "$out" 'FAIL: CreateProfile Check Player: ssuu "not-allowed"'
[ "$rc" = 1 ] && pass "a refused CreateProfile: exit 1" || fail "a refused CreateProfile: exit $rc"
expect_lacks "a refused CreateProfile: the probe does not run" "$(cat "$tmp/players.log")" "probe players"
out="$(runplayers "$pl/with")"; rc=$?
log="$(cat "$tmp/players.log")"
expect_contains "players: the probe gets the second profile" "$log" "probe players --user ruya-p1 --other p7 --profile p1"
expect_contains "players: the profile is made as the admin" "$log" 'CreateProfile sssss p1 1234 Check Player standard'
expect_contains "players: the second profile is removed" "$log" "DeleteProfile sss p1 1234 p7"
expect_contains "players: owners.json is checked 0600 ruya-input" "$out" "PASS: owners.json is 0600 ruya-input"
expect_contains "players: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "players: exit 0" || fail "players: exit $rc"
out="$(FAKE_STAT='644 root' runplayers "$pl/with")"; rc=$?
expect_contains "players: a wrong owners.json mode fails" "$out" "FAIL: owners.json: 644 root (want 600 ruya-input)"
[ "$rc" = 1 ] && pass "players: a wrong owners.json mode: exit 1" || fail "players: a wrong owners.json mode: exit $rc"
out="$(FAKE_PROBE_FAIL=1 runplayers "$pl/with")"; rc=$?
expect_contains "players: a FAIL of the probe fails the check" "$out" "SOME CHECKS FAILED"
[ "$rc" = 1 ] && pass "players: a FAIL of the probe: exit 1" || fail "players: a FAIL of the probe: exit $rc"
expect_contains "players: the profile is removed after a FAIL too" "$(cat "$tmp/players.log")" "DeleteProfile sss p1 1234 p7"
# --- vm-input-check.sh forget (RUY-468, the last step of `profiles`): each assertion can fail -----------------------
echo "vm-input-check.sh forget: the directory goes, ../x is invalid and changes nothing, StoredConsoleProfiles ids only"
fg="$tmp/forget"; mkdir -p "$fg/bin"
# busctl as Profiles1 and Input1 over a state directory: SaveProfile makes <state>/profiles/<id>/, ForgetConsoleProfile
# removes it for a valid id ("invalid" otherwise), StoredConsoleProfiles lists the directories. FAKE_BUG breaks one:
# keep (Forget leaves the directory), follow (an id with "/" or "." is removed too), list_name (a name that is no id is
# listed), list_stale (the forgotten id is still listed).
cat > "$fg/bin/busctl" <<'SHIMEOF'
#!/bin/bash
echo "busctl $*" >> "$FAKE_LOG"
root="$FAKE_STATE/profiles"
case "$6" in
ListProfiles) echo 'aa{sv} 1 2 "id" s "p1" "name" s "Check Admin"' ;;
CreateProfile) echo 'ssuu "ok" "p7" 0 0' ;;
DeleteProfile) echo 'suu "ok" 0 0' ;;
SaveProfile) mkdir -p "$root/$8" && echo "$9" > "$root/$8/vm-check-forget.json" && echo 'sas "ok" "vm-check-forget" 0' ;;
StoredConsoleProfiles)
    ids="$(ls "$root" 2>/dev/null)"
    [ "${FAKE_BUG:-}" = list_name ] && ids="$(printf '%s\nbad name' "$ids")"
    [ "${FAKE_BUG:-}" = list_stale ] && ids="$(printf '%s\np7' "$ids")"
    ids="$(printf '%s\n' "$ids" | grep . | sort -u)"
    printf 'sas "ok" %s' "$(printf '%s\n' "$ids" | grep -c .)"
    printf '%s\n' "$ids" | grep . | while read -r id; do printf ' "%s"' "$id"; done
    echo ;;
ForgetConsoleProfile)
    case "$8" in
    ""|*[!A-Za-z0-9_-]*)
        if [ "${FAKE_BUG:-}" = follow ]; then rm -rf "${root:?}/$8"; echo 's "ok"'; else echo 's "invalid"'; fi ;;
    *) [ "${FAKE_BUG:-}" = keep ] || rm -rf "${root:?}/$8"; echo 's "ok"' ;;
    esac ;;
*) echo '' ;;
esac
exit 0
SHIMEOF
chmod +x "$fg/bin/busctl"
runforget() {
    rm -rf "$fg/state"; mkdir -p "$fg/state/profiles/p1"
    : > "$tmp/forget.log"
    FAKE_LOG="$tmp/forget.log" FAKE_STATE="$fg/state" INPUT_STATE_DIR="$fg/state" PATH="$fg/bin:$PATH" \
        bash "$here/vm-input-check.sh" forget 2>&1
}
out="$(runforget)"; rc=$?
expect_contains "forget: says what it checks" "$out" "--- a console profile's controller profiles go with it (RUY-468)"
expect_contains "forget: the saved profile's directory is there first" "$out" "PASS: StoredConsoleProfiles lists p7"
expect_contains "forget: the directory is gone" "$out" "/profiles/p7 is gone"
expect_contains "forget: ../x is invalid" "$out" "PASS: ForgetConsoleProfile ../x: invalid"
expect_contains "forget: the profile is made as the admin" "$(cat "$tmp/forget.log")" 'CreateProfile sssss p1 1234 Check Forget standard'
expect_contains "forget: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "forget: exit 0" || fail "forget: exit $rc"
[ -e "$fg/state/x" ] && fail "forget: the sentinel is left behind" || pass "forget: the sentinel is removed"
[ -d "$fg/state/profiles/p1" ] && pass "forget: another profile's directory stays" || fail "forget: p1's directory went"
for case in "keep|/profiles/p7 is still there" \
    "follow|FAIL: ForgetConsoleProfile ../x: s \"ok\"" \
    "list_name|FAIL: StoredConsoleProfiles lists a name that is no profile id" \
    "list_stale|FAIL: StoredConsoleProfiles still lists p7"; do
    bug="${case%%|*}"; needle="${case#*|}"
    out="$(FAKE_BUG="$bug" runforget)"; rc=$?
    expect_contains "forget, bug $bug: caught" "$out" "$needle"
    [ "$rc" = 1 ] && pass "forget, bug $bug: exit 1" || fail "forget, bug $bug: exit $rc"
done
out="$(FAKE_BUG=follow runforget)"
expect_contains "forget, bug follow: the change in the state directory is named" "$out" "FAIL: ForgetConsoleProfile ../x changed"
# --- vm-input-check.sh seathold (RUY-627): the drop-in, the restarts, the profile, the probe ------------------
echo "vm-input-check.sh seathold: RUYA_SEAT_HOLD_SECS=5 as a drop-in, removed again, the probe gets the profiles"
sh_dir="$tmp/seathold"; mkdir -p "$sh_dir/bin" "$sh_dir/dropin"
cp "$pl/bin/busctl" "$pl/bin/pgrep" "$sh_dir/bin/"
# systemctl logs its arguments and what the drop-in says at each call.
cat > "$sh_dir/bin/systemctl" <<'SHIMEOF'
#!/bin/sh
echo "systemctl $* [$(cat "$FAKE_DROPIN/50-ruya-check-seat-hold.conf" 2>/dev/null | tr '\n' ' ')]" >> "$FAKE_LOG"
exit 0
SHIMEOF
# journalctl: the service's line about the shortened hold, unless FAKE_NO_HOLD_LINE.
cat > "$sh_dir/bin/journalctl" <<'SHIMEOF'
#!/bin/sh
[ -n "${FAKE_NO_HOLD_LINE:-}" ] || echo "ruya-inputd: RUYA_SEAT_HOLD_SECS: a seat is held 5 s, not 60 (a test setting)"
exit 0
SHIMEOF
chmod +x "$sh_dir/bin"/*
runseathold() { # <dir> [mode: seathold | coop]
    : > "$tmp/seathold.log"
    FAKE_LOG="$tmp/seathold.log" FAKE_DROPIN="$sh_dir/dropin" SEATHOLD_DROPIN_DIR="$sh_dir/dropin" CHECK_TMP="$pl/tmp" \
        PATH="$sh_dir/bin:$PATH" bash "$1/vm-input-check.sh" "${2:-seathold}" 2>&1
}
out="$(runseathold "$pl/alone")"; rc=$?
expect_contains "seathold without the probe: FAIL" "$out" "vm-input-probe.py is missing: copy it next to this script"
[ "$rc" = 1 ] && pass "seathold without the probe: exit 1" || fail "seathold without the probe: exit $rc"
expect_lacks "seathold without the probe: no drop-in" "$(cat "$tmp/seathold.log")" "RUYA_SEAT_HOLD_SECS"
out="$(runseathold "$pl/with")"; rc=$?
log="$(cat "$tmp/seathold.log")"
expect_contains "seathold: the restart runs with the drop-in" "$log" "systemctl restart ruya-inputd [[Service] Environment=RUYA_SEAT_HOLD_SECS=5 ]"
expect_contains "seathold: the probe gets the second profile" "$log" "probe seathold --user ruya-p1 --other p7 --profile p1"
expect_contains "seathold: the service is restarted without the drop-in" "$log" "systemctl restart ruya-inputd []"
[ -e "$sh_dir/dropin/50-ruya-check-seat-hold.conf" ] && fail "seathold: the drop-in is left behind" || pass "seathold: the drop-in is removed"
expect_contains "seathold: the second profile is removed" "$log" "DeleteProfile sss p1 1234 p7"
expect_contains "seathold: the journal line passes" "$out" "PASS: ruya-inputd journals the shortened hold"
expect_contains "seathold: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "seathold: exit 0" || fail "seathold: exit $rc"
out="$(FAKE_NO_HOLD_LINE=1 runseathold "$pl/with")"; rc=$?
expect_contains "seathold: no journal line about the hold: FAIL" "$out" "FAIL: no 'RUYA_SEAT_HOLD_SECS: a seat is held 5 s' line"
[ "$rc" = 1 ] && pass "seathold: no journal line: exit 1" || fail "seathold: no journal line: exit $rc"
out="$(FAKE_PROBE_FAIL=1 runseathold "$pl/with")"; rc=$?
expect_contains "seathold: a FAIL of the probe fails the check" "$out" "SOME CHECKS FAILED"
[ "$rc" = 1 ] && pass "seathold: a FAIL of the probe: exit 1" || fail "seathold: a FAIL of the probe: exit $rc"
[ -e "$sh_dir/dropin/50-ruya-check-seat-hold.conf" ] && fail "seathold: the drop-in is left after a FAIL" || pass "seathold: the drop-in is removed after a FAIL too"
expect_contains "seathold: the profile is removed after a FAIL too" "$(cat "$tmp/seathold.log")" "DeleteProfile sss p1 1234 p7"
# --- vm-input-check.sh coop (RUY-681): seathold's set-up (drop-in, profile, stopped shell), its own probe command -----
echo "vm-input-check.sh coop: RUYA_SEAT_HOLD_SECS=5 and the second profile for the probe's coop, removed again"
out="$(runseathold "$pl/with" coop)"; rc=$?
log="$(cat "$tmp/seathold.log")"
expect_contains "coop: says what it checks" "$out" "--- split-screen co-op (RUY-681)"
expect_contains "coop: the restart runs with the drop-in" "$log" "systemctl restart ruya-inputd [[Service] Environment=RUYA_SEAT_HOLD_SECS=5 ]"
expect_contains "coop: the probe runs coop with the second profile" "$log" "probe coop --user ruya-p1 --other p7 --profile p1"
expect_lacks "coop: the probe does not run seathold" "$log" "probe seathold"
expect_contains "coop: the service is restarted without the drop-in" "$log" "systemctl restart ruya-inputd []"
[ -e "$sh_dir/dropin/50-ruya-check-seat-hold.conf" ] && fail "coop: the drop-in is left behind" || pass "coop: the drop-in is removed"
expect_contains "coop: the second profile is removed" "$log" "DeleteProfile sss p1 1234 p7"
expect_contains "coop: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "coop: exit 0" || fail "coop: exit $rc"
out="$(FAKE_PROBE_FAIL=1 runseathold "$pl/with" coop)"; rc=$?
expect_contains "coop: a FAIL of the probe fails the check" "$out" "SOME CHECKS FAILED"
[ "$rc" = 1 ] && pass "coop: a FAIL of the probe: exit 1" || fail "coop: a FAIL of the probe: exit $rc"
[ -e "$sh_dir/dropin/50-ruya-check-seat-hold.conf" ] && fail "coop: the drop-in is left after a FAIL" || pass "coop: the drop-in is removed after a FAIL too"
# --- vm-input-check.sh twopads (RUY-541, RUY-681): on every entry to `app` pad2 is ready only after pad1 ----------
echo "vm-input-check.sh twopads: the journal's pad1/pad2 order (made at once since RUY-681, pad2 ready after pad1)"
tp="$tmp/twopads"; mkdir -p "$tp/bin"
cp "$pl/bin/busctl" "$pl/bin/pgrep" "$pl/bin/systemctl" "$tp/bin/"
cat > "$tp/bin/journalctl" <<'SHIMEOF'
#!/bin/sh
cat "$FAKE_JOURNAL"
SHIMEOF
chmod +x "$tp/bin"/*
runtwopads() { # <journal lines>
    printf '%s\n' "$1" > "$tmp/twopads.journal"
    : > "$tmp/twopads.log"
    FAKE_LOG="$tmp/twopads.log" FAKE_JOURNAL="$tmp/twopads.journal" CHECK_TMP="$pl/tmp" PATH="$tp/bin:$PATH" \
        bash "$pl/with/vm-input-check.sh" twopads 2>&1
}
c1='ruya-inputd: virtual pad ruya-input/pad1 created for ruya-p1 (vm-check-pad0)'
c2='ruya-inputd: virtual pad ruya-input/pad2 created for ruya-p1 (vm-check-pad1)'
r1='ruya-inputd: virtual pad ruya-input/pad1 ready for ruya-p1 (/dev/input/event20, udev add)'
r2='ruya-inputd: virtual pad ruya-input/pad2 ready for ruya-p1 (/dev/input/event21, udev add)'
out="$(runtwopads "$c1
$c2
$r1
$r2
$c1
$c2
$r1
$r2")"; rc=$?
expect_contains "twopads: both made at once, pad2 ready after pad1: PASS" "$out" "PASS: journal: pad2 was ready after pad1 was ready, 2 times"
expect_contains "twopads: the probe runs twopads" "$(cat "$tmp/twopads.log")" "probe twopads --user ruya-p1"
[ "$rc" = 0 ] && pass "twopads: exit 0" || fail "twopads: exit $rc"
out="$(runtwopads "$c1
$c2
$r1
$r2
$c1
$c2
$r2
$r1")"; rc=$?
expect_contains "twopads: pad2 ready before pad1 on the second entry: FAIL" "$out" "FAIL: journal: pad2 was ready before pad1 was ready (entries, early: 2 1)"
[ "$rc" = 1 ] && pass "twopads: pad2 ready first: exit 1" || fail "twopads: pad2 ready first: exit $rc"
out="$(runtwopads "$c1
$c2
$r1")"; rc=$?
expect_contains "twopads: pad2 never ready: FAIL" "$out" "FAIL: journal: pad2 was never ready during twopads"
[ "$rc" = 1 ] && pass "twopads: pad2 never ready: exit 1" || fail "twopads: pad2 never ready: exit $rc"
# --- vm-input-check.sh startpad (RUY-837): the prepared pad is ready before the game's route binds it ------------
echo "vm-input-check.sh startpad: the probe runs, and the journal has the pad ready before it is bound"
runstartpad() { # <journal lines>
    printf '%s\n' "$1" > "$tmp/startpad.journal"
    : > "$tmp/startpad.log"
    FAKE_LOG="$tmp/startpad.log" FAKE_JOURNAL="$tmp/startpad.journal" CHECK_TMP="$pl/tmp" PATH="$tp/bin:$PATH" \
        bash "$pl/with/vm-input-check.sh" startpad 2>&1
}
sp1='ruya-inputd: pads prepared for org.ruyaos.VmCheck (ruya-p1)'
sp2="ruya-inputd: prepared pads for org.ruyaos.VmCheck bound to instance 'vm-check-startpad'"
out="$(runstartpad "$sp1
$c1
$r1
$sp2")"; rc=$?
expect_contains "startpad: ready before bound: PASS" "$out" "PASS: journal: pads prepared, pad1 ready, then bound to the game's instance"
expect_contains "startpad: the probe runs startpad" "$(cat "$tmp/startpad.log")" "probe startpad --user ruya-p1 --profile p1"
[ "$rc" = 0 ] && pass "startpad: exit 0" || fail "startpad: exit $rc"
out="$(runstartpad "$sp1
$c1
$sp2
$r1")"; rc=$?
expect_contains "startpad: ready only after bound: FAIL" "$out" "FAIL: journal: prepared, ready before bound, bound: 1 0 1"
[ "$rc" = 1 ] && pass "startpad: ready after bound: exit 1" || fail "startpad: ready after bound: exit $rc"
out="$(FAKE_PROBE_FAIL=1 runstartpad "$sp1
$c1
$r1
$sp2")"; rc=$?
[ "$rc" = 1 ] && pass "startpad: a FAIL of the probe: exit 1" || fail "startpad: a FAIL of the probe: exit $rc"
out="$(FAKE_LOG="$tmp/startpad.log" CHECK_TMP="$pl/tmp" PATH="$tp/bin:$PATH" bash "$pl/alone/vm-input-check.sh" startpad 2>&1)"; rc=$?
expect_contains "startpad without the probe: FAIL" "$out" "vm-input-probe.py is missing: copy it next to this script"
# --- vm-input-check.sh join (RUY-628): VerifyPin wrong then right, ActiveProfile stays, JoinPlayer, ListPlayers -------
echo "vm-input-check.sh join: the PIN is checked without a sign-in, then the pad joins and ListPlayers has the seat"
jn="$tmp/join"; mkdir -p "$jn/bin" "$jn/state"
# busctl as Profiles1 and Input1 with the test pad; FAKE_BUG breaks one answer: wrong-ok (a wrong PIN answers ok),
# signs-in (VerifyPin changes ActiveProfile), join-refused, no-seat (ListPlayers lacks the joiner's seat).
cat > "$jn/bin/busctl" <<'SHIMEOF'
#!/bin/sh
echo "busctl $*" >> "$FAKE_LOG"
pad='usb-1234-5678-0a0b0c0d0e0f'
case "$*" in
*ListProfiles*) echo 'aa{sv} 1 2 "id" s "p1" "name" s "Check Admin"' ;;
*ActiveProfile*)
    if [ "${FAKE_BUG:-}" = signs-in ] && [ -e "$FAKE_STATE/verified" ]; then echo 's "p7"'; else echo 's "p1"'; fi ;;
*Route*) echo 's "shell"' ;;
*CreateProfile*) echo 'ssuu "ok" "p7" 0 0' ;;
*DeleteProfile*) echo 'suu "ok" 0 0' ;;
*ListDevices*) echo '{"type":"aa{sv}","data":[[{"id":{"type":"s","data":"'"$pad"'"},"name":{"type":"s","data":"Ruya VM Check Pad"}}]]}' ;;
*"VerifyPin ss p7 0000"*)
    touch "$FAKE_STATE/verified"
    if [ "${FAKE_BUG:-}" = wrong-ok ]; then echo 'suu "ok" 0 0'; else echo 'suu "wrong-pin" 4 0'; fi ;;
*"VerifyPin ss p7 1234"*) touch "$FAKE_STATE/verified"; echo 'suu "ok" 0 0' ;;
*JoinPlayer*) if [ "${FAKE_BUG:-}" = join-refused ]; then echo 'su "full" 0'; else echo 'su "ok" 2'; fi ;;
*ListPlayers*)
    if [ "${FAKE_BUG:-}" = no-seat ]; then
        echo '{"type":"aa{sv}","data":[[{"slot":{"type":"u","data":1},"profile":{"type":"s","data":"p1"},"device_id":{"type":"s","data":""}}]]}'
    else
        echo '{"type":"aa{sv}","data":[[{"slot":{"type":"u","data":1},"profile":{"type":"s","data":"p1"},"device_id":{"type":"s","data":""}},{"slot":{"type":"u","data":2},"profile":{"type":"s","data":"p7"},"device_id":{"type":"s","data":"'"$pad"'"}}]]}'
    fi ;;
*LeavePlayer*) echo 's "ok"' ;;
*) echo '' ;;
esac
exit 0
SHIMEOF
# pgrep: the shell runs. sleep: a short one (the stand-in pad starts in the background).
printf '#!/bin/sh\nexit 0\n' > "$jn/bin/pgrep"
printf '#!/bin/sh\nexec %s 0.05\n' "$(command -v sleep)" > "$jn/bin/sleep"
chmod +x "$jn/bin"/*
mkdir -p "$jn/with"
cp "$here/vm-input-check.sh" "$jn/with/"
# A stand-in probe: `pad` says the pad is ready.
cat > "$jn/with/vm-input-probe.py" <<'SHIMEOF'
import sys
print("pad ready /dev/input/event9" if sys.argv[1:2] == ["pad"] else "PASS: stand-in probe", flush=True)
SHIMEOF
runjoin() { # <dir>
    : > "$tmp/join.log"
    rm -f "$jn/state/verified"
    FAKE_LOG="$tmp/join.log" FAKE_STATE="$jn/state" CHECK_TMP="$jn/state" PATH="$jn/bin:$PATH" bash "$1/vm-input-check.sh" join 2>&1
}
out="$(runjoin "$pl/alone")"; rc=$?
expect_contains "join without the probe: FAIL" "$out" "vm-input-probe.py is missing: copy it next to this script"
[ "$rc" = 1 ] && pass "join without the probe: exit 1" || fail "join without the probe: exit $rc"
out="$(runjoin "$jn/with")"; rc=$?
log="$(cat "$tmp/join.log")"
expect_contains "join: the joiner is made with a PIN" "$log" "CreateProfile sssss p1 1234 Check Joiner standard 1234"
expect_contains "join: the pad joins as the joiner" "$log" "JoinPlayer ss usb-1234-5678-0a0b0c0d0e0f p7"
expect_contains "join: the seat is given back" "$log" "LeavePlayer u 2"
expect_contains "join: the joiner is removed" "$log" "DeleteProfile sss p1 1234 p7"
expect_contains "join: ListPlayers has the seat" "$out" "PASS: ListPlayers (JSON): seat 2 is p7 on the test pad"
expect_contains "join: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "join: exit 0" || fail "join: exit $rc"
# The order the shell uses: the wrong PIN, the right PIN, then the join.
order="$(grep -oE 'VerifyPin ss p7 [0-9]+|JoinPlayer' "$tmp/join.log" | tr '\n' ',')"
[ "$order" = "VerifyPin ss p7 0000,VerifyPin ss p7 1234,JoinPlayer," ] && pass "join: VerifyPin wrong, right, then JoinPlayer" \
    || fail "join: the calls ran as $order"
for case in "wrong-ok|FAIL: VerifyPin p7 0000" "signs-in|FAIL: after a wrong VerifyPin ActiveProfile reads 'p7'" \
            "join-refused|FAIL: JoinPlayer usb-1234-5678-0a0b0c0d0e0f p7: su \"full\" 0" "no-seat|FAIL: ListPlayers has no seat 2 for p7"; do
    bug="${case%%|*}"; needle="${case#*|}"
    out="$(FAKE_BUG="$bug" runjoin "$jn/with")"; rc=$?
    expect_contains "join, bug $bug: caught" "$out" "$needle"
    [ "$rc" = 1 ] && pass "join, bug $bug: exit 1" || fail "join, bug $bug: exit $rc"
    expect_contains "join, bug $bug: the joiner is removed after a FAIL too" "$(cat "$tmp/join.log")" "DeleteProfile sss p1 1234 p7"
done

# --- vm-devices-check.sh bluetooth, two adapters (RUY-648): both adapters on, the two properties read "" ---------
echo "vm-devices-check.sh: bluetooth_two_adapters_check, PrimaryAdapterOff and AdapterInUse"
cat > "$tmp/bt2.canned" <<'BTEOF'
START {"type":"u","data":["ok"]}
STOP {"type":"s","data":["ok"]}
LIST {"type":"aa{sv}","data":[[{"id":{"type":"s","data":"AA:00:00:00:00:01"},"adapter":{"type":"s","data":"hci0"}},{"id":{"type":"s","data":"AA:00:00:00:00:11"},"adapter":{"type":"s","data":"hci1"}}]]}
CONNECT {"type":"s","data":["ok"]}
FORGET {"type":"s","data":["ok"]}
LIST2 {"type":"aa{sv}","data":[[{"id":{"type":"s","data":"AA:00:00:00:00:01"},"adapter":{"type":"s","data":"hci0"}}]]}
OFF {"type":"s","data":"@OFF@"}
INUSE {"type":"s","data":"@INUSE@"}
BTEOF
btrun() { # <PrimaryAdapterOff> <AdapterInUse>: the check on a canned run of the two-adapter fake
    (
        export VM_CHECK_LIB_ONLY=1
        # shellcheck disable=SC1090
        . "$here/vm-devices-check.sh"
        as_shell() {
            case "$*" in *"status org.ruyaos.Devices1") return 1;; esac   # the name is free; the long call mentions it mid-text
            sed -e "s/@OFF@/$BT_OFF/" -e "s/@INUSE@/$BT_INUSE/" "$tmp/bt2.canned"
        }
        BT_OFF="$1" BT_INUSE="$2" bluetooth_two_adapters_check
    ) 2>&1
}
out="$(btrun "" "")"
expect_contains "both adapters on, both properties empty: PASS" "$out" "PrimaryAdapterOff and AdapterInUse are empty with both adapters on"
out="$(btrun "usb" "")"
expect_contains "PrimaryAdapterOff set with both adapters on: FAIL" "$out" "should be empty with both adapters on, not 'usb' / ''"
out="$(btrun "" "hci0")"
expect_contains "AdapterInUse set with both adapters on: FAIL" "$out" "not '' / 'hci0'"

# --- vm-devices-check.sh smart_check (RUY-737): the virtio disk is "unsupported" and has no numbers --------------
echo "vm-devices-check.sh: smart_check, the virtio disk and a failing drive"
smd="$tmp/smart/bin"; mkdir -p "$smd"
cat > "$smd/busctl" <<'SHIMEOF'
#!/bin/sh
echo "a{sv} 1 \"storage.drives\" aa{sv} 1 2 \"model\" s \"QEMU\" \"size_bytes\" t 100 ${FAKE_SMART_KEYS-\"smart\" s \"unsupported\"}"
SHIMEOF
cat > "$smd/lsblk" <<'SHIMEOF'
#!/bin/sh
echo "${FAKE_DISK-vda} disk"
SHIMEOF
chmod +x "$smd"/*
smartrun() {
    (
        export VM_CHECK_LIB_ONLY=1
        # shellcheck disable=SC1090
        . "$here/vm-devices-check.sh"
        PATH="$smd:$PATH" smart_check
    ) 2>&1
}
out="$(smartrun)"
expect_contains "virtio disk unsupported: PASS" "$out" "PASS: the virtio disk's record says smart unsupported"
expect_contains "virtio disk without numbers: PASS" "$out" "PASS: no hours, wear or temperature for the virtio disk"
out="$(FAKE_SMART_KEYS='"smart" s "ok"' smartrun)"
expect_contains "virtio disk reading ok: FAIL" "$out" "FAIL: the virtio disk's record has no"
out="$(FAKE_SMART_KEYS='"smart" s "unsupported" "power_on_hours" t 5' smartrun)"
expect_contains "virtio disk with hours: FAIL" "$out" "FAIL: a virtio disk carries power_on_hours"
out="$(FAKE_DISK=sda FAKE_SMART_KEYS='"smart" s "failing"' smartrun)"
expect_contains "a failing drive: FAIL" "$out" "FAIL: a drive reports smart failing"
expect_contains "a real disk: info only" "$out" "info: no virtio disk here"

# --- vm-boot-check.sh watchdog (RUY-483): the unit's settings, no early trip, the SIGSTOP restart ------------------
echo "vm-boot-check.sh watchdog: WatchdogSec=30s, no trip since boot, a stopped shell is restarted by the watchdog"
wdd="$tmp/watchdog"; mkdir -p "$wdd/bin" "$wdd/state"
# systemctl: the unit's properties; MainPID and NRestarts from the state (1001 and FAKE_N0 until the kill).
cat > "$wdd/bin/systemctl" <<'SHIMEOF'
#!/bin/sh
case "$1" in
is-active) exit 0 ;;
show)
    case "$3" in
    WatchdogUSec) echo "${FAKE_WDUSEC-30s}" ;;
    NotifyAccess) echo "${FAKE_NOTIFY-main}" ;;
    TimeoutAbortUSec) echo "${FAKE_ABORT-10s}" ;;
    MainPID) cat "$FAKE_WD/pid" ;;
    NRestarts) cat "$FAKE_WD/restarts" ;;
    esac ;;
esac
exit 0
SHIMEOF
# The kill: logs its arguments; a -STOP is "restarted by the watchdog" (new MainPID, NRestarts + 1, the
# trip line), unless FAKE_NO_RESTART; FAKE_OTHER_RESTART restarts without a trip line.
cat > "$wdd/bin/fakekill" <<'SHIMEOF'
#!/bin/sh
echo "kill $*" >> "$FAKE_WD/log"
if [ "$1" = -STOP ] && [ -z "${FAKE_NO_RESTART:-}" ]; then
    echo 2002 > "$FAKE_WD/pid"
    echo $(( $(cat "$FAKE_WD/restarts") + 1 + ${FAKE_EXTRA_RESTART:-0} )) > "$FAKE_WD/restarts"
    [ -n "${FAKE_OTHER_RESTART:-}" ] || touch "$FAKE_WD/tripped"
fi
exit 0
SHIMEOF
# journalctl: each shell's start line by _PID (FAKE_NO_START1 / FAKE_NO_START2 drop one), systemd's trip
# line by -u once tripped, or before the kill too with FAKE_EARLY_TRIP.
cat > "$wdd/bin/journalctl" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*_PID=1001*) [ -n "${FAKE_NO_START1:-}" ] || echo "ruya-shell: systemd watchdog every 15000 ms" ;;
*_PID=2002*) [ -n "${FAKE_NO_START2:-}" ] || echo "ruya-shell: systemd watchdog every 15000 ms" ;;
*" -u "*)
    if [ -e "$FAKE_WD/tripped" ] || [ -n "${FAKE_EARLY_TRIP:-}" ]; then
        echo "systemd[1]: ruya-compositor@tty1.service: Watchdog timeout (limit 30s)!"
    fi ;;
esac
exit 0
SHIMEOF
chmod +x "$wdd/bin"/*
runwd() { # env assignments come from the caller's prefix
    rm -f "$wdd/state/tripped"; : > "$wdd/state/log"
    echo 1001 > "$wdd/state/pid"; echo "${FAKE_N0:-0}" > "$wdd/state/restarts"
    FAKE_WD="$wdd/state" WATCHDOG_KILL="$wdd/bin/fakekill" PATH="$wdd/bin:$PATH" bash "$here/vm-boot-check.sh" watchdog 2>&1
}
out="$(runwd)"; rc=$?
expect_contains "watchdog: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "watchdog: exit 0" || fail "watchdog: exit $rc"
expect_contains "watchdog: the shell is stopped, not killed" "$(cat "$wdd/state/log")" "kill -STOP 1001"
expect_contains "watchdog: the restart is seen" "$out" "PASS: the stopped shell was restarted after about 1 s (new MainPID 2002)"
expect_contains "watchdog: the new shell's start line" "$out" "PASS: the new shell (pid 2002) logged"
expect_lacks "watchdog: a restarted shell is not continued" "$(cat "$wdd/state/log")" "kill -CONT"
expect_lacks "watchdog: the plain boot checks do not run" "$out" "kernel argument"
out="$(FAKE_WDUSEC=0 runwd)"; rc=$?
expect_contains "watchdog: no WatchdogSec: FAIL" "$out" "FAIL: ruya-compositor@tty1.service: WatchdogUSec is '0', not 30s"
[ "$rc" = 1 ] && pass "watchdog: no WatchdogSec: exit 1" || fail "watchdog: no WatchdogSec: exit $rc"
out="$(FAKE_NOTIFY=none runwd)"
expect_contains "watchdog: NotifyAccess=none: FAIL" "$out" "FAIL: ruya-compositor@tty1.service: NotifyAccess is 'none', not main"
out="$(FAKE_ABORT="1min 30s" runwd)"
expect_contains "watchdog: the default abort timeout: FAIL" "$out" "FAIL: ruya-compositor@tty1.service: TimeoutAbortUSec is '1min 30s', not 10s"
out="$(FAKE_N0=1 runwd)"
expect_contains "watchdog: a restart before the test: FAIL" "$out" "FAIL: NRestarts is 1 before the test"
out="$(FAKE_EARLY_TRIP=1 runwd)"
expect_contains "watchdog: a trip before the test: FAIL" "$out" "FAIL: the watchdog already tripped in this boot"
out="$(FAKE_NO_START1=1 runwd)"
expect_contains "watchdog: no start line from the boot's shell: FAIL" "$out" "FAIL: no 'ruya-shell: systemd watchdog every 15000 ms' from the shell (pid 1001)"
out="$(RUYA_WD_RESTART_S=1 FAKE_NO_RESTART=1 runwd)"; rc=$?
expect_contains "watchdog: not restarted: FAIL" "$out" "FAIL: the stopped shell was not restarted within 1 s"
[ "$rc" = 1 ] && pass "watchdog: not restarted: exit 1" || fail "watchdog: not restarted: exit $rc"
expect_contains "watchdog: a shell left stopped is continued at exit" "$(cat "$wdd/state/log")" "kill -CONT 1001"
out="$(FAKE_EXTRA_RESTART=1 runwd)"
expect_contains "watchdog: two restarts for one stop: FAIL" "$out" "FAIL: NRestarts went from 0 to 2, not 1"
out="$(FAKE_OTHER_RESTART=1 runwd)"
expect_contains "watchdog: a restart without the trip line: FAIL" "$out" "FAIL: no 'Watchdog timeout' line from systemd since the stop"
out="$(RUYA_WD_START_S=1 FAKE_NO_START2=1 runwd)"
expect_contains "watchdog: no start line from the new shell: FAIL" "$out" "FAIL: the new shell (pid 2002) did not log"

# --- vm-notifications-check.sh (RUY-730): each assertion can fail -------------------------------
# A fake Notifications1 and Profiles1 behind busctl, systemctl, systemd-analyze, journalctl, runuser and id,
# over one JSON state file; the signals and calls a real busctl monitor would see go to a bus log that the
# fake monitor follows with tail. FAKE_BUG breaks one rule.
echo "vm-notifications-check.sh: each assertion can fail"
nt="$tmp/notif"; mkdir -p "$nt/bin"
cat > "$nt/fake.py" <<'PYEOF'
import json, os, sys
state_path, buslog, tool = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
bugs = set(os.environ.get("FAKE_BUG", "").split(","))
caller = os.environ.get("FAKE_CALLER", "root")
try:
    with open(state_path) as f:
        st = json.load(f)
except FileNotFoundError:
    st = {"next": 1, "items": {}, "toast": 4, "sources": {}, "active": "", "journal": []}

def save():
    with open(state_path, "w") as f:
        json.dump(st, f)

def out(sig, *data):
    print(json.dumps({"type": sig, "data": list(data)}))

def bus(member, data, sender=":1.9"):
    with open(buslog, "a", newline="\n") as f:
        f.write(json.dumps({"type": "signal", "sender": sender, "member": member, "payload": {"data": data}}) + "\n")

def restart():
    if "no_persist" in bugs:
        st["items"] = {}
    if "id_reuse" in bugs:
        st["next"] = 1
    if "setting_lost" in bugs:
        st["toast"] = 4
    if "shell_silent" not in bugs:
        st["journal"].append("ruya-shell: Notifications1 is not on the bus; notifications are not kept")
    if "no_reread" not in bugs:
        bus("GetAll", ["org.ruyaos.Notifications1"], sender=":1.7")

if tool == "systemctl":
    if args[0] == "is-active":
        print("inactive" if "inactive" in bugs else "active")
    elif args[0] == "restart":
        restart()
    save()
    sys.exit(0)
if tool == "systemd-analyze":
    print("-> Overall exposure level for ruya-notifications.service: %s OK" % ("5.0" if "exposure" in bugs else "1.1"))
    sys.exit(0)
if tool == "journalctl":
    print("\n".join(st["journal"]))
    sys.exit(0)

# busctl
a = [x for x in args if not x.startswith("--")]
verb = a[0]
if verb == "status":
    sys.exit(0)
if verb == "list":
    print(":1.7 1200 ruya-shell ruya-shell :1.7 ruya-compositor@tty1.service - -")
    print(":1.9 1300 ruya-notifica root :1.9 ruya-notifications.service - -")
    sys.exit(0)
svc, rest = a[1], a[4:]
if verb == "get-property":  # busctl --json: "data" is the value itself
    name = rest[0]
    value = {"ActiveProfile": ("s", st["active"]), "ToastSeconds": ("u", st["toast"]),
             "SourcesEnabled": ("a{sb}", st["sources"])}[name]
    print(json.dumps({"type": value[0], "data": value[1]}))
    sys.exit(0)
if verb == "set-property":
    name, vals = rest[0], rest[2:]
    if name == "ToastSeconds":
        st["toast"] = int(vals[0])
    elif name == "SourcesEnabled":
        n = int(vals[0])
        st["sources"] = {vals[1 + 2 * i]: vals[2 + 2 * i] == "true" for i in range(n)}
    save()
    sys.exit(0)
method, vals = rest[0], rest[2:]
if svc == "org.ruyaos.Profiles1":
    if method == "ListProfiles":
        out("a(ssssb)", [["p1", "Check Admin", "#3a5bd9", "admin", True]])
    elif method == "SwitchTo":
        st["active"] = vals[0]
        out("suu", "ok", 0, 0)
    elif method == "Lock":
        st["active"] = ""
    save()
    sys.exit(0)
items = st["items"]
if method == "Post":
    # Like busctl: the signature must be the contract's (8 strings, a(ss), s, b).
    if rest[1] != "ssssssssa(ss)sb" or len(vals) != 11:
        print("Failed to parse '' number of array entries: Invalid argument", file=sys.stderr)
        sys.exit(1)
    profile, key, source, title = vals[0], vals[1], vals[2], vals[5]
    if caller == "nobody" and "nobody_allowed" not in bugs:
        print("Call failed: Access denied", file=sys.stderr)
        sys.exit(1)
    if caller == "ruya-shell" and "shell_forbidden" in bugs:
        out("su", "forbidden", 0)
        sys.exit(0)
    if st["sources"].get(source) is False and "source_kept" not in bugs:
        out("su", "ok", 0)
        sys.exit(0)
    lst = items.setdefault(profile, [])
    if key and "no_replace" not in bugs:
        for it in [i for i in lst if i["key"] == key]:
            lst.remove(it)
            bus("Removed", [profile, [it["id"]], "replaced"])
    iid = st["next"]
    st["next"] += 1
    lst.append({"id": iid, "key": key, "source": source, "title": title, "unread": True})
    if "no_added" not in bugs:
        bus("Added", [profile, [iid, source, "", "info", title, "", "", [], "normal", False, True, 0]])
    out("su", "ok", iid)
elif method == "List":
    out("a(ussssssa(ss)sbbx)", [[i["id"], i["source"], "", "info", i["title"], "", "", [], "normal", False, i["unread"], 0] for i in items.get(vals[0], [])])
elif method == "MarkRead":
    if "unread_stays" not in bugs:
        for i in items.get(vals[0], []):
            i["unread"] = False
    bus("Changed", [vals[0]])
    out("s", "ok")
elif method == "Withdraw":
    for p, lst in items.items():
        for it in [i for i in lst if i["key"] == vals[0]]:
            if "no_withdraw" not in bugs:
                lst.remove(it)
                bus("Removed", [p, [it["id"]], "withdrawn"])
    out("s", "ok")
elif method == "Dismiss":
    for lst in items.values():
        for it in [i for i in lst if i["id"] == int(vals[0])]:
            lst.remove(it)
    out("s", "ok")
save()
PYEOF
cat > "$nt/bin/busctl" <<'SHIMEOF'
#!/bin/sh
# monitor: prints what is added to the bus log from now on, until it is killed or its parent is gone
# (a loop of the shell, not tail -f: a leftover native tail would hold the test's output pipe open).
case " $* " in *" monitor "*)
    n="$(wc -l < "$NOTIF_BUSLOG")"; i=0
    while kill -0 "$PPID" 2>/dev/null && [ "$i" -lt 600 ]; do
        m="$(wc -l < "$NOTIF_BUSLOG")"
        if [ "$m" -gt "$n" ]; then tail -n "+$((n + 1))" "$NOTIF_BUSLOG" | head -n "$((m - n))"; n="$m"; fi
        i=$((i + 1)); sleep 0.1
    done
    exit 0 ;;
esac
exec python3 "$NOTIF_PY" "$NOTIF_STATE" "$NOTIF_BUSLOG" busctl "$@"
SHIMEOF
for t in systemctl systemd-analyze journalctl; do
    printf '#!/bin/sh\nexec python3 "$NOTIF_PY" "$NOTIF_STATE" "$NOTIF_BUSLOG" %s "$@"\n' "$t" > "$nt/bin/$t"
done
cat > "$nt/bin/runuser" <<'SHIMEOF'
#!/bin/sh
# runuser -u <user> -- <command...>
user="$2"; shift 3
FAKE_CALLER="$user" exec "$@"
SHIMEOF
cat > "$nt/bin/id" <<'SHIMEOF'
#!/bin/sh
echo 990
SHIMEOF
cat > "$nt/bin/stdbuf" <<'SHIMEOF'
#!/bin/sh
shift
exec "$@"
SHIMEOF
chmod +x "$nt/bin/"*
runnotif() { # FAKE_BUG comes from the caller's prefix
    rm -f "$nt/state.json"; : > "$nt/bus.log"
    NOTIF_PY="$nt/fake.py" NOTIF_STATE="$nt/state.json" NOTIF_BUSLOG="$nt/bus.log" \
        NOTIF_BASELINE="$here/../image/security-baseline.json" NOTIF_WAIT=3 PATH="$nt/bin:$shims:$PATH" \
        bash "$here/vm-notifications-check.sh" check 2>&1
}
out="$(runnotif)"; rc=$?
expect_contains "notifications: a good service passes" "$out" "ALL CHECKS PASSED"
expect_lacks "notifications: a good service: no FAIL" "$out" "FAIL"
expect_contains "notifications: it signs a profile in when nobody is" "$out" "PASS: signed p1 in for the check"
[ "$rc" = 0 ] && pass "notifications: a good service: exit 0" || fail "notifications: a good service: exit $rc"
expect_lacks "notifications: the exit trap locks again" "$(cat "$nt/state.json")" '"active": "p1"'
expect_contains "notifications: the exit trap puts ToastSeconds back" "$(cat "$nt/state.json")" '"toast": 4'
expect_contains "notifications: the exit trap puts the sources back" "$(cat "$nt/state.json")" '"sources": {}'
# Bugs that do not get in each other's way share a run (each run costs seconds of fake busctl calls).
for group in \
    "inactive,no_added,unread_stays,shell_silent,no_replace,source_kept,setting_lost" \
    "exposure,no_persist,no_reread,shell_forbidden,no_withdraw,nobody_allowed" \
    "id_reuse"; do
    out="$(FAKE_BUG="$group" runnotif)"; rc=$?
    [ "$rc" = 1 ] && pass "notifications, bugs $group: exit 1" || fail "notifications, bugs $group: exit $rc"
    for case in \
        "inactive|FAIL: ruya-notifications.service is not active" \
        "exposure|FAIL: exposure 5.0 is above the baseline" \
        "no_added|FAIL: no Added for item" \
        "unread_stays|FAIL: MarkRead left item" \
        "no_persist|FAIL: item 1 is gone after the restart" \
        "id_reuse|is not above 1" \
        "shell_silent|FAIL: no 'Notifications1 is not on the bus; notifications are not kept'" \
        "no_reread|FAIL: no GetAll from the shell" \
        "shell_forbidden|FAIL: a Post from ruya-shell" \
        "no_replace|FAIL: the keyed Post did not replace" \
        "no_withdraw|FAIL: Withdraw" \
        "source_kept|FAIL: a switched-off source" \
        "nobody_allowed|FAIL: a Post as nobody was not refused" \
        "setting_lost|FAIL: ToastSeconds is '4' after the restart"; do
        bug="${case%%|*}"; needle="${case#*|}"
        case ",$group," in *",$bug,"*) expect_contains "notifications, bug $bug: caught" "$out" "$needle" ;; esac
    done
done

echo "== vm-play-check.sh: JSON by key (RUY-829) =="
pc() { PATH="$shims:$PATH" bash "$here/vm-play-check.sh" parse "$@"; }
jobs_a='{"type":"aa{sv}","data":[[{"id":{"type":"s","data":"job-1"},"state":{"type":"s","data":"finished"},"status":{"type":"s","data":"bad-signature"}},{"status":{"type":"s","data":""},"state":{"type":"s","data":"running"},"id":{"type":"s","data":"job-2"}}]]}'
got="$(echo "$jobs_a" | pc job job-1)"
[ "$got" = "finished bad-signature" ] && pass "play: a finished job's state and status" || fail "play: job-1 read as '$got'"
got="$(echo "$jobs_a" | pc job job-2)"
[ "$got" = "running " ] && pass "play: keys in another order read the same" || fail "play: job-2 read as '$got'"
got="$(echo "$jobs_a" | pc job job-3)"
[ -z "$got" ] && pass "play: an unknown job reads as nothing" || fail "play: job-3 read as '$got'"
got="$(echo '{"type":"ss","data":["ok","job-7"]}' | pc status)"
[ "$got" = ok ] && pass "play: a call's status" || fail "play: status read as '$got'"
got="$(echo '{"type":"ss","data":["ok","job-7"]}' | pc second)"
[ "$got" = job-7 ] && pass "play: a call's job" || fail "play: job read as '$got'"
srcs='{"type":"aa{sv}","data":[[{"size":{"type":"t","data":5},"path":{"type":"s","data":"/run/media/ruya-shell/A/x.play.zip"},"kind":{"type":"s","data":"zip"}},{"path":{"type":"s","data":"/run/media/ruya-shell/A/Game"}}]]}'
got="$(echo "$srcs" | pc sources | tr -d '\r' | tr '\n' ' ')"
[ "$got" = "/run/media/ruya-shell/A/x.play.zip /run/media/ruya-shell/A/Game " ] && pass "play: ListSources paths by key" || fail "play: sources read as '$got'"
got="$(echo '{"type":"aa{sv}","data":[[{"name":{"type":"s","data":"Hello"},"id":{"type":"s","data":"flatpak:play.com.example.hello"}}]]}' | pc items)"
[ "$got" = flatpak:play.com.example.hello ] && pass "play: Library1 ids by key" || fail "play: items read as '$got'"
# RUY-876: Library1 item ids are flatpak:<id>; the check's greps must match that form.
appid=com.example.hello
echo "$got" | grep -qx "flatpak:play.$appid" && [ "$(grep -c 'grep -qx "flatpak:play.\$appid"' "$here/vm-play-check.sh")" = 2 ] && ! grep -q 'listed" | grep -qx "play\.' "$here/vm-play-check.sh" && pass "vm-play-check.sh matches Library1's flatpak:play.<id> item ids (RUY-876)" || fail "vm-play-check.sh: the Library1 greps do not match flatpak:play.<id>"
# RUY-866: an Inspect record's problem codes, one per line (inspect_clean looks for staging.*/helper.*).
insp='{"type":"sa{sv}","data":["ok",{"problems":{"type":"a(sss)","data":[["trust.unsigned","","x"],["staging.io","","Not a directory"]]},"verdict":{"type":"s","data":"needs-developer-mode"}}]}'
got="$(echo "$insp" | pc codes | tr -d '\r' | tr '\n' ' ')"
[ "$got" = "trust.unsigned staging.io " ] && pass "play: an Inspect record's problem codes" || fail "play: codes read as '$got'"
got="$(echo "$insp" | pc key verdict)"
[ "$got" = needs-developer-mode ] && pass "play: an Inspect record's verdict" || fail "play: verdict read as '$got'"
got="$(echo '{"type":"sa{sv}","data":["ok",{"verdict":{"type":"s","data":"ok"}}]}' | pc codes)"
[ -z "$got" ] && pass "play: a record without problems has no codes" || fail "play: codes of a clean record read as '$got'"
grep -q 'no-gpg-verify' "$here/vm-play-check.sh" && fail "vm-play-check.sh mentions --no-gpg-verify" || pass "vm-play-check.sh never turns signature checks off"
grep -q 'trap cleanup EXIT' "$here/vm-play-check.sh" && pass "vm-play-check.sh cleans up on exit" || fail "vm-play-check.sh: no EXIT trap"
grep -q 'mount -o loop,nosuid,nodev,noexec' "$here/vm-play-check.sh" && pass "vm-play-check.sh mounts its drive as ruya-devices does" || fail "vm-play-check.sh: the check drive is not mounted nosuid,nodev,noexec"
# RUY-839: the probe is the product's own way (files the manager opens), and the script's old slips.
grep -v '^ *#' "$here/vm-play-check.sh" | grep -q -- '--pipe' && fail "vm-play-check.sh uses --pipe (SELinux wedges PID 1's bus)" || pass "vm-play-check.sh never uses systemd-run --pipe"
grep -q 'StandardOutput=file:\$pout' "$here/vm-play-check.sh" && pass "vm-play-check.sh: the probe's output is a file the manager opens" || fail "vm-play-check.sh: the probe has no StandardOutput=file:"
grep -q '/var/tmp/x' "$here/vm-play-check.sh" && fail "vm-play-check.sh probes /var/tmp/x (PrivateTmp makes it succeed)" || pass "vm-play-check.sh: no /var/tmp/x write probe"
grep -q 'chmod +x "\$pack"' "$here/vm-play-check.sh" && pass "vm-play-check.sh makes ruya-pack executable" || fail "vm-play-check.sh: ruya-pack keeps the mode scp gave it"
# RUY-834: the verify mode installs the sample, damages one deployed file and expects the job to say so.
grep -q 'if \[ "\$mode" = verify \]' "$here/vm-play-check.sh" && pass "vm-play-check.sh has a verify mode" || fail "vm-play-check.sh: no verify mode"
grep -q 'call Verify s' "$here/vm-play-check.sh" && pass "vm-play-check.sh calls Play1.Verify" || fail "vm-play-check.sh never calls Verify"
grep -q 'printf x >> "\$app/\$victim"' "$here/vm-play-check.sh" && pass "vm-play-check.sh damages a deployed file as root" || fail "vm-play-check.sh: no damaged file"
grep -q '"ok invalid-package"' "$here/vm-play-check.sh" && grep -q 'package.hash_mismatch' "$here/vm-play-check.sh" && pass "vm-play-check.sh expects invalid-package with package.hash_mismatch" || fail "vm-play-check.sh: the damaged file is not expected to be reported"
grep -q 'truncate -s "\$size"' "$here/vm-play-check.sh" && pass "vm-play-check.sh undoes the damage" || fail "vm-play-check.sh leaves the damaged file"
# RUY-851: the perms mode compares flatpak info --show-permissions with 05 section 8's mapping.
want="$(sed -n "/^PERMS_WANT='/,/'\$/p" "$here/vm-play-check.sh" | sed "s/^PERMS_WANT='//; s/'\$//")"
shown='[Context]
shared=network;ipc;
sockets=pulseaudio;wayland;
devices=dri;
features=multiarch;

[Session Bus Policy]
com.feralinteractive.GameMode=talk
'
pp() { PATH="$shims:$PATH" bash "$here/vm-play-check.sh" parse perms | tr -d '\r'; }
got="$(printf '%s' "$shown" | pp)"
[ -n "$want" ] && [ "$got" = "$want" ] && pass "play perms: the mapped set in another order matches" || fail "play perms: '$got' is not '$want'"
extra="$(printf '%s\n[Context]\nfilesystems=host;\n' "$shown" | pp)"
[ "$extra" != "$want" ] && echo "$extra" | grep -qx '\[Context\] filesystems=host' && pass "play perms: an extra filesystem differs" || fail "play perms: filesystems=host went unseen"
bus="$(printf '%s%s\n' "$shown" 'org.freedesktop.Flatpak=talk' | pp)"
[ "$bus" != "$want" ] && pass "play perms: another bus name differs" || fail "play perms: an extra bus name went unseen"
grep -q 'if \[ "\$mode" = perms \]' "$here/vm-play-check.sh" && grep -q -- '--show-permissions' "$here/vm-play-check.sh" && pass "vm-play-check.sh has a perms mode that reads --show-permissions" || fail "vm-play-check.sh: no perms mode"
# RUY-877: each installing mode has its own id, so no mode meets another's trust record.
wi="$tmp/withid"; mkdir -p "$wi"
python3 - "$wi/in.zip" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("play.json", json.dumps({"id": "org.example.hello", "title": "Hello"}))
    z.writestr("art/icon.png", b"png")
PY
bash "$here/vm-play-check.sh" withid "$wi/in.zip" "$wi/out.zip" org.example.hello.verify
got="$(python3 -c '
import json, sys, zipfile
a, b = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
print(json.loads(b.read("play.json"))["id"], json.loads(b.read("play.json"))["title"], a.read("art/icon.png") == b.read("art/icon.png"), a.namelist() == b.namelist())
' "$wi/in.zip" "$wi/out.zip")"
[ "$got" = "org.example.hello.verify Hello True True" ] && pass "vm-play-check.sh withid changes only the id" || fail "vm-play-check.sh withid: '$got'"
ids="$(grep -o 'appid="\$appid\.[a-z]*"' "$here/vm-play-check.sh" | sort | tr '\n' ' ')"
[ "$ids" = 'appid="$appid.perms" appid="$appid.verify" ' ] && pass "vm-play-check.sh: verify and perms install under their own ids (RUY-877)" || fail "vm-play-check.sh: mode ids '$ids'"
! grep -q 'systemctl restart ruya-play.service' <(sed -n '/^if \[ "\$mode" = perms \]/,/^fi$/p' "$here/vm-play-check.sh") && pass "vm-play-check.sh perms no longer uninstalls the check's id and restarts (RUY-865 workaround gone)" || fail "vm-play-check.sh perms still restarts the service"
grep -q 'SKIP: no profile on this VM' "$here/vm-play-check.sh" && ! grep -q 'bad "no profile' "$here/vm-play-check.sh" && pass "vm-play-check.sh: no profile is a SKIP, not a FAIL (RUY-877)" || fail "vm-play-check.sh: no profile is not a SKIP"
grep -q 'share/ruyaos/play/trust.json' "$here/vm-play-check.sh" && grep -q '"1 unverified None None False"' "$here/vm-play-check.sh" && pass "vm-play-check.sh checks the trust record" || fail "vm-play-check.sh: the trust record is not checked"
[ "$(grep -c '^zin = zipfile.ZipFile(src)' "$here/vm-play-check.sh")" = 2 ] && pass "vm-play-check.sh re-opens the source before the bomb" || fail "vm-play-check.sh: the bomb reuses the tampered zip's ZipInfo objects"

echo "== vm-library-check.sh: a .play app in Library1 (RUY-852) =="
plroot="$tmp/plroot"; mkdir -p "$plroot"; : > "$plroot/icon-512.webp"; : > "$plroot/card-540.webp"
play_rec() { # <play value> <tier json fragment> <icon path>
    printf '{"type":"aa{sv}","data":[[{"id":{"type":"s","data":"flatpak:org.example.Tux"}},{"play":{"type":"b","data":%s},"id":{"type":"s","data":"flatpak:play.com.example.hello"},"title":{"type":"s","data":"Hello"},"genres":{"type":"as","data":["platformer"]},"players":{"type":"(uu)","data":[1,2]}%s,"art":{"type":"a{ss}","data":{"card":"%s/card-540.webp","icon":"%s"}}}]]}' "$1" "$2" "$plroot" "$3"
}
pj() { PLAY_FIXTURE_ROOT="$plroot" PATH="$shims:$PATH" bash "$here/vm-library-check.sh" playjudge com.example.hello; }
tier=',"play_tier":{"type":"s","data":"developer"}'
out="$(play_rec true "$tier" "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" = 0 ] && expect_contains "library play: a full record passes" "$out" "ruya-shell can read the icon art" || fail "library play: a full record failed: $out"
out="$(play_rec true "" "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" = 0 ] && pass "library play: no tier is fine (trust.json may be absent)" || fail "library play: no tier failed: $out"
out="$(play_rec true ',"play_tier":{"type":"s","data":"godlike"}' "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" != 0 ] && pass "library play: an unknown tier FAILs" || fail "library play: an unknown tier passed"
out="$(play_rec false "$tier" "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" != 0 ] && pass "library play: play false FAILs" || fail "library play: play false passed"
out="$(play_rec true "$tier" "$plroot/gone.webp" | pj)"; rc=$?
[ "$rc" != 0 ] && pass "library play: an art path that cannot be read FAILs" || fail "library play: a missing art file passed"
out="$(play_rec true "$tier" "/etc/passwd" | pj)"; rc=$?
[ "$rc" != 0 ] && pass "library play: an art path outside the deployment FAILs" || fail "library play: an outside path passed"
out="$(echo '{"type":"aa{sv}","data":[[{"id":{"type":"s","data":"flatpak:org.example.Tux"}}]]}' | pj)"; rc=$?
[ "$rc" != 0 ] && pass "library play: an app that is not listed FAILs" || fail "library play: a missing item passed"
out="$(printf '{"type":"aa{sv}","data":[[{"id":{"type":"s","data":"flatpak:play.com.example.hello"},"play":{"type":"b","data":true},"title":{"type":"s","data":"Hello"},"genres":{"type":"as","data":[]},"art":{"type":"a{ss}","data":{}}}]]}' | pj)"; rc=$?
[ "$rc" != 0 ] && pass "library play: an item without art FAILs" || fail "library play: an item without icon passed"
grep -q 'm\["id"\] = ' "$here/vm-library-check.sh" && grep -q '\.library' "$here/vm-library-check.sh" && pass "vm-library-check.sh play installs under its own id <id>.library (RUY-877)" || fail "vm-library-check.sh play: no own id"
grep -q 'play_clean$' "$here/vm-library-check.sh" && grep -q 'rm -f "$play_state/incoming/vm-library-check.play.zip"' "$here/vm-library-check.sh" && pass "vm-library-check.sh play removes the sample and the incoming file" || fail "vm-library-check.sh play: no clean-up"

echo "== build stage names (RUY-771) =="
source "$here/lib-stages.sh"
printf '%s\n' 'ARG X=1' 'FROM a/b:${X} AS one' 'RUN true' 'FROM c as Two' 'FROM d AS three-3' 'FROM quay.io/final:${X}' > "$tmp/Containerfile.stages"
got="$(ruya_stage_names "$tmp/Containerfile.stages" | tr '\n' ' ')"
[ "$got" = "one Two three-3 " ] && pass "stage names: 3 named, the final FROM skipped" || fail "stage names: '$got'"
real="$(ruya_stage_names "$here/../image/Containerfile" | tr '\n' ' ')"
expect_contains "stage names: real Containerfile" "$real" "shell-build services-build qt-dmabuf xwayland-satellite"

echo
if [ "$fails" = 0 ]; then echo "vm-check tests: all passed"; else echo "vm-check tests: $fails failed"; fi
exit $(( fails > 0 ))
