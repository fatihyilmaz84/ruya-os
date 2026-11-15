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
#                          missing journal line fails; the probe's udevadm-monitor and ListPlayers helpers
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
 "unconfined": [{"process": "ruya-odd", "reason": "t"}],
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
printf '#!/bin/sh\nif [ "${FAKE_NO_NTSYNC:-}" ]; then echo "Module Size Used by"; else echo "Module Size Used by"; echo "ntsync 24576 0"; fi\n' > "$gm/lsmod"
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
        RUYA_HOME_ROOT="$tmp/prof/home" PATH="$tmp/prof-bin:$PATH" bash "$here/vm-profiles-check.sh" guests 2>&1
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
    "gid|is not its uid"     "reuse|is not greater than"; do
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
expect_contains "players: all good passes" "$out" "ALL CHECKS PASSED"
[ "$rc" = 0 ] && pass "players: exit 0" || fail "players: exit $rc"
out="$(FAKE_PROBE_FAIL=1 runplayers "$pl/with")"; rc=$?
expect_contains "players: a FAIL of the probe fails the check" "$out" "SOME CHECKS FAILED"
[ "$rc" = 1 ] && pass "players: a FAIL of the probe: exit 1" || fail "players: a FAIL of the probe: exit $rc"
expect_contains "players: the profile is removed after a FAIL too" "$(cat "$tmp/players.log")" "DeleteProfile sss p1 1234 p7"
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
runseathold() { # <dir>
    : > "$tmp/seathold.log"
    FAKE_LOG="$tmp/seathold.log" FAKE_DROPIN="$sh_dir/dropin" SEATHOLD_DROPIN_DIR="$sh_dir/dropin" CHECK_TMP="$pl/tmp" \
        PATH="$sh_dir/bin:$PATH" bash "$1/vm-input-check.sh" seathold 2>&1
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

echo
if [ "$fails" = 0 ]; then echo "vm-check tests: all passed"; else echo "vm-check tests: $fails failed"; fi
exit $(( fails > 0 ))
