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
#   - vm-store-check.sh    the `perms` mode (RUY-744): the sandbox probe counts the interfaces other than lo, so
#                          lo alone reads as no network; the test app asks for all devices and not dri; the
#                          probe looks at /dev/bus/usb; the override's devices entries are read in any order
#   - vm-input-check.sh    the `uinput` mode (RUY-1063): no probe or no vm_uinput_trust.py fails, the probe gets both
#                          profiles with the module next to it, a probe FAIL fails
#   - the input udev rules (RUY-1063, test-udev-input-rules.py): /dev/uinput, ruya-inputd's marked devices, foreign
#                          ones (a phys ruya-input/pad1 included), foreign at add and own after the marker, root's
#                          vouched-for stand-ins and hardware, each with its origin, owner, mode, tags and RUN
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
got="$( (export VM_CHECK_LIB_ONLY=1; . "$here/vm-x11-check.sh"; window_pids 1001 p1 < "$tmp/shell.log") | tr '\n' ' ')"
[ "$got" = "4321 4400 " ] && pass "window_pids: the windows of one uid and profile, an empty title included" || fail "window_pids gave '$got'"
out="$(
    export VM_CHECK_LIB_ONLY=1
    # shellcheck disable=SC1090
    . "$here/vm-x11-check.sh"
    printf '%s\n' 'INFO xwayland_satellite: ready' '-> wl_shm@4.create_pool(wl_shm_pool@26, fd 12, 4096)' | satellite_faults | sed 's/^/clean:/'
    printf '%s\n' 'Protocol error 1 on object wl_shm_pool@26: invalid width, height or stride (1920x25, 7680)' \
        "thread 'main' panicked at src/server/mod.rs:803:21: Failed flushing clientside events: Protocol(...)" | satellite_faults
)"
expect_lacks "satellite_faults passes an ordinary log, a debug create_pool line included" "$out" "clean:"
expect_contains "satellite_faults finds the wl_shm_pool protocol error" "$out" "wl_shm_pool@26: invalid width"
expect_contains "satellite_faults finds the satellite's panic" "$out" "Failed flushing clientside events"
# The bridge step (RUY-1028) waits for the exact journal line the helper writes, and for the reason "crashed".
if grep -q 'the X11 bridge stopped: {which}' "$here/../services/ruya-session/src/x11.rs" \
    && grep -q '"the X11 bridge stopped: xwayland-satellite was killed by signal 9"' "$here/vm-x11-check.sh" \
    && grep -q 'is not .crashed.: ' "$here/vm-x11-check.sh" \
    && grep -q 'was killed by signal {sig}' "$here/../services/ruya-session/src/x11.rs"; then
    pass "vm-x11-check.sh bridge step: the line it waits for is the one x11.rs writes"
else
    fail "vm-x11-check.sh bridge step: its line differs from x11.rs's"
fi
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
echo "the input udev rules: own, foreign and trusted devices (RUY-1063)"
out="$(python3 "$here/test-udev-input-rules.py" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && pass "test-udev-input-rules.py exit 0" || fail "test-udev-input-rules.py exit $rc"

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

# --- vm-session-check.sh: running_item, the ListRunning keys of ADR-041 (RUY-1051) -------------------
itemsrc="$tmp/running-item.sh"
sed -n '/^# --- running_item begin/,/^# --- running_item end/p' "$here/vm-session-check.sh" > "$itemsrc"
[ -s "$itemsrc" ] && pass "vm-session-check.sh has the running_item block" || fail "no running_item block in vm-session-check.sh"
listed='{"type":"aa{sv}","data":[[{"instance":{"type":"s","data":"u1"},"app_id":{"type":"s","data":"org.a.B"},"item":{"type":"s","data":"flatpak:org.a.B"},"parent":{"type":"s","data":""}},{"instance":{"type":"s","data":"u2"},"app_id":{"type":"s","data":"org.a.C"}}]]}'
out="$(printf '%s' "$listed" | bash -c ". '$itemsrc'; running_item u1" 2>&1)"
expect_contains "a record with both keys gives item and parent" "$out" "flatpak:org.a.B|"
out="$(printf '%s' "$listed" | bash -c ". '$itemsrc'; running_item u2" 2>&1)"
expect_contains "a record without item and parent is missing" "$out" "missing"
out="$(printf '%s' "$listed" | bash -c ". '$itemsrc'; running_item u9" 2>&1)"
expect_contains "an instance not listed is missing" "$out" "missing"

# --- vm-session-check.sh steam-pause: steam_pair finds Steam and its game (RUY-1054) -----------------
pairsrc="$tmp/steam-pair.sh"
sed -n '/^# --- steam_pair begin/,/^# --- steam_pair end/p' "$here/vm-session-check.sh" > "$pairsrc"
[ -s "$pairsrc" ] && pass "vm-session-check.sh has the steam_pair block" || fail "no steam_pair block in vm-session-check.sh"
listed='{"type":"aa{sv}","data":[[{"instance":{"type":"s","data":"st"},"item":{"type":"s","data":"flatpak:com.valvesoftware.Steam"},"parent":{"type":"s","data":""}},{"instance":{"type":"s","data":"st:steam-70"},"item":{"type":"s","data":"steam:70"},"parent":{"type":"s","data":"st"}}]]}'
out="$(printf '%s' "$listed" | bash -c ". '$pairsrc'; steam_pair" 2>&1)"
expect_contains "steam_pair names Steam, its game and the game's appid" "$out" "st|st:steam-70|70"
listed='{"type":"aa{sv}","data":[[{"instance":{"type":"s","data":"st"},"item":{"type":"s","data":"flatpak:com.valvesoftware.Steam"},"parent":{"type":"s","data":""}}]]}'
out="$(printf '%s' "$listed" | bash -c ". '$pairsrc'; steam_pair" 2>&1)"
expect_contains "steam_pair without a game is none" "$out" "none"

# steam_scope_game asks the product's probe (a stub here) and never reads the processes itself: a
# reaper that carries the game's id inside the client's scope (ADR-041 point 2) is the probe's call.
scopesrc="$tmp/steam-scope-game.sh"
sed -n '/^# --- steam_scope_game begin/,/^# --- steam_scope_game end/p' "$here/vm-session-check.sh" > "$scopesrc"
[ -s "$scopesrc" ] && pass "vm-session-check.sh has the steam_scope_game block" || fail "no steam_scope_game block in vm-session-check.sh"
stub='steam_probe() { case "$2" in game.scope) echo 70;; reaper.scope) ;; late.scope) n=$(cat "$tmp/n" 2>/dev/null || echo 0); echo $((n+1)) > "$tmp/n"; [ "$n" -ge 2 ] && echo 70 || return 3;; *) return 3;; esac; }'
sg() { bash -c "tmp='$tmp'; . '$scopesrc'; $stub; PROBE_RETRY_SLEEP=0 steam_scope_game ruya-p1 $1" 2>&1; }
expect_contains "steam_scope_game: the probe's appid is the game's scope" "$(sg game.scope)" "70"
expect_contains "steam_scope_game: an empty probe (a reaper in the client's scope) is Steam's own" "$(sg reaper.scope)" "-"
rm -f "$tmp/n"
expect_contains "steam_scope_game: exit 3 is retried until decided" "$(sg late.scope)" "70"
expect_contains "steam_scope_game: always undecided is ?" "$(sg stuck.scope)" "?"

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
# and the stubborn app of `kill` (installed from the same remote). RUY-888: and the saver of `shutdown`.
for c in 'vm-session-check.sh'; do
    [ "$(grep -c 'drop_test_apps "$wclient" "$sleeper" "$crasher" "$stubborn" "$saver" "$rt"' "$here/$c")" -ge 6 ]         && pass "$c: every full cleanup also removes the display check's app, the stubborn app and the saver (RUY-708, RUY-736, RUY-888)" || fail "$c: a cleanup leaves $wclient, $stubborn or $saver, which keeps the runtime installed"
done
[ "$(grep -c 'drop_test_apps "$wclient" "$sleeper" "$crasher" "$rt"' "$here/vm-session-check.sh")" -eq 0 ] \
    && pass "vm-session-check.sh: no cleanup without the stubborn app (RUY-736)" || fail "vm-session-check.sh: a cleanup leaves the stubborn app installed"
[ "$(grep -c 'drop_test_apps .*"$stubborn" "$rt"' "$here/vm-session-check.sh")" -eq 0 ] \
    && pass "vm-session-check.sh: no cleanup without the saver (RUY-888)" || fail "vm-session-check.sh: a cleanup leaves the saver installed"

# --- vm-session-check.sh shutdown: a clean end (RUY-888) -------------------------------------------
# The verdict on the journal after StopAll and the user manager's stop: the Dell's two kill lines FAIL.
cleansrc="$tmp/clean.sh"
sed -n '/^# --- judge_clean_end begin/,/^# --- judge_clean_end end/p' "$here/vm-session-check.sh" > "$cleansrc"
[ -s "$cleansrc" ] && pass "vm-session-check.sh has the judge_clean_end block" || fail "no judge_clean_end block in vm-session-check.sh"
runclean() { # <journal text> <uid>
    printf '%s\n' "$1" | bash -c "ok() { echo \"PASS: \$*\"; }; bad() { echo \"FAIL: \$*\"; }; . '$cleansrc'; judge_clean_end 'the stops' '$2'; echo \"rc=\$?\"" 2>&1
}
out="$(runclean 'ruya-session: every app has ended (StopAll)
Stopped user@1001.service - User Manager for UID 1001.' 1001)"
expect_contains "judge_clean_end: a clean end passes" "$out" "PASS: the stops: no SIGKILL"
expect_contains "judge_clean_end: a clean end returns 0" "$out" "rc=0"
out="$(runclean 'user@1001.service: Killing process 4242 (ironwail) with signal SIGKILL.' 1001)"
expect_contains "judge_clean_end: the manager's SIGKILL fails" "$out" "FAIL: the stops: the journal shows a kill: user@1001.service: Killing process 4242"
expect_contains "judge_clean_end: the manager's SIGKILL returns 1" "$out" "rc=1"
out="$(runclean 'Cannot stop frozen unit ruya-app-ruya-p1-io.github.lavenderdotpet.LibreQuake.service.' 1001)"
expect_contains "judge_clean_end: a frozen unit that cannot stop fails" "$out" "FAIL: the stops: the journal shows a kill: Cannot stop frozen unit"
out="$(runclean 'user@1002.service: Killing process 7 (sleep) with signal SIGKILL.' 1001)"
expect_contains "judge_clean_end: another user's manager does not count" "$out" "rc=0"
grep -q 'printf .%s\\n. "$prev" | judge_clean_end "the shutdown" "$puid"' "$here/vm-session-check.sh" \
    && pass "vm-session-check.sh shutdown-verify judges the previous boot's journal" || fail "vm-session-check.sh shutdown-verify: the journal is not judged"
grep -q 'prev="$(journalctl -b -1 ' "$here/vm-session-check.sh" \
    && pass "vm-session-check.sh shutdown-verify reads the boot that went down" || fail "vm-session-check.sh shutdown-verify: not the previous boot"
grep -q 'bash /root/vm-session-check.sh shutdown"' "$here/vm-reboot-check.ps1" \
    && grep -q 'bash /root/vm-session-check.sh shutdown-verify"' "$here/vm-reboot-check.ps1" \
    && pass "vm-reboot-check.ps1 -Shutdown runs both halves around the reboot" || fail "vm-reboot-check.ps1: the shutdown halves are not run"

# --- vm-session-check.sh check: the app unit's limits (RUY-855) ------------------------------------
limsrc="$tmp/limits.sh"
sed -n '/^# --- judge_limits begin/,/^# --- judge_limits end/p' "$here/vm-session-check.sh" > "$limsrc"
[ -s "$limsrc" ] && pass "vm-session-check.sh has the judge_limits block" || fail "no judge_limits block in vm-session-check.sh"
runlimits() { # <show output> <MemTotal kB> <cgroup root>
    printf '%s\n' "$1" | bash -c "ok() { echo \"PASS: \$*\"; }; bad() { echo \"FAIL: \$*\"; }; . '$limsrc'; judge_limits 'limits' $2 '$3'; echo \"rc=\$?\"" 2>&1
}
cgroot="$tmp/cgroot"
mkdir -p "$cgroot/u/a" "$cgroot/u/b" "$cgroot/u/c"
printf '15461882265\n' > "$cgroot/u/a/memory.max"; printf '8192\n' > "$cgroot/u/a/pids.max"
printf 'max\n' > "$cgroot/u/b/memory.max"; printf '8192\n' > "$cgroot/u/b/pids.max"
printf '15461882265\n' > "$cgroot/u/c/memory.max"
showfor() { printf 'MemoryMax=%s\nTasksMax=%s\nControlGroup=/u/%s\n' "$1" "$2" "$3"; }
out="$(runlimits "$(showfor 15461882265 8192 a)" 16777216 "$cgroot")"
expect_contains "judge_limits: 90% of 16 GiB, 8192 and the kernel's files pass" "$out" "PASS: limits: memory.max=15461882265 bytes and pids.max=8192 in the kernel"
expect_contains "judge_limits: a good unit returns 0" "$out" "rc=0"
out="$(runlimits "$(showfor infinity 8192 a)" 16777216 "$cgroot")"
expect_contains "judge_limits: no memory limit fails" "$out" "FAIL: limits: MemoryMax is 'infinity'"
out="$(runlimits "$(showfor 15461882265 15000 a)" 16777216 "$cgroot")"
expect_contains "judge_limits: another TasksMax fails" "$out" "FAIL: limits: TasksMax is '15000'"
expect_contains "judge_limits: another TasksMax returns 1" "$out" "rc=1"
out="$(runlimits "$(showfor 1000 8192 a)" 16777216 "$cgroot")"
expect_contains "judge_limits: a value far from 90% of RAM fails" "$out" "FAIL: limits: MemoryMax=1000 is not about 90%"
out="$(runlimits "$(showfor 15461882265 8192 b)" 16777216 "$cgroot")"
expect_contains "judge_limits: memory.max 'max' in the kernel (not delegated) fails" "$out" "the kernel's memory.max is 'max'"
out="$(runlimits "$(showfor 15461882265 8192 c)" 16777216 "$cgroot")"
expect_contains "judge_limits: a missing pids.max (not delegated) fails" "$out" "the kernel's pids.max is 'missing'"
out="$(runlimits "$(showfor 15461882265 8192 gone)" 16777216 "$cgroot")"
expect_contains "judge_limits: no cgroup directory fails" "$out" "FAIL: limits: no cgroup directory"
grep -q '| judge_limits "the app unit' "$here/vm-session-check.sh"     && pass "vm-session-check.sh check judges the running unit's limits" || fail "vm-session-check.sh: limits not judged"

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
# RUY-744 perms: the sandbox probe counts the interfaces other than lo in /proc/net/dev. It runs here on a
# canned file in its place: lo alone is no network (a withdrawal shows), lo and one more is one.
sed -n '/cat > "\$pwork\/app\/files\/bin\/probe" <<.EOF./,/^EOF$/p' "$here/vm-store-check.sh" | sed '1d;$d' > "$tmp/perms-probe.sh"
grep -q '/proc/net/dev' "$tmp/perms-probe.sh" && pass "vm-store-check.sh perms: the probe is found and reads /proc/net/dev" || fail "vm-store-check.sh perms: no probe found"
printf 'Inter-|   Receive\n face |bytes packets\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n' > "$tmp/netdev-lo"
printf 'Inter-|   Receive\n face |bytes packets\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  eth0: 900 9 0 0 0 0 0 0 900 9 0 0 0 0 0 0\n' > "$tmp/netdev-eth"
sed "s#/proc/net/dev#$tmp/netdev-lo#" "$tmp/perms-probe.sh" > "$tmp/perms-probe-lo.sh"
sed "s#/proc/net/dev#$tmp/netdev-eth#" "$tmp/perms-probe.sh" > "$tmp/perms-probe-eth.sh"
expect_contains "vm-store-check.sh perms: lo alone is no network" "$(bash "$tmp/perms-probe-lo.sh")" "net=0"
expect_contains "vm-store-check.sh perms: lo and eth0 is one interface" "$(bash "$tmp/perms-probe-eth.sh")" "net=1"
grep -q 'flatpak build-finish --command=probe --share=network --device=all --socket=pulseaudio' "$here/vm-store-check.sh" \
    && ! grep -q 'build-finish.*device=dri' "$here/vm-store-check.sh" \
    && pass "vm-store-check.sh perms: the test app asks for all devices and not dri (so /dev/dri stays only through the override)" \
    || fail "vm-store-check.sh perms: the test app's devices do not test the withdrawal"
grep -q 'usb=yes' "$tmp/perms-probe.sh" && pass "vm-store-check.sh perms: the probe reports /dev/bus/usb (the node a device withdrawal takes)" || fail "vm-store-check.sh perms: the probe does not look at /dev/bus/usb"
# The override's devices entries in whatever order Flatpak writes them: one sorted line.
eval "$(grep '^perms_devices_of()' "$here/vm-store-check.sh")"
expect_contains "vm-store-check.sh perms: Flatpak's order of the devices entries does not matter" \
    "[$(printf '[Context]\nshared=!network;\ndevices=dri;!all;input;\n' | perms_devices_of)]" '[!all dri input]'

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
# --- vm-input-check.sh uinput (RUY-1063): the probe and its module, the two profiles, a probe FAIL fails ----------
echo "vm-input-check.sh uinput: the probe gets both profiles and vm_uinput_trust.py next to it"
ui="$tmp/uinput"; mkdir -p "$ui/bin" "$ui/alone" "$ui/nomod" "$ui/with" "$ui/tmp"
cat > "$ui/bin/busctl" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*ListProfiles*) echo 'aa{sv} 2 2 "id" s "p1" "name" s "A" 2 "id" s "p2" "name" s "B"' ;;
esac
exit 0
SHIMEOF
printf '#!/bin/sh\nexit 0\n' > "$ui/bin/systemctl"
chmod +x "$ui/bin"/*
cp "$here/vm-input-check.sh" "$ui/alone/"
cp "$here/vm-input-check.sh" "$here/vm_uinput_trust.py" "$ui/with/"
cp "$here/vm-input-check.sh" "$ui/nomod/"
# A stand-in probe: logs its arguments and whether the module sits next to it; FAKE_PROBE_FAIL makes it fail.
cat > "$ui/with/vm-input-probe.py" <<'SHIMEOF'
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("probe " + " ".join(sys.argv[1:]) + (" module" if os.path.isfile(os.path.join(here, "vm_uinput_trust.py")) else "") + "\n")
print("FAIL: stand-in probe" if os.environ.get("FAKE_PROBE_FAIL") else "PASS: stand-in probe")
SHIMEOF
cp "$ui/with/vm-input-probe.py" "$ui/nomod/"
runuinput() { # <dir>
    : > "$tmp/uinput.log"
    FAKE_LOG="$tmp/uinput.log" CHECK_TMP="$ui/tmp" PATH="$ui/bin:$PATH" bash "$1/vm-input-check.sh" uinput 2>&1
}
out="$(runuinput "$ui/alone")"; rc=$?
expect_contains "uinput without the probe: FAIL" "$out" "vm-input-probe.py is missing: copy it next to this script"
[ "$rc" = 1 ] && pass "uinput without the probe: exit 1" || fail "uinput without the probe: exit $rc"
out="$(runuinput "$ui/nomod")"; rc=$?
expect_contains "uinput without vm_uinput_trust.py: FAIL" "$out" "vm_uinput_trust.py is missing: copy it next to this script"
[ "$rc" = 1 ] && pass "uinput without the module: exit 1" || fail "uinput without the module: exit $rc"
out="$(runuinput "$ui/with")"; rc=$?
[ "$rc" = 0 ] && pass "uinput with a passing probe: exit 0" || fail "uinput with a passing probe: exit $rc ($out)"
expect_contains "uinput runs the probe as p1 with p2 as the other, the module next to it" "$(cat "$tmp/uinput.log")" \
    "probe uinput --user ruya-p1 --profile p1 --other ruya-p2 module"
out="$(FAKE_PROBE_FAIL=1 runuinput "$ui/with")"; rc=$?
[ "$rc" = 1 ] && pass "uinput with a failing probe: exit 1" || fail "uinput with a failing probe: exit $rc"
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
# FAKE_BUG comes from the caller's prefix. $1 = the wait_seen bound in 0.2 s tries: the good run
# gets the real check's 5 s (it returns as soon as the line shows, so a busy host costs nothing);
# the bug runs are expected to FAIL and wait the whole bound, so they keep a short one.
runnotif() {
    rm -f "$nt/state.json"; : > "$nt/bus.log"
    NOTIF_PY="$nt/fake.py" NOTIF_STATE="$nt/state.json" NOTIF_BUSLOG="$nt/bus.log" \
        NOTIF_BASELINE="$here/../image/security-baseline.json" NOTIF_WAIT="${1:-3}" PATH="$nt/bin:$shims:$PATH" \
        bash "$here/vm-notifications-check.sh" check 2>&1
}
out="$(runnotif 25)"; rc=$?
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
# RUY-914: the Inspect assertions read signer_name, developer and signer_key_id by key (absent = empty).
insp='{"type":"sa{sv}","data":["ok",{"developer":{"type":"s","data":"Example Games"},"signer_name":{"type":"s","data":"Example Games"},"signer_key_id":{"type":"s","data":"3f9a41c07be2d6058e21b4a9d0c7f312"}}]}'
got="$(echo "$insp" | pc key signer_name)|$(echo "$insp" | pc key developer)|$(echo "$insp" | pc key signer_key_id)"
[ "$got" = "Example Games|Example Games|3f9a41c07be2d6058e21b4a9d0c7f312" ] && pass "play: Inspect's signer_name, developer and key by key (RUY-914)" || fail "play: Inspect keys read as '$got'"
got="$(echo '{"type":"sa{sv}","data":["ok",{"developer":{"type":"s","data":"Example Games"}}]}' | pc key signer_name)"
[ -z "$got" ] && pass "play: an Inspect record without signer_name reads as nothing (RUY-914)" || fail "play: absent signer_name read as '$got'"
[ "$(grep -c 'parse key signer_name' "$here/vm-play-check.sh")" = 2 ] && pass "vm-play-check.sh asserts Inspect's signer_name, signed and unsigned (RUY-914)" || fail "vm-play-check.sh lacks a signer_name assertion (signed or unsigned)"
# RUY-1038: an Inspect record's art paths (the roles' values, then the screenshots), one per line.
insp='{"type":"sa{sv}","data":["ok",{"art":{"type":"a{ss}","data":{"icon":"/run/ruya-play/inspect/inspect-1/icon-512.webp","hero":"/run/ruya-play/inspect/inspect-1/hero-2160.webp"}},"screenshots":{"type":"as","data":["/run/ruya-play/inspect/inspect-1/screenshot-0-1080.webp"]}}]}'
got="$(echo "$insp" | pc artpaths | tr -d '\r' | tr '\n' ' ')"
[ "$got" = "/run/ruya-play/inspect/inspect-1/icon-512.webp /run/ruya-play/inspect/inspect-1/hero-2160.webp /run/ruya-play/inspect/inspect-1/screenshot-0-1080.webp " ] && pass "play: an Inspect record's art paths (RUY-1038)" || fail "play: art paths read as '$got'"
got="$(echo '{"type":"sa{sv}","data":["ok",{"verdict":{"type":"s","data":"ok"}}]}' | pc artpaths)"
[ -z "$got" ] && pass "play: a record without art has no art paths (RUY-1038)" || fail "play: art paths of a bare record read as '$got'"
# RUY-866: an Inspect record's problem codes, one per line (inspect_clean looks for staging.*/helper.*).
insp='{"type":"sa{sv}","data":["ok",{"problems":{"type":"a(sss)","data":[["trust.unsigned","","x"],["staging.io","","Not a directory"]]},"verdict":{"type":"s","data":"needs-developer-mode"}}]}'
got="$(echo "$insp" | pc codes | tr -d '\r' | tr '\n' ' ')"
[ "$got" = "trust.unsigned staging.io " ] && pass "play: an Inspect record's problem codes" || fail "play: codes read as '$got'"
got="$(echo "$insp" | pc key verdict)"
[ "$got" = needs-developer-mode ] && pass "play: an Inspect record's verdict" || fail "play: verdict read as '$got'"
got="$(echo '{"type":"sa{sv}","data":["ok",{"verdict":{"type":"s","data":"ok"}}]}' | pc codes)"
[ -z "$got" ] && pass "play: a record without problems has no codes" || fail "play: codes of a clean record read as '$got'"
# RUY-1001: the one way a check removes a .play app is `removeapp`: Play1.Remove as an admin, then the job's end.
# busctl is a fake Play1: Remove answers $FAKE_REMOVE (default: ok, job-9), ListJobs says job-9 finished with $FAKE_JOB.
rm="$tmp/removeapp"; mkdir -p "$rm"
printf '#!/bin/sh\necho 0\n' > "$rm/id"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$rm/runuser"
cat > "$rm/busctl" <<'SHIMEOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$*" in
    *" Remove "*) if [ -n "$FAKE_REMOVE" ]; then echo "$FAKE_REMOVE"; else echo '{"type":"ss","data":["ok","job-9"]}'; fi ;;
    *" ListJobs"*) echo "{\"type\":\"aa{sv}\",\"data\":[[{\"id\":{\"type\":\"s\",\"data\":\"job-9\"},\"state\":{\"type\":\"s\",\"data\":\"finished\"},\"status\":{\"type\":\"s\",\"data\":\"${FAKE_JOB:-ok}\"}}]]}" ;;
esac
SHIMEOF
chmod +x "$rm/id" "$rm/runuser" "$rm/busctl"
rmrun() { FAKE_LOG="$tmp/removeapp.log" PATH="$rm:$PATH" bash "$here/vm-play-check.sh" removeapp play.com.example.hello 2>&1; }
: > "$tmp/removeapp.log"
out="$(rmrun)"; rc=$?
[ "$rc" = 0 ] && ! echo "$out" | grep -q FAIL && pass "play: removeapp is silent and exit 0 when the Remove job finishes ok" || fail "play: removeapp of a finished job: exit $rc, '$out'"
grep -q 'Remove sa{sv} play.com.example.hello 1 admin_approved b true' "$tmp/removeapp.log" && pass "play: removeapp calls Play1.Remove for the app as an admin" || fail "play: removeapp called '$(cat "$tmp/removeapp.log")'"
grep -q ' ListJobs' "$tmp/removeapp.log" && pass "play: removeapp waits for the job (ListJobs)" || fail "play: removeapp never looked at the job"
out="$(FAKE_JOB=failed rmrun)"; rc=$?
[ "$rc" != 0 ] && expect_contains "play: a Remove job that ends failed is a FAIL line" "$out" "FAIL: Play1.Remove of play.com.example.hello: ok failed" || fail "play: a failed Remove job exited 0"
out="$(FAKE_REMOVE='{"type":"ss","data":["busy",""]}' rmrun)"; rc=$?
[ "$rc" != 0 ] && expect_contains "play: a refused Remove is a FAIL line" "$out" "FAIL: Play1.Remove of play.com.example.hello: busy -" || fail "play: a refused Remove exited 0"
out="$(FAKE_REMOVE='{"type":"ss","data":["unknown-app",""]}' rmrun)"; rc=$?
[ "$rc" = 0 ] && ! echo "$out" | grep -q FAIL && pass "play: removeapp of an app that is not installed is nothing to remove" || fail "play: removeapp of an unknown app: exit $rc, '$out'"
! grep -v '^ *#' "$here/vm-play-check.sh" | grep -q 'flatpak uninstall' && pass "vm-play-check.sh removes no .play app with flatpak uninstall" || fail "vm-play-check.sh: a flatpak uninstall"
grep -q 'remove_app "play.$appid"' "$here/vm-play-check.sh" && pass "vm-play-check.sh: the cleanup removes the app through remove_app" || fail "vm-play-check.sh: the cleanup does not use remove_app"
! sed -n '/^play_clean() {/,/^}/p' "$here/vm-library-check.sh" | grep -q 'flatpak uninstall' && sed -n '/^play_clean() {/,/^}/p' "$here/vm-library-check.sh" | grep -q 'vm-play-check.sh" removeapp' && pass "vm-library-check.sh play_clean removes the sample through vm-play-check.sh removeapp" || fail "vm-library-check.sh play_clean: not through removeapp"
# RUY-1001: GetRunnerChoice returns status and choice (two strings, `ss`).
cj() { printf '%s\n' "$1" | bash "$here/vm-library-check.sh" choicejudge "$2" 2>&1; }
expect_contains "vm-library-check.sh choicejudge: ss \"ok\" \"system\" is the system choice" "$(cj 'ss "ok" "system"' system)" "PASS: the reply is ok with the choice system"
expect_contains "vm-library-check.sh choicejudge: ss \"ok\" \"package\" is the package choice" "$(cj 'ss "ok" "package"' package)" "PASS: the reply is ok with the choice package"
expect_contains "vm-library-check.sh choicejudge: the one-string form is not the reply" "$(cj 's "ok" "system"' system)" "FAIL: the reply is not ok with the choice system"
expect_contains "vm-library-check.sh choicejudge: another choice is refused" "$(cj 'ss "ok" "package"' system)" "FAIL: the reply is not ok with the choice system"
expect_contains "vm-library-check.sh choicejudge: a status that is not ok is refused" "$(cj 'ss "unknown" ""' system)" "FAIL: the reply is not ok with the choice system"
# RUY-1056: the steam mode reads the steam: ids of ListItems (busctl's text), each once and sorted.
sids="$(printf '%s\n' 'aa{sv} 3 7 "id" s "steam:70" "kind" s "game" 7 "id" s "flatpak:org.x.A" 7 "id" s "steam:220" "launch" s "steam://rungameid/220" "x" s "steam:220"' | bash "$here/vm-library-check.sh" steamids 2>&1 | tr '\n' ' ')"
[ "$sids" = "steam:220 steam:70 " ] && pass "vm-library-check.sh steamids: the two steam: ids, once each" || fail "vm-library-check.sh steamids: '$sids'"
sids="$(printf '%s\n' 'aa{sv} 1 7 "id" s "flatpak:org.x.A" "launch" s "flatpak:org.x.A"' | bash "$here/vm-library-check.sh" steamids 2>&1)"
[ -z "$sids" ] && pass "vm-library-check.sh steamids: none in a Flatpak-only list" || fail "vm-library-check.sh steamids: '$sids'"
# The steam mode's unit properties are the reader's (spawner::PROFILE_SCAN_PROPERTIES), in order.
code_props="$(sed -n '/^pub const PROFILE_SCAN_PROPERTIES/,/^];/p' "$here/../services/ruya-session/src/spawner.rs" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')"
check_props="$(sed -n 's/^scan_properties="\(.*\)"$/\1/p' "$here/vm-library-check.sh") "
[ -n "$code_props" ] && [ "$code_props" = "$check_props" ] && pass "vm-library-check.sh steam: the reader's properties, as ruya-session runs it" || fail "vm-library-check.sh scan_properties '$check_props' are not spawner.rs's '$code_props'"
code_rt="$(sed -n 's/^pub const PROFILE_SCAN_RUNTIME_SECS: u32 = \([0-9]*\);$/\1/p' "$here/../services/ruya-session/src/spawner.rs")"
check_rt="$(sed -n 's/^scan_runtime=\([0-9]*\)$/\1/p' "$here/vm-library-check.sh")"
[ -n "$code_rt" ] && [ "$code_rt" = "$check_rt" ] && pass "vm-library-check.sh steam: the reader's RuntimeMaxSec, as ruya-session runs it" || fail "vm-library-check.sh scan_runtime '$check_rt' is not spawner.rs's '$code_rt'"
# RUY-1102: the steam mode's sandbox probe, judged (scanjudge) as the Dell printed it under the reader's
# properties; a writable home or /run/user, a socket that opens or is only refused, or no python fails.
sj() { printf '%s\n' "$@" | bash "$here/vm-library-check.sh" scanjudge 2>&1; }
sj_good=("write home: read-only" "write runuser: read-only" "read home: ok" "python: rc0" "socket AF_UNIX: rc159" "socket AF_INET: rc159" "socket AF_INET6: rc159" "socket AF_NETLINK: rc159")
expect_contains "vm-library-check.sh scanjudge: the sandbox the Dell measured passes" "$(sj "${sj_good[@]}")" "ALL CHECKS PASSED"
expect_contains "vm-library-check.sh scanjudge: a writable home fails" "$(sj "write home: written" "${sj_good[@]:1}")" "FAIL: a write to the home as the reader's unit"
expect_contains "vm-library-check.sh scanjudge: a writable /run/user fails" "$(sj "${sj_good[0]}" "write runuser: written" "${sj_good[@]:2}")" "FAIL: a write to the runuser as the reader's unit"
expect_contains "vm-library-check.sh scanjudge: an unreadable home fails" "$(sj "${sj_good[@]:0:2}" "read home: failed" "${sj_good[@]:3}")" "FAIL: the reader's unit cannot read the home"
expect_contains "vm-library-check.sh scanjudge: an AF_INET6 socket that opens fails" "$(sj "${sj_good[@]:0:6}" "socket AF_INET6: rc0" "${sj_good[7]}")" "FAIL: socket(AF_INET6) in the reader's unit: socket AF_INET6: rc0"
expect_contains "vm-library-check.sh scanjudge: a socket only refused (not the filter's kill) fails" "$(sj "${sj_good[@]:0:4}" "socket AF_UNIX: rc1" "${sj_good[@]:5}")" "FAIL: socket(AF_UNIX)"
expect_contains "vm-library-check.sh scanjudge: no python3 fails" "$(sj "${sj_good[@]:0:3}" "python: rc127" "${sj_good[@]:4}")" "FAIL: python3 does not run"
expect_contains "vm-library-check.sh scanjudge: an empty probe fails" "$(sj "")" "SOME CHECKS FAILED"
grep -q 'no-gpg-verify' "$here/vm-play-check.sh" && fail "vm-play-check.sh mentions --no-gpg-verify" || pass "vm-play-check.sh never turns signature checks off"
# RUY-900: the metadata generation in installed.json, read and set as the service writes the file.
gj="$tmp/installed.json"
printf '{\n  "format": 1,\n  "installed": [\n    {\n      "id": "com.example.old",\n      "build": 3\n    },\n    {\n      "id": "com.example.new",\n      "build": 1,\n      "generation": 1\n    }\n  ]\n}\n' > "$gj"
gen() { bash "$here/vm-play-check.sh" generation "$@"; }
[ "$(gen "$gj" com.example.old)" = 0 ] && pass "play: an entry without a generation reads 0" || fail "play: an entry without a generation reads '$(gen "$gj" com.example.old)'"
[ "$(gen "$gj" COM.Example.New)" = 1 ] && pass "play: a generation is read by the id in any case" || fail "play: the generation of com.example.new reads '$(gen "$gj" COM.Example.New)'"
[ "$(gen "$gj" com.example.none)" = none ] && pass "play: an id without an entry is none" || fail "play: an id without an entry reads '$(gen "$gj" com.example.none)'"
gen "$gj" com.example.new 0 >/dev/null
[ "$(gen "$gj" com.example.new)" = 0 ] && [ "$(gen "$gj" com.example.old)" = 0 ] && grep -q '"build": 3' "$gj" && pass "play: setting a generation keeps the other entries" || fail "play: setting a generation: $(cat "$gj")"
# The log lines the recommit check waits for are the service's own.
main_rs="$here/../services/ruya-play/src/main.rs"
grep -q 'eprintln!("ruya-play: recommitted play.{id}")' "$main_rs" && grep -q 'grep -qx "ruya-play: recommitted play.$id"' "$here/vm-play-check.sh" && pass "play: the recommit check waits for the service's own log line" || fail "play: vm-play-check.sh and main.rs disagree on the recommit log line"
grep -q 'eprintln!("ruya-play: serving {BUS_NAME}")' "$main_rs" && grep -q 'eprintln!("ruya-play: reconcile: {a:?}")' "$main_rs" && grep -q 'Recommit { id: \\"$id\\" }' "$here/vm-play-check.sh" && pass "play: the second start's check reads the reconcile's own log lines" || fail "play: vm-play-check.sh and main.rs disagree on the reconcile log lines"
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
# RUY-816: the remove mode calls Play1.Remove with and without admin_approved, waits for the job and expects the
# records and the deployment gone; its busctl call has the contract's signature (s, a{sv}).
grep -q 'if \[ "\$mode" = remove \]' "$here/vm-play-check.sh" && pass "vm-play-check.sh has a remove mode" || fail "vm-play-check.sh: no remove mode"
grep -c "call Remove 'sa{sv}'" "$here/vm-play-check.sh" | grep -qx 3 && grep -A4 'name="Remove"' "$here/../api/dbus/org.ruyaos.Play1.xml" | grep -q 'name="options" type="a{sv}"' && pass "vm-play-check.sh calls Play1.Remove as (s, a{sv}), the signature of Play1.xml" || fail "vm-play-check.sh: its Remove calls do not match Play1.xml"
grep -q '"remove", "removing", "ok"' "$here/vm-play-check.sh" && pass "vm-play-check.sh expects kind remove, phase removing in the job table" || fail "vm-play-check.sh: the remove job is not checked in state/jobs"
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
# RUY-854: the perms mode asks Store1 (as root, an admin) for the .play app's permission list, withdraws the
# network and tests it from inside the app's sandbox with a connection attempt.
store_json='{"type":"sasasas","data":["ok",["network","audio"],["gamepad","all-devices"],["network"]]}'
[ "$(echo "$store_json" | pc status)" = ok ] && pass "play perms: a GetPermissions status" || fail "play perms: status of '$store_json'"
[ "$(echo "$store_json" | pc keys effective)" = "network audio" ] && [ "$(echo "$store_json" | pc keys withdrawn)" = "gamepad all-devices" ] && [ "$(echo "$store_json" | pc keys withdrawable)" = network ] && pass "play perms: the three lists of a GetPermissions answer" || fail "play perms: the lists read as '$(echo "$store_json" | pc keys effective)' '$(echo "$store_json" | pc keys withdrawn)' '$(echo "$store_json" | pc keys withdrawable)'"
[ -z "$(echo '{"type":"sasasas","data":["unknown-app",[],[],[]]}' | pc keys effective)" ] && pass "play perms: an unknown app has no keys" || fail "play perms: unknown-app read with keys"
np="$tmp/netprobe"; mkdir -p "$np"
probe="$(sed -n "/^NET_PROBE='/,/connect=no\"; fi'\$/p" "$here/vm-play-check.sh" | sed "1s/^NET_PROBE='//; \$s/'\$//")"
printf 'Inter-|   Receive\n face |bytes\n    lo: 1 2\n  eth0: 3 4\n' > "$np/shared"
printf 'Inter-|   Receive\n face |bytes\n    lo: 1 2\n' > "$np/unshared"
python3 -c '
import socket, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
print(s.getsockname()[1], flush=True)
time.sleep(20)
' > "$np/port" &
lpid=$!
n=0; while [ ! -s "$np/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
lport="$(cat "$np/port")"
got="$(PROC_NET_DEV="$np/shared" bash -c "$probe" probe "$lport" | tr -d '\r' | tr '\n' ' ')"
[ "$got" = "net=1 connect=yes " ] && pass "play perms: the sandbox probe sees an interface and reaches a listener" || fail "play perms: the probe says '$got'"
got="$(PROC_NET_DEV="$np/unshared" bash -c "$probe" probe 1 | tr -d '\r' | tr '\n' ' ')"
[ "$got" = "net=0 connect=no " ] && pass "play perms: the probe sees no interface and no listener" || fail "play perms: the probe says '$got'"
kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
# The calls the mode makes are the signatures of Store1.xml.
storexml="$here/../api/dbus/org.ruyaos.Store1.xml"
grep -A2 'name="GetPermissions"' "$storexml" | grep -q 'name="app_id" type="s"' && grep -A3 'name="WithdrawPermission"' "$storexml" | grep -q 'name="key" type="s"' && grep -q 'store_call GetPermissions s ' "$here/vm-play-check.sh" && grep -q 'store_call WithdrawPermission ss ' "$here/vm-play-check.sh" && grep -q 'store_call ResetPermissions s ' "$here/vm-play-check.sh" && pass "vm-play-check.sh calls Store1's permission methods with the signatures of Store1.xml" || fail "vm-play-check.sh: its Store1 calls do not match Store1.xml"
grep -q 'permission_list_checks "play.\$appid"' "$here/vm-play-check.sh" && grep -q 'flatpak override --system --reset "play.\$appid"' "$here/vm-play-check.sh" && pass "vm-play-check.sh perms runs the permission list checks and drops the override at exit" || fail "vm-play-check.sh perms: no permission list checks or no override cleanup"
grep -q 'connect=no' "$here/vm-play-check.sh" && grep -q 'WithdrawPermission ss "\$papp" network' "$here/vm-play-check.sh" && pass "vm-play-check.sh perms withdraws the network and expects a refused connection" || fail "vm-play-check.sh perms: the network-off case is gone"
# RUY-923: Play1.Remove drops the app's permission override. The remove mode installs a copy of the sample that
# asks for the network (the perms mode's copy), has an admin withdraw it, expects `flatpak override --system
# --show` to be empty after the removal and nothing withdrawn after the reinstall.
an="$tmp/asknet"; mkdir -p "$an"
python3 - "$an/in.zip" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("play.json", json.dumps({"id": "org.example.hello", "title": "Hello", "permissions": {"network": False}}))
    z.writestr("art/icon.png", b"png")
PY
bash "$here/vm-play-check.sh" asknet "$an/in.zip" "$an/out.zip"
got="$(python3 -c '
import json, sys, zipfile
a, b = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
m = json.loads(b.read("play.json"))
print(m["id"], m["permissions"]["network"], m["permissions"]["multiarch"], m["permissions"]["gamemode"], a.read("art/icon.png") == b.read("art/icon.png"), a.namelist() == b.namelist())
' "$an/in.zip" "$an/out.zip")"
[ "$got" = "org.example.hello True True True True True" ] && pass "vm-play-check.sh asknet asks for network, multiarch and gamemode and changes nothing else" || fail "vm-play-check.sh asknet: '$got'"
grep -c 'asks_network "\$work/id.play.zip"' "$here/vm-play-check.sh" | grep -qx 2 && pass "vm-play-check.sh: perms and remove build the network-asking package with one function" || fail "vm-play-check.sh: perms and remove do not both use asks_network"
rm_block="$(sed -n '/^remove_checks() {/,/^}/p' "$here/vm-play-check.sh")"
echo "$rm_block" | grep -q 'WithdrawPermission ss "play.\$appid" network' && echo "$rm_block" | grep -q 'the removal left no override' && echo "$rm_block" | grep -q 'flatpak override --system --show "play.\$appid"' && echo "$rm_block" | grep -q 'the reinstall starts with nothing withdrawn' && pass "vm-play-check.sh remove withdraws the network, expects no override after Play1.Remove and nothing withdrawn after the reinstall (RUY-923)" || fail "vm-play-check.sh remove: the override is not checked after Play1.Remove"
grep -A5 '^permission_list_checks() {' "$here/vm-play-check.sh" | grep -q 'override --system --reset' && fail "vm-play-check.sh perms resets an earlier run's override at the start again" || pass "vm-play-check.sh perms needs no reset of an earlier run's override (Play1.Remove drops it)"
# RUY-877: each installing mode has its own id, so no mode meets another's trust record.
wi="$tmp/withid"; mkdir -p "$wi"
python3 - "$wi/in.zip" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("play.json", json.dumps({"id": "org.example.hello", "title": "Hello"}))
    z.writestr("art/icon.png", b"png")
PY
bash "$here/vm-play-check.sh" withid "$wi/in.zip" "$wi/out.zip" org.example.hello_verify
got="$(python3 -c '
import json, sys, zipfile
a, b = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
print(json.loads(b.read("play.json"))["id"], json.loads(b.read("play.json"))["title"], a.read("art/icon.png") == b.read("art/icon.png"), a.namelist() == b.namelist())
' "$wi/in.zip" "$wi/out.zip")"
[ "$got" = "org.example.hello_verify Hello True True" ] && pass "vm-play-check.sh withid changes only the id" || fail "vm-play-check.sh withid: '$got'"
# RUY-879: check takes a new id each run (key A's trust record for an id outlives an uninstall).
r1="$(bash "$here/vm-play-check.sh" runid org.example.hello)"; r2="$(bash "$here/vm-play-check.sh" runid org.example.hello)"
[ "$r1" != "$r2" ] && pass "vm-play-check.sh check: two runs get two ids (RUY-879)" || fail "vm-play-check.sh runid: '$r1' twice"
# The limit is the format's own (MAX_ID_BYTES), written once in the script and asserted here.
rust_max="$(sed -n 's/^pub const MAX_ID_BYTES: usize = \([0-9]*\);/\1/p' "$here/../services/ruya-play-format/src/limits.rs")"
script_max="$(sed -n 's/^PLAY_MAX_ID_BYTES=\([0-9]*\)$/\1/p' "$here/vm-play-check.sh")"
[ -n "$rust_max" ] && [ "$rust_max" = "$script_max" ] && pass "vm-play-check.sh PLAY_MAX_ID_BYTES is the format's MAX_ID_BYTES ($rust_max)" || fail "vm-play-check.sh PLAY_MAX_ID_BYTES '$script_max' differs from MAX_ID_BYTES '$rust_max'"
for r in "$r1" "$r2"; do
    echo "$r" | grep -Eq '^org\.example\.hello_c[0-9]+x[0-9]+$' && [ "${#r}" -le "$rust_max" ] && [ "$(( ${#r} + 5 ))" -le 255 ] || fail "vm-play-check.sh runid: '$r' breaks the id rules (letter-led part, length)"
done
# A last part with '-' stays valid (Flatpak allows '-' only there): the run part joins it with '_'.
r3="$(bash "$here/vm-play-check.sh" runid org.example.hello-game)"
echo "$r3" | grep -Eq '^org\.example\.hello-game_c[0-9]+x[0-9]+$' && pass "vm-play-check.sh runid: a last part with '-' keeps no '-' outside the last part" || fail "vm-play-check.sh runid: '$r3' for a last part with '-'"
# An id that would pass the limit is refused with a FAIL line, no id printed (the limit, not 255).
long="org.example.$(printf 'a%.0s' $(seq 1 $(( rust_max - 12 ))))"
out="$(bash "$here/vm-play-check.sh" runid "$long" 2>&1)"; rc=$?
[ "$rc" != 0 ] && expect_contains "vm-play-check.sh runid: an id that would pass $rust_max bytes FAILs" "$out" "FAIL: the package id" || fail "vm-play-check.sh runid: a $(( ${#long} + 20 ))-byte id passed (rc $rc)"
short="org.example.$(printf 'a%.0s' $(seq 1 $(( rust_max - 12 - 25 ))))"
out="$(bash "$here/vm-play-check.sh" runid "$short" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "${#out}" -le "$rust_max" ] && pass "vm-play-check.sh runid: an id that fits the limit passes" || fail "vm-play-check.sh runid: '$out' (rc $rc)"
grep -q 'appid="\$(run_id "\$appid")"' "$here/vm-play-check.sh" && grep -q 'with_id "\$zip" "\$work/run.play.zip"' "$here/vm-play-check.sh" && pass "vm-play-check.sh check builds every package from the run-id copy (RUY-879)" || fail "vm-play-check.sh check: not built from the run-id copy"
ids="$(grep -o 'appid="\$(pkg_id "\$appid" [a-z]*)"' "$here/vm-play-check.sh" | sort | tr '\n' ' ')"
[ "$ids" = 'appid="$(pkg_id "$appid" perms)" appid="$(pkg_id "$appid" remove)" appid="$(pkg_id "$appid" verify)" ' ] && pass "vm-play-check.sh: remove, verify and perms install under their own ids, through pkg_id (RUY-877, RUY-887)" || fail "vm-play-check.sh: mode ids '$ids'"
! grep -Eq 'appid="\$appid\.|run_id\(\) \{ echo' "$here/vm-play-check.sh" && pass "vm-play-check.sh: no id is made by appending a dotted part (RUY-887)" || fail "vm-play-check.sh: an id with an appended dotted part"
# RUY-887: every mode's id keeps a last part with '-' valid (verify, perms, the library check, check).
for part in verify perms library; do
    got="$(bash "$here/vm-play-check.sh" pkgid org.example.hello-game "$part")"
    [ "$got" = "org.example.hello-game_$part" ] && pass "vm-play-check.sh pkgid: a last part with '-' stays valid for $part" || fail "vm-play-check.sh pkgid $part: '$got'"
done
got="$(bash "$here/vm-library-check.sh" playid org.example.hello-game | head -n 1)"
[ "$got" = "org.example.hello-game_library" ] && pass "vm-library-check.sh play: its id for a last part with '-' is valid (RUY-887)" || fail "vm-library-check.sh playid: '$got'"
grep -q 'vm-play-check.sh" pkgid' "$here/vm-library-check.sh" && ! grep -Eq 'echo "\$1[._]library"' "$here/vm-library-check.sh" && pass "vm-library-check.sh has no id suffix rule of its own, it asks vm-play-check.sh pkgid" || fail "vm-library-check.sh: its own id suffix"
! grep -q 'systemctl restart ruya-play.service' <(sed -n '/^if \[ "\$mode" = perms \]/,/^fi$/p' "$here/vm-play-check.sh") && pass "vm-play-check.sh perms no longer uninstalls the check's id and restarts (RUY-865 workaround gone)" || fail "vm-play-check.sh perms still restarts the service"
pc="$here/../image/rootfs/usr/lib/tmpfiles.d/ruya-play.conf"
if grep -qx 'R /var/lib/ruya-play/staging - - - -' "$pc" && grep -qx 'R /var/lib/ruya-play/inspect - - - -' "$pc"     && ! grep -Eq '^[dDfFwzZ] +/var/lib/ruya-play/(staging|inspect)' "$pc"; then
    pass "ruya-play.conf removes the old staging/ and inspect/ and creates neither (RUY-867)"
else
    fail "ruya-play.conf: R lines for the old staging/ and inspect/ missing, or a line creates them"
fi
grep -q 'the old \$state/\$old is gone' "$here/vm-play-check.sh" && pass "vm-play-check.sh checks the old folders are gone (RUY-867)" || fail "vm-play-check.sh: no old-folder step"
grep -q 'SKIP: no profile on this VM' "$here/vm-play-check.sh" && ! grep -q 'bad "no profile' "$here/vm-play-check.sh" && pass "vm-play-check.sh: no profile is a SKIP, not a FAIL (RUY-877)" || fail "vm-play-check.sh: no profile is not a SKIP"
grep -q 'share/ruyaos/play/trust.json' "$here/vm-play-check.sh" && grep -q '"1 unverified None None False"' "$here/vm-play-check.sh" && pass "vm-play-check.sh checks the trust record" || fail "vm-play-check.sh: the trust record is not checked"
[ "$(grep -c '^zin = zipfile.ZipFile(src)' "$here/vm-play-check.sh")" = 2 ] && pass "vm-play-check.sh re-opens the source before the bomb" || fail "vm-play-check.sh: the bomb reuses the tampered zip's ZipInfo objects"

echo "== vm-library-check.sh: a .play app in Library1 (RUY-852) =="
plroot="$tmp/plroot"; mkdir -p "$plroot"; : > "$plroot/icon-512.webp"; : > "$plroot/card-540.webp"
for i in 0 1; do : > "$plroot/screenshot-$i-1080.webp"; done
play_rec() { # <play value> <tier json fragment> <icon path>
    printf '{"type":"aa{sv}","data":[[{"id":{"type":"s","data":"flatpak:org.example.Tux"}},{"play":{"type":"b","data":%s},"id":{"type":"s","data":"flatpak:play.com.example.hello"},"title":{"type":"s","data":"Hello"},"genres":{"type":"as","data":["platformer"]},"players":{"type":"(uu)","data":[1,2]}%s,"art":{"type":"a{ss}","data":{"card":"%s/card-540.webp","icon":"%s"}}}]]}' "$1" "$2" "$plroot" "$3"
}
pj() { PLAY_FIXTURE_ROOT="$plroot" PATH="$shims:$PATH" bash "$here/vm-library-check.sh" playjudge com.example.hello "$@"; }
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
# RUY-886: play_signer_key_id and play_screenshots. The sample installs unsigned and declares n shots.
shots() { printf ',"play_screenshots":{"type":"as","data":[%s]}' "$1"; }
two="\"$plroot/screenshot-0-1080.webp\",\"$plroot/screenshot-1-1080.webp\""
kid=0123456789abcdef0123456789abcdef
out="$(play_rec true "$tier$(shots "$two")" "$plroot/icon-512.webp" | pj 2)"; rc=$?
[ "$rc" = 0 ] && expect_contains "library play: the screenshots in order as readable paths pass" "$out" "play_screenshots lists 2 screenshot(s)" || fail "library play: good screenshots failed: $out"
out="$(play_rec true "$tier" "$plroot/icon-512.webp" | pj 2)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: a missing play_screenshots key FAILs when the sample has shots" "$out" "play_screenshots lists 0, the sample has 2" || fail "library play: missing shots passed"
out="$(play_rec true "$tier$(shots "$two")" "$plroot/icon-512.webp" | pj 0)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: shots the sample does not have FAIL" "$out" "play_screenshots lists 2, the sample has 0" || fail "library play: extra shots passed"
out="$(play_rec true "$tier$(shots "\"$plroot/screenshot-1-1080.webp\",\"$plroot/screenshot-0-1080.webp\"")" "$plroot/icon-512.webp" | pj 2)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: screenshots out of order FAIL" "$out" "not screenshot-<n>-1080 files in rising order" || fail "library play: shots out of order passed"
out="$(play_rec true "$tier$(shots "\"$plroot/screenshot-0-1080.webp\",\"$plroot/screenshot-9-1080.webp\"")" "$plroot/icon-512.webp" | pj 2)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: an unreadable screenshot FAILs" "$out" "ruya-shell cannot read screenshot shot.1" || fail "library play: an unreadable shot passed"
out="$(play_rec true "$tier$(shots "\"/etc/passwd\"")" "$plroot/icon-512.webp" | pj 1)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: a screenshot outside the deployment FAILs" "$out" "screenshot shot.0 is outside the deployment" || fail "library play: an outside shot passed"
out="$(play_rec true "$tier,\"play_signer_key_id\":{\"type\":\"s\",\"data\":\"$kid\"}" "$plroot/icon-512.webp" | pj 0)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: a key id on an unsigned sample FAILs" "$out" "play_signer_key_id is '$kid' for an unsigned sample" || fail "library play: a key id on an unsigned sample passed"
out="$(play_rec true "$tier,\"play_signer_key_id\":{\"type\":\"s\",\"data\":\"$kid\"}" "$plroot/icon-512.webp" | pj 0 "$kid")"; rc=$?
[ "$rc" = 0 ] && expect_contains "library play: a signed run's key id passes" "$out" "play_signer_key_id is the signer's key id" || fail "library play: the expected key id failed: $out"
out="$(play_rec true "$tier" "$plroot/icon-512.webp" | pj 0 "$kid")"; rc=$?
[ "$rc" != 0 ] && pass "library play: a missing key id FAILs when the run signs" || fail "library play: a missing key id passed"
# RUY-903: the native sample has no play_runner keys and the launcher's resolution does not refuse it.
out="$(play_rec true "$tier" "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" = 0 ] && expect_contains "library play: a native sample with no runner keys passes" "$out" "a native sample has no play_runner keys" || fail "library play: no runner keys failed: $out"
out="$(play_rec true "$tier,\"play_resolve_error\":{\"type\":\"s\",\"data\":\"This game's files are damaged\"}" "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: a refusal the sample should not have FAILs" "$out" "play_resolve_error for the sample: This game's files are damaged" || fail "library play: a resolve error passed"
out="$(play_rec true "$tier,\"play_runner\":{\"type\":\"s\",\"data\":\"wine 10.2\"}" "$plroot/icon-512.webp" | pj)"; rc=$?
[ "$rc" != 0 ] && expect_contains "library play: a runner on a native sample FAILs" "$out" "a native sample has a play_runner key" || fail "library play: a runner on a native sample passed"
grep -q 'judge_screenshots "\$1" "\$f" "\${2:-0}"' "$here/vm-library-check.sh" && grep -q 'play_judge "\$play_id" "\$shots" ""' "$here/vm-library-check.sh" && pass "vm-library-check.sh play judges the screenshots and the key id of the sample it installs (RUY-886)" || fail "vm-library-check.sh play: play_judge is not given the sample's screenshots"
# The missing-script FAIL names the full path it looked for (RUY-887).
nopc="$tmp/nopc"; mkdir -p "$nopc"; cp "$here/vm-library-check.sh" "$nopc/"; : > "$nopc/sample.zip"
out="$(PATH="$shims:$PATH" bash "$nopc/vm-library-check.sh" play "$nopc/sample.zip" 2>&1)"
expect_contains "library play: a missing vm-play-check.sh FAIL names its path" "$out" "FAIL: no $nopc/vm-play-check.sh: copy vm-play-check.sh next to this script"
[ "$(bash "$here/vm-library-check.sh" playid com.example.hello | head -n 1)" = com.example.hello_library ] && pass "vm-library-check.sh play installs under its own id <id>_library (RUY-877)" || fail "vm-library-check.sh playid: not <id>.library"
! grep -q 'm\["id"\] = ' "$here/vm-library-check.sh" && grep -q '"\$playcheck" withid' "$here/vm-library-check.sh" && pass "vm-library-check.sh has no copy of the id rewrite, it calls vm-play-check.sh withid (RUY-878)" || fail "vm-library-check.sh: its own id rewrite"
grep -q 'play_pkg_id "\$play_id"' "$here/vm-library-check.sh" && pass "vm-library-check.sh play installs under the id playid prints" || fail "vm-library-check.sh play does not use play_pkg_id"
n="$(grep -c 'with_id "\$zip"' "$here/vm-play-check.sh")"; m="$(grep 'with_id "\$zip"' "$here/vm-play-check.sh" | grep -c 'bad "with_id.*exit 1')"
[ "$n" = 4 ] && [ "$m" = 4 ] && pass "vm-play-check.sh: a failed with_id ends the mode with one FAIL (RUY-878)" || fail "vm-play-check.sh: with_id calls $n, ending the mode $m"
grep -q 'play_clean$' "$here/vm-library-check.sh" && grep -q 'rm -f "$play_state/incoming/vm-library-check.play.zip"' "$here/vm-library-check.sh" && pass "vm-library-check.sh play removes the sample and the incoming file" || fail "vm-library-check.sh play: no clean-up"

echo "== vm-play-check.sh: launch and launch-windows (RUY-902) =="
lp="$tmp/launch"; mkdir -p "$lp"
# RUY-1039: the sandbox probe of the library loads: LD_LIBRARY_PATH starts with the runner's library
# folder, each soname is tried in a child process, an abort or an error is a FAIL line and the others are
# still tried. The python3 shim fails libbad.so.1 (a non-zero exit, as an abort is) and records the path.
lps="$tmp/libprobe-shims"; mkdir -p "$lps"
cat > "$lps/python3" <<'SHIMEOF'
#!/bin/sh
echo "$LD_LIBRARY_PATH" > "$LP_SEEN"
[ "$4" = libbad.so.1 ] && { echo "OSError: version V_1.10.0 not found" >&2; kill -ABRT $$; }
exit 0
SHIMEOF
chmod +x "$lps/python3"
out="$(LP_SEEN="$lp/seen" LD_LIBRARY_PATH=/runtime PATH="$lps:$PATH" bash "$here/vm-play-check.sh" libprobe /app/runners/R "libgood.so.0 libbad.so.1 libother.so.2" 2>&1)"
[ "$out" = "ok libgood.so.0
FAIL libbad.so.1: OSError: version V_1.10.0 not found
ok libother.so.2" ] && pass "vm-play-check.sh libprobe: each library in its own child, an abort is a FAIL line and the next one is still tried" || fail "libprobe: '$out'"
[ "$(cat "$lp/seen")" = "/app/runners/R/files/lib/x86_64-linux-gnu:/runtime" ] && pass "vm-play-check.sh libprobe: the runner's x86_64-linux-gnu folder comes first in LD_LIBRARY_PATH" || fail "libprobe: LD_LIBRARY_PATH is '$(cat "$lp/seen")'"
# The signals of Session1 as `busctl --json=short monitor` prints them: one object per line, the arguments in
# payload.data. Two apps, two exits of the first, a line that is no JSON and a signal of another member.
cat > "$lp/signals.log" <<'EOF'
{"type":"signal","interface":"org.ruyaos.Session1","member":"AppStarted","payload":{"signature":"ss","data":["ruya-app-ruya-p1-play.a.service","play.a"]}}
Monitoring bus message stream.
{"type":"signal","interface":"org.ruyaos.Session1","member":"AppExited","payload":{"signature":"ssis","data":["ruya-app-ruya-p1-play.b.service","play.b",7,"crashed"]}}
{"type":"signal","interface":"org.ruyaos.Session1","member":"AppExited","payload":{"signature":"ssis","data":["ruya-app-ruya-p1-play.a.service","play.a",0,"quit"]}}
{"type":"signal","interface":"org.ruyaos.Session1","member":"FrozenChanged","payload":{"signature":"sb","data":["ruya-app-ruya-p1-play.a.service",true]}}
{"type":"signal","interface":"org.ruyaos.Session1","member":"AppExited","payload":{"signature":"ssis","data":["ruya-app-ruya-p1-play.a.service","play.a",139,"crashed"]}}
EOF
sg() { bash "$here/vm-play-check.sh" signals "$lp/signals.log" "$@" | tr -d '\r' | tr '\n' '|'; }
got="$(sg AppExited play.a)"
[ "$got" = "ruya-app-ruya-p1-play.a.service 0 quit|ruya-app-ruya-p1-play.a.service 139 crashed|" ] && pass "play launch: signals lists an app's exits in order with code and reason" || fail "play launch: signals read '$got'"
got="$(sg AppStarted play.a)"
[ "$got" = "ruya-app-ruya-p1-play.a.service|" ] && pass "play launch: signals reads AppStarted as the instance alone" || fail "play launch: AppStarted read '$got'"
got="$(sg AppExited play.c)"
[ -z "$got" ] && pass "play launch: another app's exits do not count" || fail "play launch: play.c read '$got'"
got="$(sg AppExited play.b)"
[ "$got" = "ruya-app-ruya-p1-play.b.service 7 crashed|" ] && pass "play launch: a crash reads as its code and reason" || fail "play launch: play.b read '$got'"

# winpkg: the Windows sample's copy changes the id, the command and multiarch, nothing else.
python3 - "$lp/in.zip" <<'PY'
import json, sys, zipfile
m = {"id": "org.example.helloplaywine", "name": {"en": "Hello"}, "components": [{"id": "proton", "type": "proton"}],
     "run": {"runner": "proton", "component": "proton", "command": ["${game}/Program/hello.exe"], "cwd": "${game}/Program",
             "writable": ["Program"], "setup": [{"id": "first-run", "command": ["${game}/Program/setup.exe"], "once": True}]},
     "permissions": {"network": False, "input": "controllers+keyboard-mouse"}}
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("play.json", json.dumps(m))
    z.writestr("payload/Program/check.exe", b"MZ")
PY
bash "$here/vm-play-check.sh" winpkg "$lp/in.zip" "$lp/out.zip" org.example.helloplaywine_launchwindows
got="$(python3 -c '
import json, sys, zipfile
a, b = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
m = json.loads(b.read("play.json"))
print(m["id"], m["run"]["command"], m["run"]["cwd"], m["run"]["runner"], m["run"]["setup"][0]["id"], m["permissions"],
      a.read("payload/Program/check.exe") == b.read("payload/Program/check.exe"), a.namelist() == b.namelist())
' "$lp/in.zip" "$lp/out.zip")"
[ "$got" = "org.example.helloplaywine_launchwindows ['\${game}/Program/check.exe'] \${game}/Program proton first-run {'network': False, 'input': 'controllers+keyboard-mouse', 'multiarch': True} True True" ] \
    && pass "vm-play-check.sh winpkg: the id, the command and multiarch change, the rest of the manifest and the files stay" || fail "vm-play-check.sh winpkg: '$got'"
# The sample the copy is made from: a Proton component from the OS, and check.exe is what its build produces.
sw="$here/../samples/hello-play-wine"
got="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
c = m["components"][0]
print(c["type"], c["source"], m["run"]["runner"], m["run"]["component"] == c["id"], m["permissions"].get("network"), "multiarch" in m["permissions"])
' "$sw/package/play.json")"
[ "$got" = "proton system proton True False False" ] && pass "samples/hello-play-wine: type proton, source system, no network and no multiarch of its own (RUY-902)" || fail "samples/hello-play-wine/package/play.json: '$got'"
grep -q '^bin="\$payload/Program"$' "$sw/build.sh" && grep -q '"\$bin/check.exe"' "$sw/build.sh" && grep -q '"\${game}/Program/check.exe"' "$here/vm-play-check.sh" && pass "vm-play-check.sh launch-windows runs the check.exe that build.sh compiles into Program/" || fail "launch-windows and build.sh disagree on check.exe"
# RUY-1019: the sample's programs are in its writable folder, check.exe reads check.ini and writes beside.txt there.
got="$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))["run"]
print(r["writable"], r["command"][0], r["cwd"])
' "$sw/package/play.json")"
[ "$got" = "['Program'] \${game}/Program/hello.exe \${game}/Program" ] && grep -q "echo 'edition=1' > \"\$bin/check.ini\"" "$sw/build.sh" && grep -q 'L"check.ini"' "$sw/src/check.c" && grep -q 'L"beside.txt"' "$sw/src/check.c" && grep -q 'Program/check.ini' "$here/vm-play-check.sh" && grep -q 'game/Program/beside.txt' "$here/vm-play-check.sh" \
    && pass "samples/hello-play-wine: Program/ is writable, build.sh ships check.ini there, check.c reads it and writes beside.txt, launch-windows looks there (RUY-1019)" || fail "samples/hello-play-wine writable layout: '$got'"
# check.txt: the keys the check reads are the ones check.c writes, in the folder data.saves keeps.
keys_ok=1
for key in launches pointer_bits wow64 network module edition beside; do
    grep -q "$key=" "$sw/src/check.c" && grep -q "$key=" "$here/vm-play-check.sh" || keys_ok=0
done
[ "$keys_ok" = 1 ] && pass "check.c writes the keys launch-windows reads from check.txt (launches, pointer_bits, wow64, network, module, edition, beside)" || fail "check.c and vm-play-check.sh disagree on the keys of check.txt"
grep -q 'Hello Play' "$sw/src/check.c" && grep -q 'check.txt' "$sw/src/check.c" && grep -q 'Documents/Hello Play/check.txt' "$here/vm-play-check.sh" && grep -q 'prefix:drive_c/users/steamuser/Documents/Hello Play' "$sw/package/play.json" && pass "check.txt is in the folder data.saves keeps, where launch-windows looks (RUY-902)" || fail "check.txt: the path of check.c, play.json and vm-play-check.sh differ"
grep -q 'drive_c/users/steamuser/Documents/Hello Play/check.txt' "$here/vm-play-check.sh" && grep -q 'proton/pfx' "$here/vm-play-check.sh" && pass "launch-windows reads check.txt in the Proton prefix (<data>/proton/pfx, 05 section 6.2.1)" || fail "launch-windows looks outside the Proton prefix"
# kv on a check.txt as check.exe writes it, CR LF (RUY-999): the values without the CR. The script's own kv,
# with sed in binary mode: Git Bash's sed drops CR itself (text mode), Linux's keeps it, as on the VM. Its bytes
# are compared through od, because Git Bash's $(...) drops a trailing CR too.
eval "$(grep '^kv() {' "$here/vm-play-check.sh")"
sed() { command sed -b "$@"; }
kv_bytes() { kv "$@" | od -An -c | tr -d ' \n'; }
printf 'launches=1\r\npointer_bits=32\r\nwow64=1\r\n' > "$tmp/check-crlf.txt"
[ "$(kv_bytes "$tmp/check-crlf.txt" launches)" = '1\n' ] && [ "$(kv_bytes "$tmp/check-crlf.txt" pointer_bits)" = '32\n' ] && [ -z "$(kv_bytes "$tmp/check-crlf.txt" network)" ] && pass "vm-play-check.sh kv reads a CR LF check.txt (launches=1, pointer_bits=32, no network key)" || fail "vm-play-check.sh kv on CR LF: launches is '$(kv_bytes "$tmp/check-crlf.txt" launches)', want '1\n'"
unset -f kv sed kv_bytes

# modpath (RUY-1019): check.exe's module= line as the Unix path Wine maps Z: to.
printf 'launches=1\r\nmodule=Z:\\var\\home\\ruya-p1\\.var\\app\\play.a\\data\\.ruya-play\\game\\Program\\check.exe\r\nedition=1\r\n' > "$tmp/check-mod.txt"
got="$(bash "$here/vm-play-check.sh" modpath "$tmp/check-mod.txt" | tr -d '\r')"
[ "$got" = "/var/home/ruya-p1/.var/app/play.a/data/.ruya-play/game/Program/check.exe" ] && pass "vm-play-check.sh modpath: Z:\\a\\b is /a/b (CR LF dropped)" || fail "vm-play-check.sh modpath: '$got'"
printf 'module=z:\\x\\y.exe\n' > "$tmp/check-mod-lower.txt"
[ "$(bash "$here/vm-play-check.sh" modpath "$tmp/check-mod-lower.txt" | tr -d '\r')" = "/x/y.exe" ] && pass "vm-play-check.sh modpath: a lower-case z: too" || fail "vm-play-check.sh modpath: lower-case z: '$(bash "$here/vm-play-check.sh" modpath "$tmp/check-mod-lower.txt")'"
printf 'module=C:\\Program Files\\x.exe\n' > "$tmp/check-mod-c.txt"
printf 'launches=1\n' > "$tmp/check-mod-none.txt"
for f in check-mod-c check-mod-none missing; do
    if out="$(bash "$here/vm-play-check.sh" modpath "$tmp/$f.txt")" || [ -n "$out" ]; then fail "vm-play-check.sh modpath $f: '$out', want nothing and status 1"; else pass "vm-play-check.sh modpath: $f is no path in the tree (status 1)"; fi
done
# The pattern launch-windows matches the path against: the tree's Program/check.exe of this app only.
eval "$(sed -n '/^launch_windows_checks() {/,/^}/p' "$here/vm-play-check.sh" | grep -m1 -A3 'case "\$module" in' | sed -n '2s/^ *\([^)]*\)).*/mp_pat() { case "$1" in \1) return 0 ;; esac; return 1; }/p')"
app=play.a
mp_pat "/var/home/ruya-p1/.var/app/play.a/data/.ruya-play/game/Program/check.exe" && pass "launch-windows takes a module path in \${game}/Program" || fail "launch-windows refuses the module path in \${game}/Program"
mp_pat "/var/home/ruya-p1/.var/app/play.a/data/.ruya-play/game.new/Program/check.exe" && fail "launch-windows takes a path outside the tree" || pass "launch-windows refuses a path outside \${game} (game.new)"
mp_pat "/app/payload/Program/check.exe" && fail "launch-windows takes the read-only original" || pass "launch-windows refuses /app/payload (the original, not the tree)"
mp_pat "/var/home/ruya-p1/.var/app/play.b/data/.ruya-play/game/Program/check.exe" && fail "launch-windows takes another app's tree" || pass "launch-windows refuses another app's tree"
unset -f mp_pat; unset app

# bumpbuild (RUY-1019): the next build of a package with one payload file changed and its table line updated.
python3 - "$lp/bb-in.zip" <<'PY'
import hashlib, json, sys, zipfile
files = {"payload/Program/check.exe": b"MZ", "payload/Program/check.ini": b"edition=1\n", "payload/x\u00e9.txt": b"e"}
table = "".join(json.dumps({"h": hashlib.sha256(d).hexdigest(), "p": p, "s": len(d), "t": "f"}, separators=(",", ":"), ensure_ascii=False) + "\n" for p, d in sorted(files.items()))
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("play.json", json.dumps({"id": "a.b", "build": 4}))
    z.writestr("play.files", table)
    for p, d in files.items():
        z.writestr(p, d)
PY
got="$(bash "$here/vm-play-check.sh" bumpbuild "$lp/bb-in.zip" "$lp/bb-out.zip" Program/check.ini 'edition=2' | tr -d '\r')"
[ "$got" = 5 ] && pass "vm-play-check.sh bumpbuild prints the next build (5)" || fail "vm-play-check.sh bumpbuild printed '$got'"
got="$(python3 -c '
import hashlib, json, sys, zipfile
a, b = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
lines = {json.loads(l)["p"]: json.loads(l) for l in b.read("play.files").decode("utf-8").splitlines()}
ini = b.read("payload/Program/check.ini")
e = lines["payload/Program/check.ini"]
same = [p for p in ("payload/Program/check.exe", "payload/x\u00e9.txt") if b.read(p) == a.read(p) and lines[p]["h"] == hashlib.sha256(a.read(p)).hexdigest()]
print(json.loads(b.read("play.json"))["build"], ini.decode(), e["s"] == len(ini), e["h"] == hashlib.sha256(ini).hexdigest(), len(same), a.namelist() == b.namelist(), "\\u" not in b.read("play.files").decode("utf-8"))
' "$lp/bb-in.zip" "$lp/bb-out.zip")"
[ "$got" = "5 edition=2 True True 2 True True" ] && pass "vm-play-check.sh bumpbuild: build+1, the file and its table line (size, SHA-256) changed, the other files and lines as they were" || fail "vm-play-check.sh bumpbuild: '$got'"
bash "$here/vm-play-check.sh" bumpbuild "$lp/bb-in.zip" "$lp/bb-none.zip" Program/none.ini x >/dev/null 2>&1 && fail "vm-play-check.sh bumpbuild accepts a file the package lacks" || pass "vm-play-check.sh bumpbuild refuses a file the package lacks"

# lstate: the launcher's status file (05 section 6.3).
echo '{"format":1,"epoch":1,"backup_of":null,"setup_done":["first-run"],"setup_failed":null,"runner":{"component":"proton","family":"proton-ge","version":"GE-Proton11-12","source":"system","hash":null}}' > "$lp/state-win.json"
echo '{"format":1,"epoch":0,"backup_of":null,"setup_done":[],"setup_failed":null,"runner":null}' > "$lp/state-native.json"
echo 'not json' > "$lp/state-bad.json"
echo '{"format":1,"epoch":1,"backup_of":null,"setup_done":["first-run"],"setup_failed":null,"runner":{"component":"proton","family":"proton-ge","version":"GE-Proton11-12","source":"system","hash":null},"game_build":2}' > "$lp/state-game.json"
ls_() { bash "$here/vm-play-check.sh" lstate "$1" | tr -d '\r'; }
[ "$(ls_ "$lp/state-game.json")" = "epoch=1 setup_done=first-run runner=system/proton-ge/GE-Proton11-12 game=2" ] && pass "vm-play-check.sh lstate: the build of the game tree (game_build, RUY-1019)" || fail "lstate (game tree): '$(ls_ "$lp/state-game.json")'"
[ "$(ls_ "$lp/state-win.json")" = "epoch=1 setup_done=first-run runner=system/proton-ge/GE-Proton11-12" ] && pass "vm-play-check.sh lstate: a system-runner launch" || fail "lstate (windows): '$(ls_ "$lp/state-win.json")'"
[ "$(ls_ "$lp/state-native.json")" = "epoch=0 setup_done= runner=none" ] && pass "vm-play-check.sh lstate: a native game has no runner" || fail "lstate (native): '$(ls_ "$lp/state-native.json")'"
case "$(ls_ "$lp/state-bad.json")" in unreadable:*) pass "vm-play-check.sh lstate: a damaged file is unreadable, not empty" ;; *) fail "lstate (bad): '$(ls_ "$lp/state-bad.json")'" ;; esac
case "$(ls_ "$lp/missing.json")" in unreadable:*) pass "vm-play-check.sh lstate: a missing file is unreadable" ;; *) fail "lstate (missing): '$(ls_ "$lp/missing.json")'" ;; esac

# newest (vm-runner-check.sh): the newest runner of a kind or family by the numbers in the version
# (GE-Proton10-9 is below GE-Proton11-12), the one rule steam and vm-play-check.sh's sysrunner share.
mkdir -p "$lp/runners/ProtonGE10" "$lp/runners/ProtonGE11" "$lp/runners/WineStable" "$lp/runners/Broken"
echo '{"family":"proton-ge","kind":"proton","version":"GE-Proton10-9"}' > "$lp/runners/ProtonGE10/runner.json"
echo '{"family":"proton-ge","kind":"proton","version":"GE-Proton11-12"}' > "$lp/runners/ProtonGE11/runner.json"
echo '{"family":"wine","kind":"wine","version":"99.0"}' > "$lp/runners/WineStable/runner.json"
echo '{' > "$lp/runners/Broken/runner.json"
nw() { bash "$here/vm-runner-check.sh" newest "$@" | tr -d '\r'; }
[ "$(nw "$lp/runners" family=proton-ge)" = ProtonGE11 ] && pass "vm-runner-check.sh newest family=proton-ge: the highest version, not a wine runner or a broken file" || fail "newest family=proton-ge: '$(nw "$lp/runners" family=proton-ge)'"
[ "$(nw "$lp/runners" kind=wine)" = WineStable ] && pass "vm-runner-check.sh newest kind=wine picks by the key it is given" || fail "newest kind=wine: '$(nw "$lp/runners" kind=wine)'"
[ "$(nw "$lp/runners" kind=proton)" = ProtonGE11 ] && pass "vm-runner-check.sh newest kind=proton is the runner steam wants" || fail "newest kind=proton: '$(nw "$lp/runners" kind=proton)'"
bash "$here/vm-runner-check.sh" newest "$lp/runners" family=nobody >/dev/null 2>&1 && fail "newest: a family without a runner passed" || pass "vm-runner-check.sh newest: no runner of the family is a failure"
! grep -q 'findall' "$here/vm-play-check.sh" && grep -q 'newest "\$1" family=proton-ge' "$here/vm-play-check.sh" && [ "$(grep -c 'findall' "$here/vm-runner-check.sh")" = 1 ] && pass "the newest-runner rule is in vm-runner-check.sh only; vm-play-check.sh and steam ask for it" || fail "the newest-runner rule is written twice"
grep -q 'newest_runner "\$play/runners" kind=proton' "$here/vm-runner-check.sh" && pass "vm-runner-check.sh steam asks newest_runner for its runner" || fail "vm-runner-check.sh steam has its own newest block"

# sysrunner: "<family>/<version>" of that newest proton-ge, through vm-runner-check.sh next to the script.
got="$(bash "$here/vm-play-check.sh" sysrunner "$lp/runners" | tr -d '\r')"
[ "$got" = "proton-ge/GE-Proton11-12" ] && pass "vm-play-check.sh sysrunner: the newest proton-ge as <family>/<version>" || fail "sysrunner: '$got'"
mkdir -p "$lp/none/WineStable"; echo '{"family":"wine","version":"9.0"}' > "$lp/none/WineStable/runner.json"
bash "$here/vm-play-check.sh" sysrunner "$lp/none" >/dev/null 2>&1 && fail "sysrunner: a tree without proton-ge passed" || pass "vm-play-check.sh sysrunner: no proton-ge runner is a failure"
# compat32 (RUY-1006): the Compat.i386 ref of the app's runtime, asked of flatpak; a missing one fails and is named.
cs="$lp/cshim"; mkdir -p "$cs"
cat > "$cs/flatpak" <<'SHIMEOF'
#!/bin/sh
# flatpak info --system --show-runtime <app> | flatpak info --system <ref>
[ "$3" = --show-runtime ] && { echo org.freedesktop.Platform/x86_64/24.08; exit 0; }
[ "$3" = "org.freedesktop.Platform.Compat.i386/x86_64/24.08" ] && [ -z "${FAKE_NO_COMPAT:-}" ] && exit 0
exit 1
SHIMEOF
chmod +x "$cs/flatpak"
got="$(PATH="$cs:$PATH" bash "$here/vm-play-check.sh" compat32 play.x)"; rc=$?
[ "$rc" = 0 ] && [ "$got" = "org.freedesktop.Platform.Compat.i386/x86_64/24.08" ] && pass "vm-play-check.sh compat32: the runtime's Compat.i386 ref, installed" || fail "compat32: rc $rc, '$got'"
got="$(FAKE_NO_COMPAT=1 PATH="$cs:$PATH" bash "$here/vm-play-check.sh" compat32 play.x)"; rc=$?
[ "$rc" = 1 ] && [ "$got" = "org.freedesktop.Platform.Compat.i386/x86_64/24.08" ] && pass "vm-play-check.sh compat32: a missing Compat.i386 fails and names the ref" || fail "compat32 missing: rc $rc, '$got'"
lw="$(sed -n '/^launch_windows_checks() {/,/^}/p' "$here/vm-play-check.sh")"
echo "$lw" | grep -q '^    module_check ruya_play_runners$' && echo "$lw" | grep -q "has no 32-bit loader: .*(Compat.i386)" && pass "vm-play-check.sh launch-windows checks ruya_play_runners and the 32-bit loader" || fail "vm-play-check.sh launch-windows: no ruya_play_runners or Compat.i386 check"
grep -q '^    module_check ruya_play_openfile$' "$here/vm-play-check.sh" && pass "vm-play-check.sh: avc_checks still needs ruya_play_openfile" || fail "vm-play-check.sh: avc_checks lost ruya_play_openfile"
mkdir -p "$lp/alone"; cp "$here/vm-play-check.sh" "$lp/alone/"
out="$(bash "$lp/alone/vm-play-check.sh" sysrunner "$lp/runners" 2>&1)"; rc=$?
[ "$rc" = 1 ] && expect_contains "vm-play-check.sh sysrunner without vm-runner-check.sh next to it says so" "$out" "copy vm-runner-check.sh next to this script" || fail "sysrunner alone: exit $rc, $out"

# offline: a fake `ip` with a route table per family. on takes every default route away and keeps it; off puts
# the same routes back. The fake fails on request: FAKE_DEL_FAIL="<families>" refuses `route del` for them,
# FAKE_REPLACE_FAIL=<text> refuses a `route replace` whose route contains the text. replace is idempotent.
ipsh="$tmp/ip-shims"; mkdir -p "$ipsh" "$lp/off"
cat > "$ipsh/ip" <<'IPEOF'
#!/bin/sh
fam=$1; shift
[ "$1" = route ] || exit 2
shift
t="$IP_TABLE$fam"; touch "$t"
case "$1" in
    show) cat "$t" ;;
    del) case " ${FAKE_DEL_FAIL:-} " in *" $fam "*) exit 2 ;; esac; sed -i '1d' "$t" ;;
    replace)
        shift
        case "$*" in *"${FAKE_REPLACE_FAIL:-@none@}"*) exit 2 ;; esac
        { grep -vxF -- "$*" "$t" || true; } > "$t.new"; mv "$t.new" "$t"; echo "$*" >> "$t" ;;
esac
IPEOF
chmod +x "$ipsh/ip"
off() { IP_TABLE="$lp/table" PATH="$ipsh:$PATH" bash "$here/vm-play-check.sh" offline "$@"; }
reset_routes() {
    printf 'default via 10.0.2.2 dev eth0 proto dhcp metric 100\ndefault via 10.0.2.3 dev eth0 proto dhcp metric 200\n' > "$lp/table-4"
    printf 'default via fe80::2 dev eth0 proto ra metric 1024\n' > "$lp/table-6"
    rm -f "$lp/off"/routes-*
}
reset_routes
cp "$lp/table-4" "$lp/want-4"; cp "$lp/table-6" "$lp/want-6"
off on "$lp/off"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$lp/table-4" ] && [ ! -s "$lp/table-6" ] && pass "vm-play-check.sh offline on: every default route, IPv4 and IPv6, is gone" || fail "offline on: rc $rc, left: $(cat "$lp/table-4" "$lp/table-6")"
off off "$lp/off"; rc=$?
[ "$rc" = 0 ] && cmp -s "$lp/table-4" "$lp/want-4" && cmp -s "$lp/table-6" "$lp/want-6" && pass "vm-play-check.sh offline off: the routes are back as they were" || fail "offline off: rc $rc, have: $(cat "$lp/table-4" "$lp/table-6")"
[ ! -e "$lp/off/routes-4" ] && [ ! -e "$lp/off/routes-6" ] && pass "vm-play-check.sh offline off: the saved routes are removed, a second off adds nothing" || fail "offline off kept its saved routes"
# A step the caller must be able to undo: IPv6 cannot be deleted while IPv4 is gone already.
reset_routes
FAKE_DEL_FAIL="-6" off on "$lp/off" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$lp/table-4" ] && pass "vm-play-check.sh offline on: a route that cannot be deleted fails the step after IPv4 is gone" || fail "offline on (IPv6 fails): rc $rc, IPv4 left: $(cat "$lp/table-4")"
off off "$lp/off"; rc=$?
[ "$rc" = 0 ] && cmp -s "$lp/table-4" "$lp/want-4" && cmp -s "$lp/table-6" "$lp/want-6" && pass "vm-play-check.sh offline off after a half-done on: both families are back, no route twice" || fail "offline off after a half-done on: rc $rc, have: $(cat "$lp/table-4" "$lp/table-6")"
# A restore line that fails does not stop the others, and the retry finishes it.
reset_routes
off on "$lp/off"
FAKE_REPLACE_FAIL=10.0.2.2 off off "$lp/off" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$lp/table-4")" = "$(sed -n 2p "$lp/want-4")" ] && cmp -s "$lp/table-6" "$lp/want-6" && pass "vm-play-check.sh offline off: a route that fails does not stop the others, IPv6 is back, rc 1" || fail "offline off (one route fails): rc $rc, have: $(cat "$lp/table-4" "$lp/table-6")"
[ -s "$lp/off/routes-4" ] && [ ! -e "$lp/off/routes-6" ] && pass "vm-play-check.sh offline off: a family with a route left keeps its saved file, a restored one loses it" || fail "offline off (one route fails): saved files $(ls "$lp/off")"
off off "$lp/off"; rc=$?
[ "$rc" = 0 ] && [ "$(sort "$lp/table-4")" = "$(sort "$lp/want-4")" ] && [ ! -e "$lp/off/routes-4" ] && pass "vm-play-check.sh offline off: the retry (the cleanup's) puts the last route back without an error for the one already there" || fail "offline off retry: rc $rc, have: $(cat "$lp/table-4")"
rm -f "$lp/off"/routes-*

# The modes in the script: own ids through pkg_id (they differ from every other mode's), the cleanup, the calls
# against Session1.xml and the profile code the other checks use.
ids="$(grep -o 'launch_run [a-z]* [a-z_]* [a-z_]*' "$here/vm-play-check.sh" | sort | tr '\n' ',')"
[ "$ids" = "launch_run launch with_id launch_checks,launch_run launchwindows windows_pkg launch_windows_checks," ] && pass "vm-play-check.sh: launch and launch-windows install under their own ids (launch, launchwindows)" || fail "vm-play-check.sh launch ids: '$ids'"
grep -q 'appid="\$(pkg_id "\$appid" "\$part")"' "$here/vm-play-check.sh" && pass "vm-play-check.sh: launch_run takes its id through pkg_id (RUY-887)" || fail "vm-play-check.sh: launch_run builds its id without pkg_id"
[ "$(grep -c '^    launch_cleanup$' "$here/vm-play-check.sh")" = 1 ] && [ "$(sed -n '/^cleanup() {/{n;p}' "$here/vm-play-check.sh")" = "    launch_cleanup" ] && pass "vm-play-check.sh: the cleanup stops the launch and gives the routes back before it uninstalls" || fail "vm-play-check.sh: cleanup does not start with launch_cleanup"
grep -A4 'name="Launch"' "$here/../api/dbus/org.ruyaos.Session1.xml" | grep -c 'type="s" direction="in"' | grep -qx 2 && grep -q 'Launch ss "\$1" "\$lprof"' "$here/vm-play-check.sh" && grep -q 'Stop s "\$linst"' "$here/vm-play-check.sh" && pass "vm-play-check.sh calls Session1.Launch as (ss) and Stop as (s), the signatures of Session1.xml" || fail "vm-play-check.sh: its Launch/Stop calls do not match Session1.xml"
grep -A5 'signal name="AppExited"' "$here/../api/dbus/org.ruyaos.Session1.xml" | tr -d '\n' | grep -q 'instance.*app_id.*exit_code.*reason' && pass "vm-play-check.sh signals: AppExited carries instance, app id, exit code, reason in that order (Session1.xml)" || fail "Session1.xml: AppExited arguments changed; signals reads data[2:] as code and reason"
grep -q 'CreateProfile sssss "" "" "Check Admin" admin 1234' "$here/vm-play-check.sh" && grep -q 'DeleteProfile sss "\$ladmin" 1234 "\$lcreated"' "$here/vm-play-check.sh" && grep -q 'SwitchTo ss' "$here/vm-play-check.sh" && pass "vm-play-check.sh makes, signs in and deletes a profile with the calls vm-sample-check.sh and vm-x11-check.sh use" || fail "vm-play-check.sh: the profile calls differ from the other checks'"
# sign_in (RUY-1017): no PIN, then RUYA_PIN, then 1234. A busctl shim accepts one PIN (SI_OK) and logs its calls.
si="$tmp/signin"; mkdir -p "$si"
cat > "$si/busctl" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >> "$SI_LOG"
if [ "${*: -1}" = "$SI_OK" ]; then echo 'suu "ok" 0 0'; else echo 'suu "wrong-pin" 0 0'; fi
EOF
chmod +x "$si/busctl"
si_run() {  # <accepted pin> <RUYA_PIN or "-">; prints the PINs tried, comma separated, then the exit code
    : > "$si/log"
    ( [ "$2" = "-" ] || export RUYA_PIN="$2"
      export SI_LOG="$si/log" SI_OK="$1" PATH="$si:$PATH"
      eval "psvc=s ppath=/p; $(sed -n '/^sign_in() {/,/^}/p' "$here/vm-play-check.sh")"
      sign_in p1 >"$si/out" 2>&1; echo "rc=$?" >>"$si/out" )
    echo "$(tr '\n' ',' < "$si/log")$(tail -1 "$si/out")"
}
[ "$(si_run "" -)" = ",rc=0" ] && pass "sign_in: a profile without a PIN signs in with no PIN, nothing else tried" || fail "sign_in no PIN: '$(si_run "" -)'"
[ "$(si_run 4321 4321)" = ",4321,rc=0" ] && pass "sign_in: RUYA_PIN is tried second" || fail "sign_in RUYA_PIN: '$(si_run 4321 4321)'"
[ "$(si_run 1234 4321)" = ",4321,1234,rc=0" ] && pass "sign_in: 1234 is the last fallback, after RUYA_PIN" || fail "sign_in 1234 after RUYA_PIN: '$(si_run 1234 4321)'"
[ "$(si_run 1234 -)" = ",1234,rc=0" ] && pass "sign_in: 1234 without RUYA_PIN" || fail "sign_in 1234: '$(si_run 1234 -)'"
si_run 9999 4321 >/dev/null; ! grep -q 4321 "$si/out" && grep -q 'wrong-pin' "$si/out" && pass "sign_in: a failure prints busctl's reply, never the PIN" || fail "sign_in: failure output '$(cat "$si/out")'"
lr="$(sed -n '/^launch_checks() {/,/^launch_run() {/p' "$here/vm-play-check.sh")"
[ "$(echo "$lr" | grep -c '^    sigsys_checks$')" = 2 ] && [ "$(echo "$lr" | grep -c '^    avc_checks$')" = 2 ] && pass "vm-play-check.sh: both launch modes end with the init_t AVC and the SIGSYS journal checks" || fail "vm-play-check.sh: a launch mode skips the journal checks"
[ "$(grep -c 'offline on "\$work"' "$here/vm-play-check.sh")" = 1 ] && [ "$(grep -B2 'offline on "\$work"' "$here/vm-play-check.sh" | grep -c '^    lrouted=1$')" = 1 ] && [ "$(grep -c 'offline off "\$work"' "$here/vm-play-check.sh")" = 2 ] && pass "vm-play-check.sh launch-windows sets its routes flag before it takes the routes away, once, and gives them back (after the launches and in the cleanup)" || fail "vm-play-check.sh: the offline calls changed"
out="$(sed -n '/^if \[ "\$mode" = launch-windows \]/,/^fi$/p' "$here/vm-play-check.sh")"; expect_contains "vm-play-check.sh launch-windows is its own mode" "$out" "launch_run launchwindows windows_pkg launch_windows_checks"
grep -q 'zip=/root/hello-play-wine.play.zip' "$here/vm-play-check.sh" && pass "vm-play-check.sh launch-windows defaults to the Windows sample's zip" || fail "vm-play-check.sh: launch-windows has no default zip"

echo "== vm-library-check.sh runners: Library1 ListRunners and the runner choice (RUY-959) =="
rj() { printf '%s' "$1" | bash "$here/vm-library-check.sh" runnersjudge 2>&1; }
ge='{"type":"s","data":"proton-ge"}'
good='{"type":"aa{sv}","data":[[{"family":'"$ge"',"kind":{"type":"s","data":"proton"},"version":{"type":"s","data":"GE-Proton11-12"},"licence":{"type":"s","data":"BSD-3-Clause"}},{"family":{"type":"s","data":"wine"},"kind":{"type":"s","data":"wine"},"version":{"type":"s","data":"10.0"}}]]}'
out="$(rj "$good")"; rc=$?
[ "$rc" = 0 ] && expect_contains "runners: GE-Proton and Wine pass" "$out" "PASS: the image's GE-Proton is listed" || fail "runners: a good listing: exit $rc, $out"
expect_contains "runners: the count is printed" "$out" "ListRunners lists 2 runner(s)"
out="$(rj '{"type":"aa{sv}","data":[[{"family":{"type":"s","data":"wine"},"kind":{"type":"s","data":"wine"},"version":{"type":"s","data":"10.0"}}]]}')"; rc=$?
[ "$rc" = 1 ] && expect_contains "runners: no GE-Proton FAILs" "$out" "FAIL: no proton-ge runner" || fail "runners: no GE-Proton: exit $rc, $out"
out="$(rj '{"type":"aa{sv}","data":[[]]}')"; rc=$?
[ "$rc" = 1 ] && expect_contains "runners: an empty list FAILs" "$out" "FAIL: ListRunners lists no runner" || fail "runners: empty: exit $rc, $out"
out="$(rj '{"type":"aa{sv}","data":[[{"family":'"$ge"',"kind":{"type":"s","data":"proton"},"version":{"type":"s","data":"GE-Proton11-12"}},{"family":{"type":"s","data":"wine"},"kind":{"type":"s","data":"wine"}}]]}')"; rc=$?
[ "$rc" = 1 ] && expect_contains "runners: a runner without a version FAILs" "$out" "FAIL: a runner without a family, kind or version" || fail "runners: no version: exit $rc, $out"
grep -q 'systemctl restart ruya-library' "$here/vm-library-check.sh" && grep -q 'set_choice "$prof" "$id" system' "$here/vm-library-check.sh" && grep -q 'play_install "$1" || return' "$here/vm-library-check.sh" && pass "vm-library-check.sh runners stores a choice for the installed sample and restarts the service" || fail "vm-library-check.sh runners: no choice across a restart"
grep -q 'StateDirectory=ruyaos/library' "$here/../image/rootfs/usr/lib/systemd/system/ruya-library.service" && grep -q 'file=/var/lib/ruyaos/library/' "$here/vm-library-check.sh" && pass "the choice file the check looks at is the unit's StateDirectory" || fail "ruya-library.service StateDirectory and vm-library-check.sh runners disagree"

echo "== .play VM files (RUY-860) =="
# lib-samples.sh's clean-up removes the build outputs of the named samples only, and
# scripts/ci-samples-linux.sh and scripts/play-vm-files.sh both use it (no second copy).
source "$here/lib-samples.sh"
root="$tmp/samples-root"
for s in hello-play-native hello-play-wine; do
    mkdir -p "$root/samples/$s/package/payload"
    touch "$root/samples/$s/package/play.json" "$root/samples/$s/package/play.files" "$root/samples/$s/package/play.sig" "$root/samples/$s/$s.play.zip" "$root/samples/$s/package/payload/game"
done
samples_clean_outputs "$root" hello-play-native
left="$(cd "$root" && find samples -type f | sort | tr '\n' ' ')"
expect_contains "samples_clean_outputs: the named sample keeps its sources" "$left" "samples/hello-play-native/package/play.json"
[ "$(cd "$root" && find samples/hello-play-native -type f | wc -l)" = 1 ] && pass "samples_clean_outputs: payload, play.files, play.sig and the zip of the named sample are gone" || fail "samples_clean_outputs: left $left"
expect_contains "samples_clean_outputs: another sample is untouched" "$left" "samples/hello-play-wine/hello-play-wine.play.zip"
[ "$(grep -c 'samples_clean_outputs' "$here/ci-samples-linux.sh" "$here/play-vm-files.sh" | tr '\n' ' ')" = "$here/ci-samples-linux.sh:1 $here/play-vm-files.sh:1 " ] && pass "ci-samples-linux.sh and play-vm-files.sh share samples_clean_outputs" || fail "the sample clean-up is not shared"
! grep -q 'rm -rf "\$p/package' "$here/ci-samples-linux.sh" "$here/play-vm-files.sh" && pass "no copy of the sample clean-up outside lib-samples.sh" || fail "a copy of the sample clean-up"
grep -q 'trap .samples_clean_outputs' "$here/play-vm-files.sh" && grep -q 'output/play-vm' "$here/play-vm-files.sh" && pass "play-vm-files.sh cleans up on exit and writes output/play-vm" || fail "play-vm-files.sh: no clean-up trap or wrong folder"

echo "== vm-runner-check.sh: the Play platform on /usr (RUY-34) =="
# A fake image under $rr: the real tmpfiles file, a launcher, one Proton and one Wine runner, ruya-pack and
# readlink fakes.
rr="$tmp/runner-root"; rsh="$tmp/runner-shims"; mkdir -p "$rsh" "$rr/usr/lib/tmpfiles.d" "$rr/var/tmp"
cp "$here/../image/rootfs/usr/lib/tmpfiles.d/ruya-play-platform.conf" "$rr/usr/lib/tmpfiles.d/"
rp="$rr/usr/lib/ruyaos/play"; rt="$rp/runners/ProtonGE11"
mkdir -p "$rp/launcher/bin" "$rt/files/lib/wine/x86_64-windows"
cat > "$rp/launcher/bin/ruya-play-launch" <<'SHIMEOF'
#!/bin/sh
echo "ruya-play-launch: ${FAKE_LAUNCH_SAYS:-This game's play.files cannot be read (no file); reinstall it. [package.read_failed]}" >&2
exit 1
SHIMEOF
chmod +x "$rp/launcher/bin/ruya-play-launch"
hash_ok="$(printf 'ab%.0s' $(seq 32))"
printf '%s\n' "$hash_ok" > "$rt/.ruya-runner-hash"
# The Wine runner (RUY-37): its runner.json names the loader; bin/wine prints the words after /c echo
# (CR LF) of a 64- or 32-bit cmd.exe that is there when WINEPREFIX is set, nothing when "silent" is in
# the runner's folder.
rw="$rp/runners/Wine11"
mkdir -p "$rw/bin" "$rw/lib/wine/x86_64-windows" "$rw/lib/wine/i386-windows"
: > "$rw/lib/wine/x86_64-windows/cmd.exe"; : > "$rw/lib/wine/i386-windows/cmd.exe"
printf '{"format": 1, "family": "wine", "kind": "wine", "version": "wine-11.0", "arch": "x86_64",\n "entry": {"wine": "bin/wine", "wineserver": "bin/wineserver"}}\n' > "$rw/runner.json"
printf '%s\n' "$hash_ok" > "$rw/.ruya-runner-hash"
cat > "$rw/bin/wine" <<'SHIMEOF'
#!/bin/sh
[ -e "$(dirname "$0")/../silent" ] && exit 0
[ -n "$WINEPREFIX" ] && [ -f "$1" ] || exit 3
case "$1" in */x86_64-windows/cmd.exe | */i386-windows/cmd.exe) ;; *) exit 4 ;; esac
[ "$2" = /c ] && [ "$3" = echo ] || exit 5
shift 3
printf '%s\r\n' "$*"
SHIMEOF
printf '#!/bin/sh\nexit 0\n' > "$rw/bin/wineserver"
chmod +x "$rw/bin/wine" "$rw/bin/wineserver"
# ruya-session x11-run <app id> (RUY-980): what the helper does for the check, without an X server: it needs a
# runtime directory it may use and the profile's Wayland socket name, and with the file "no-display" next to it
# it fails as the real one does when the satellite does not start (log line, exit 203). Otherwise it runs
# `flatpak run --device=input <app id>` (the check's own `flatpak` in front of PATH) with DISPLAY and XAUTHORITY
# and without WAYLAND_DISPLAY. With the file "abs-flatpak" it starts the X server (logs "runs on display") but
# runs something else than the PATH's flatpak, as a helper that called /usr/bin/flatpak would.
mkdir -p "$rr/usr/bin"
cat > "$rr/usr/bin/ruya-session" <<'SHIMEOF'
#!/bin/sh
[ "$1" = x11-run ] && [ "$2" = org.ruyaos.RunnerCheck ] && [ "$#" = 2 ] || { echo "ruya-session: usage: x11-run <app id>" >&2; exit 2; }
[ -d "${XDG_RUNTIME_DIR:-/nonexistent}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] || { echo "ruya-session x11: $2: launch failed, no runtime dir or Wayland display" >&2; exit 203; }
[ -e "$(dirname "$0")/no-display" ] && { echo "ruya-session x11: $2: launch failed, no X server" >&2; exit 203; }
unset WAYLAND_DISPLAY
DISPLAY=:77; XAUTHORITY="$XDG_RUNTIME_DIR/Xauthority"; export DISPLAY XAUTHORITY
echo "ruya-session x11: $2 runs on display $DISPLAY" >&2
[ -e "$(dirname "$0")/abs-flatpak" ] && exec true
exec flatpak run --device=input "$2"
SHIMEOF
chmod +x "$rr/usr/bin/ruya-session"
# busctl get-property ... ActiveProfile: the signed-in profile $FAKE_ACTIVE (default p1; empty = nobody), as
# `s "p1"`; every other call is the shared fake busctl.
cat > "$rsh/busctl" <<'SHIMEOF'
#!/bin/sh
case "$*" in *get-property*ActiveProfile*) printf 's "%s"\n' "${FAKE_ACTIVE-p1}"; exit 0 ;; esac
exec "$FAKE_SHARED_SHIMS/busctl" "$@"
SHIMEOF
chmod +x "$rsh/busctl"
# proton: with a display (DISPLAY, no WAYLAND_DISPLAY: Wine's Wayland driver is refused by the compositor) and
# both STEAM_COMPAT_* folders, SteamAppId, SteamGameId and PWD set, it does what Proton does with CREATE_NEW_CONSOLE:
# cmd.exe's `echo <words>>Z:\path` writes the words and CR LF to the file, and nothing reaches stdout. Without
# a display it waits (here: exits 124 as `timeout` does). The file "silent" next to it writes nothing; "stdout"
# prints the words to stdout instead of the file (what the check used to read).
cat > "$rt/proton" <<'PYEOF'
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(os.path.join(here, "silent")):
    sys.exit(0)
# (Git Bash hands a native python the argument /c as C:/)
assert sys.argv[1] == "waitforexitandrun" and sys.argv[2].endswith("cmd.exe") and sys.argv[3] in ("/c", "C:/"), sys.argv
assert os.environ.get("STEAM_COMPAT_DATA_PATH"), os.environ
assert os.path.isdir(os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH", "")), os.environ
# What protonfixes needs outside Steam (RUY-969): it reads PWD without a fallback and fails on a game id
# parsed from a compat path without digits. A real run checks it for real (vm-runner-check.sh check).
assert os.environ.get("SteamAppId") == "0" and os.environ.get("SteamGameId") == "0", os.environ
assert os.path.samefile(os.environ.get("PWD", "/nonexistent"), os.getcwd()), (os.environ.get("PWD"), os.getcwd())
# What Wine needs and a console window too (RUY-980): a display, a runtime directory, no Wayland socket.
if not os.environ.get("DISPLAY") or not os.path.isdir(os.environ.get("XDG_RUNTIME_DIR", "")) or "WAYLAND_DISPLAY" in os.environ:
    sys.stderr.write("fake proton: no usable display, waiting for ever\n")
    sys.exit(124)
words, _, target = sys.argv[4].partition(">")
assert words.startswith("echo ") and target.startswith("Z:"), sys.argv
if os.path.exists(os.path.join(here, "stdout")):
    sys.stdout.write(words[5:] + "\r\n")
else:
    # Z:\<path> is <path> with / for \ (the shell's path, which `sh` resolves on every host).
    subprocess.run(["sh", "-c", 'printf "%s\\r\\n" "$1" > "$2"', "sh", words[5:], target[2:].replace("\\", "/")], check=True)
PYEOF
# readlink: the links of $FAKE_LINKS ("<path> <target>" lines).
cat > "$rsh/readlink" <<'SHIMEOF'
#!/bin/sh
while read -r p t; do [ "$p" = "$1" ] && { echo "$t"; exit 0; }; done < "$FAKE_LINKS"
exit 1
SHIMEOF
# ruya-pack runner-check: ok with $FAKE_PACK_HASH (the kind and version of a runner.json there, else
# GE-Proton's), or refused.
cat > "$rsh/ruya-pack" <<'SHIMEOF'
#!/bin/sh
if [ -n "${FAKE_PACK_REFUSE:-}" ]; then echo '{"ok": false, "problems": [{"code": "runner.unknown_key"}]}'; exit 1; fi
kind=proton; version=GE-Proton11-12
if [ -f "$2/runner.json" ]; then
    kind="$(sed -n 's/.*"kind": *"\([a-z]*\)".*/\1/p' "$2/runner.json")"
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$2/runner.json")"
fi
echo "{\"hash\": \"$FAKE_PACK_HASH\", \"runner\": {\"version\": \"$version\", \"kind\": \"$kind\"}, \"ok\": true}"
SHIMEOF
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$rsh/unshare"
printf '#!/bin/sh\nexit 0\n' > "$rsh/chown"
# ls -Z <file>: the SELinux label the image's policy gives the runners (RUY-999); $FAKE_LABEL changes it.
cat > "$rsh/ls" <<'SHIMEOF'
#!/bin/sh
[ "$1" = -Z ] && { printf '%s %s\n' "${FAKE_LABEL-system_u:object_r:textrel_shlib_t:s0}" "$2"; exit 0; }
exec /usr/bin/ls "$@"
SHIMEOF
chmod +x "$rsh"/*
mkdir -p "$rt/files/lib/wine/i386-windows"
: > "$rt/files/lib/wine/i386-windows/ntdll.dll"; : > "$rw/lib/wine/i386-windows/ntdll.dll"
printf '%s %s\n' "$rr/var/lib/flatpak/extension/org.ruyaos.Play.Launcher/x86_64/1" /usr/lib/ruyaos/play/launcher \
    "$rr/var/lib/flatpak/extension/org.ruyaos.Play.Runner.ProtonGE11/x86_64/1" /usr/lib/ruyaos/play/runners/ProtonGE11     "$rr/var/lib/flatpak/extension/com.valvesoftware.Steam.CompatibilityTool.ProtonGE11/x86_64/stable" /usr/lib/ruyaos/play/runners/ProtonGE11 > "$tmp/links.good"
printf '%s %s\n' "$rr/var/lib/flatpak/extension/org.ruyaos.Play.Runner.Wine11/x86_64/1" /usr/lib/ruyaos/play/runners/Wine11 >> "$tmp/links.good"
grep -v Launcher "$tmp/links.good" > "$tmp/links.nolauncher"
sed 's#/usr/lib/ruyaos/play/runners/ProtonGE11$#/usr/lib/ruyaos/play/runners/Other#' "$tmp/links.good" > "$tmp/links.elsewhere"
rc_() { # <links file> [VAR=value ...]: the check against the fake image
    local links="$1"; shift
    env FAKE_LINKS="$links" FAKE_PACK_HASH="$hash_ok" FAKE_SHARED_SHIMS="$shims" RUYA_ROOT="$rr" "$@" \
        PATH="$rsh:$PATH" bash "$here/vm-runner-check.sh" check "$rsh/ruya-pack" 2>&1
}
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner: a good image passes" "$out" "vm-runner-check: all passed" || fail "runner: a good image: exit $rc, $out"
expect_contains "runner: the Windows program ran as the profile user" "$out" "ProtonGE11: cmd.exe printed RUYA_RUNNER_OK as ruya-p1 without network"
expect_contains "runner: it ran on the display ruya-session x11-run made" "$out" "on display :77"
expect_contains "runner: the hash is compared" "$out" "hash $hash_ok as recorded"
expect_contains "runner: the Wine runner's 64-bit program ran" "$out" "Wine11: x86_64 cmd.exe printed RUYA_RUNNER_OK as ruya-p1 without network"
expect_contains "runner: the Wine runner's 32-bit program ran" "$out" "Wine11: i386 cmd.exe printed RUYA_RUNNER_OK as ruya-p1 without network"
expect_contains "runner: GE-Proton's i386 ntdll.dll is textrel_shlib_t" "$out" "ok   ProtonGE11: files/lib/wine/i386-windows/ntdll.dll is labelled system_u:object_r:textrel_shlib_t:s0"
expect_contains "runner: Wine's i386 ntdll.dll is textrel_shlib_t" "$out" "ok   Wine11: lib/wine/i386-windows/ntdll.dll is labelled"
out="$(rc_ "$tmp/links.good" FAKE_LABEL=system_u:object_r:lib_t:s0)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a runner DLL labelled lib_t FAILs (RUY-999)" "$out" "FAIL ProtonGE11: files/lib/wine/i386-windows/ntdll.dll is labelled 'system_u:object_r:lib_t:s0', not textrel_shlib_t" || fail "runner: lib_t label: exit $rc, $out"
# A wine or proton runner without an i386 ntdll.dll is a FAIL naming it, never a silent skip (RUY-1005); other kinds are not checked.
mv "$rw/lib/wine/i386-windows/ntdll.dll" "$tmp/ntdll.keep"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a Wine runner with no i386 ntdll.dll FAILs" "$out" "FAIL Wine11: a wine runner with no i386-windows/ntdll.dll" || fail "runner: no ntdll.dll: exit $rc, $out"
mv "$tmp/ntdll.keep" "$rw/lib/wine/i386-windows/ntdll.dll"
mv "$rt/files/lib/wine/i386-windows/ntdll.dll" "$tmp/ntdll.keep"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a Proton runner with no i386 ntdll.dll FAILs" "$out" "FAIL ProtonGE11: a proton runner with no i386-windows/ntdll.dll" || fail "runner: no ntdll.dll (proton): exit $rc, $out"
mv "$tmp/ntdll.keep" "$rt/files/lib/wine/i386-windows/ntdll.dll"
ro="$rp/runners/Tool"; mkdir -p "$ro"
printf '{"kind": "tool", "version": "1"}
' > "$ro/runner.json"; printf '%s
' "$hash_ok" > "$ro/.ruya-runner-hash"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'Tool: a ' && pass "runner: a runner of another kind needs no ntdll.dll" || fail "runner: another kind: exit $rc, $out"
rm -rf "$ro"
out="$(rc_ "$tmp/links.nolauncher")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a missing launcher link FAILs" "$out" "FAIL /var/lib/flatpak/extension/org.ruyaos.Play.Launcher/x86_64/1 is 'no link'" || fail "runner: a missing link: exit $rc"
out="$(rc_ "$tmp/links.elsewhere")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a link to another folder FAILs" "$out" "is '/usr/lib/ruyaos/play/runners/Other', not a link to the folder" || fail "runner: a wrong link: exit $rc"
out="$(rc_ "$tmp/links.good" FAKE_PACK_HASH="$(printf 'cd%.0s' $(seq 32))")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a hash that is not the recorded one FAILs" "$out" "FAIL ProtonGE11: runner-check ok=yes" || fail "runner: a hash mismatch: exit $rc"
out="$(rc_ "$tmp/links.good" FAKE_PACK_REFUSE=1)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a refused runner.json FAILs" "$out" "FAIL ProtonGE11: runner-check ok=no" || fail "runner: a refused runner: exit $rc"
out="$(rc_ "$tmp/links.good" FAKE_LAUNCH_SAYS="something else")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a launcher that does not refuse in its own words FAILs" "$out" "FAIL the launcher outside a sandbox" || fail "runner: the launcher's answer: exit $rc"
# The label comes from the image's policy (RUY-999): the module has the file context and the Containerfile loads it.
grep -qF '(filecon "/usr/lib/ruyaos/play/runners(/.*)?" file (system_u object_r textrel_shlib_t ((s0) (s0))))' "$here/../image/rootfs/usr/share/selinux/packages/ruyaos/ruya_play_runners.cil" && pass "ruya_play_runners.cil labels the runner trees textrel_shlib_t" || fail "ruya_play_runners.cil has no textrel_shlib_t file context for /usr/lib/ruyaos/play/runners"
grep -Eq '^[[:space:]]*&& semodule -i .* -i /usr/share/selinux/packages/ruyaos/ruya_play_runners\.cil' "$here/../image/Containerfile" && pass "the Containerfile loads ruya_play_runners.cil with semodule -i" || fail "the Containerfile does not load ruya_play_runners.cil"
! grep -q 'runners.list' "$here/vm-runner-check.sh" && pass "vm-runner-check.sh reads no runners.list (RUY-959: Library1 ListRunners)" || fail "vm-runner-check.sh still reads runners.list"
: > "$rt/silent"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: no marker from the Windows program FAILs" "$out" "FAIL ProtonGE11: cmd.exe through proton as ruya-p1" || fail "runner: the marker: exit $rc"
rm -f "$rt/silent"
# Proton's console window gets what cmd.exe echoes, not stdout (RUY-980): a marker on stdout only does not pass.
: > "$rt/stdout"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a marker on stdout and not in the file FAILs" "$out" "FAIL ProtonGE11: cmd.exe through proton as ruya-p1: exit 0, marker file ''" || fail "runner: the marker on stdout: exit $rc, $out"
rm -f "$rt/stdout"
# The signed-in profile gets no X server: a FAIL with the helper's words (never a SKIP, never the wait for Proton).
: > "$rr/usr/bin/no-display"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: no X server for the signed-in profile FAILs" "$out" "FAIL the signed-in profile ruya-p1 got no X server from ruya-session x11-run, so ProtonGE11's cmd.exe was not run" || fail "runner: no display: exit $rc, $out"
expect_contains "runner: the FAIL quotes the helper" "$out" "launch failed, no X server"
expect_lacks "runner: no display is not a SKIP" "$out" "SKIP"
expect_contains "runner: the Wine runner's check still ran without a display" "$out" "Wine11: x86_64 cmd.exe printed RUYA_RUNNER_OK as ruya-p1 without network"
rm -f "$rr/usr/bin/no-display"
# The helper started the X server but did not run flatpak from the PATH: not "no X server".
: > "$rr/usr/bin/abs-flatpak"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a helper that does not run flatpak from PATH FAILs" "$out" "FAIL x11-run started an X server for ruya-p1 but did not run flatpak from PATH, so ProtonGE11's cmd.exe was not run" || fail "runner: abs flatpak: exit $rc, $out"
rm -f "$rr/usr/bin/abs-flatpak"
# A missing helper is a broken image.
mv "$rr/usr/bin/ruya-session" "$rr/usr/bin/ruya-session.keep"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a missing helper FAILs" "$out" "FAIL $rr/usr/bin/ruya-session is missing: the image has no ruya-session x11-run helper" || fail "runner: no helper: exit $rc, $out"
mv "$rr/usr/bin/ruya-session.keep" "$rr/usr/bin/ruya-session"
# The program runs as the signed-in profile, not the first one listed.
out="$(rc_ "$tmp/links.good" FAKE_ACTIVE=p2)"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner: the program runs as the signed-in profile" "$out" "ProtonGE11: cmd.exe printed RUYA_RUNNER_OK as ruya-p2 without network" || fail "runner: active profile: exit $rc, $out"
: > "$rw/silent"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: no marker through the Wine runner FAILs" "$out" "FAIL Wine11: x86_64 cmd.exe through bin/wine as ruya-p1" || fail "runner: the Wine marker: exit $rc"
rm -f "$rw/silent"
mv "$rw/lib/wine/i386-windows/cmd.exe" "$tmp/cmd32.keep"
out="$(rc_ "$tmp/links.good")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner: a Wine runner that cannot run a 32-bit program FAILs" "$out" "FAIL Wine11: i386 cmd.exe through bin/wine as ruya-p1" || fail "runner: the 32-bit program: exit $rc"
mv "$tmp/cmd32.keep" "$rw/lib/wine/i386-windows/cmd.exe"
out="$(rc_ "$tmp/links.good" FAKE_ACTIVE=)"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner: with nobody signed in the program step is a SKIP" "$out" "SKIP: no profile is signed in" || fail "runner: no profile: exit $rc, $out"
[ "$(grep -c 'run_on_display "\$user"' "$here/vm-runner-check.sh")" = 2 ] && grep -q 'x11-run org.ruyaos.RunnerCheck' "$here/vm-runner-check.sh" && pass "vm-runner-check.sh runs the Proton program and the sample through run_on_display (ruya-session x11-run), one copy" || fail "vm-runner-check.sh: the Proton program and the sample do not both go through run_on_display"
grep -q 'unshare -n runuser -u "$user"' "$here/vm-runner-check.sh" && pass "vm-runner-check.sh runs the program offline as the profile user" || fail "vm-runner-check.sh: the program does not run under unshare -n as the profile user"

echo "== vm-runner-check.sh steam: GE-Proton in Steam (RUY-35) =="
# Two Proton runners (the older is the newer folder name on purpose: the version in runner.json
# decides). Each carries GE-Proton's own compatibilitytool.vdf; Steam's extension point links to it.
steam_runner() { # <folder> <version> <tool>
    local t="$rp/runners/$1"
    mkdir -p "$t" "$rr/var/lib/flatpak/extension/com.valvesoftware.Steam.CompatibilityTool.$1/x86_64"
    printf '{"kind": "proton", "version": "%s"}\n' "$2" > "$t/runner.json"
    printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s"\n    {\n      "install_path" "."\n    }\n  }\n}\n' "$3" > "$t/compatibilitytool.vdf"
    ln -s "$t" "$rr/var/lib/flatpak/extension/com.valvesoftware.Steam.CompatibilityTool.$1/x86_64/stable"
}
steam_runner ProtonGE11 GE-Proton10-34 GE-Proton10-34
steam_runner ProtonGE12 GE-Proton11-12 GE-Proton11-12
sx="$rr/var/lib/flatpak/extension/com.valvesoftware.Steam.CompatibilityTool.ProtonGE12/x86_64"
steam_dir="$rr/home/ruya-p1/.var/app/com.valvesoftware.Steam/.local/share/Steam"
mkdir -p "$rr/var/lib/flatpak/app/com.valvesoftware.Steam" "$steam_dir/config"
touch "$steam_dir/steam.sh"
printf '#!/bin/sh\necho "ruya-p1:x:1001:1001::/home/ruya-p1:/bin/sh"\n' > "$rsh/getent"; chmod +x "$rsh/getent"
steam_cfg="$steam_dir/config/config.vdf"
steam_config() { # <tool name>: a config.vdf whose default is that tool, a "0" elsewhere after it
    printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\t"Other"\n\t\t\t\t{\n\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"not-this"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' "$1" > "$steam_cfg"
}
sc_() { env RUYA_ROOT="$rr" PATH="$rsh:$PATH" bash "$here/vm-runner-check.sh" steam 2>&1; }
steam_config GE-Proton11-12
out="$(sc_)"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner steam: a good image passes" "$out" "vm-runner-check: all passed" || fail "runner steam: a good image: exit $rc, $out"
expect_contains "runner steam: the tool is listed" "$out" "ProtonGE12: Steam's extension point has the tool GE-Proton11-12"
expect_contains "runner steam: the newest runner is the one by version" "$out" "the newest Proton runner is ProtonGE12, tool GE-Proton11-12"
expect_contains "runner steam: the default is the newest tool" "$out" "ruya-p1: the default is GE-Proton11-12, the newest runner's tool"
expect_contains "runner steam: Steam's own files are required" "$out" "ruya-p1: Steam's own files are in"
steam_config GE-Proton10-34
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: an older tool as the default FAILs" "$out" "FAIL ruya-p1: the default is 'GE-Proton10-34', not GE-Proton11-12" || fail "runner steam: an older default: exit $rc"
steam_config proton_9
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: a tool the player chose FAILs too" "$out" "FAIL ruya-p1: the default is 'proton_9'" || fail "runner steam: a player's choice: exit $rc"
printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t}\n\t\t\t\t"Other"\n\t\t\t\t{\n\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"GE-Proton11-12"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' > "$steam_cfg"
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: a 0 outside the mapping block is not read" "$out" "FAIL ruya-p1: the default is 'none'" || fail "runner steam: a 0 elsewhere: exit $rc"
: > "$steam_cfg"
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: no default FAILs" "$out" "FAIL ruya-p1: the default is 'none'" || fail "runner steam: no default: exit $rc"
steam_config GE-Proton11-12
rm "$steam_dir/steam.sh"
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: a config without Steam's own files FAILs" "$out" "FAIL ruya-p1: no steam.sh or ubuntu12_32" || fail "runner steam: no Steam files: exit $rc"
mkdir "$steam_dir/ubuntu12_32"
out="$(sc_)"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner steam: ubuntu12_32 does as well" "$out" "Steam's own files are in" || fail "runner steam: ubuntu12_32: exit $rc"
rm -f "$steam_cfg"
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: no profile that started Steam FAILs" "$out" "FAIL no profile has started Steam yet" || fail "runner steam: no config: exit $rc"
steam_config GE-Proton11-12
rm -rf "$sx/stable"
out="$(sc_)"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner steam: a runner not linked for Steam FAILs" "$out" "FAIL ProtonGE12: no compatibilitytool.vdf" || fail "runner steam: no link: exit $rc"

echo "== vm-runner-check.sh sample: the developer guide's sample on the image (RUY-36) =="
# A stand-in for samples/hello-runner/run-windows.py (the real script execs the runner's shebang script,
# which a Windows host cannot do; its logic is samples/hello-runner/test_run_windows.py, run below). The
# check copies the script, runs it under `env -i` as the profile user and reads only what it prints and
# leaves, so the stand-in is told what to do by the file `sample-mode` next to the runners.
sample_py="$tmp/fake-run-windows.py"
cat > "$sample_py" <<'PYEOF'
import os, sys
mode = ""
try:
    with open(os.path.join(os.path.dirname(sys.argv[2]), "sample-mode"), encoding="utf-8") as f:
        mode = f.read().strip()
except OSError:
    pass
assert sys.argv[1] == "--runners" and sys.argv[3] == "--self-test", sys.argv
# Run on the display ruya-session x11-run made (RUY-980): the real script refuses to start without one.
assert os.environ.get("DISPLAY") and "WAYLAND_DISPLAY" not in os.environ, os.environ
# The check starts the copy from the scratch folder it copied it to (RUY-969): the script sets PWD from
# its working folder, and that must be one the profile user can use.
assert os.path.samefile(os.getcwd(), os.path.dirname(os.path.abspath(__file__))), (os.getcwd(), __file__)
if mode != "norunner":
    print("hello-runner: using ProtonGE11 (GE-Proton11-12)")
if mode != "noprefix":
    os.makedirs(os.path.join(os.environ["XDG_DATA_HOME"], "proton", "pfx"), exist_ok=True)
if mode != "silent":
    print("RUYA_HELLO_RUNNER_OK")
sys.exit(1 if mode == "fail" else 0)
PYEOF
sm_() { # <script> [VAR=value ...]: the sample mode against the fake image
    local script="$1"; shift
    env FAKE_SHARED_SHIMS="$shims" RUYA_ROOT="$rr" "$@" PATH="$rsh:$PATH" bash "$here/vm-runner-check.sh" sample "$script" 2>&1
}
out="$(sm_ "$sample_py")"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner sample: a good run passes" "$out" "vm-runner-check: all passed" || fail "runner sample: a good run: exit $rc, $out"
expect_contains "runner sample: the runner is one of the image's" "$out" "the script took the runner ProtonGE11 from"
expect_contains "runner sample: the marker came from the runner as the profile user" "$out" "ProtonGE11: cmd.exe printed RUYA_HELLO_RUNNER_OK as ruya-p1 without network"
expect_contains "runner sample: the prefix is in the data folder" "$out" "the Proton prefix is in the app's data folder"
for m in silent noprefix norunner fail; do
    echo "$m" > "$rp/sample-mode"
    out="$(sm_ "$sample_py")"; rc=$?
    case "$m" in
    silent) want="FAIL the sample as ruya-p1: exit 0" ;;
    noprefix) want="FAIL no Proton prefix at" ;;
    norunner) want="FAIL the script named no runner of the image" ;;
    fail) want="FAIL the sample as ruya-p1: exit 1" ;;
    esac
    [ "$rc" = 1 ] && expect_contains "runner sample: '$m' FAILs" "$out" "$want" || fail "runner sample: $m: exit $rc, $out"
done
rm -f "$rp/sample-mode"
out="$(sm_ "$tmp/no-such-script.py")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner sample: a missing script FAILs" "$out" "is not on the guest" || fail "runner sample: no script: exit $rc"
: > "$rr/usr/bin/no-display"
out="$(sm_ "$sample_py")"; rc=$?
[ "$rc" = 1 ] && expect_contains "runner sample: no X server for the signed-in profile FAILs" "$out" "FAIL the signed-in profile ruya-p1 got no X server from ruya-session x11-run, so the sample was not run" || fail "runner sample: no display: exit $rc, $out"
expect_lacks "runner sample: no display is not a SKIP" "$out" "SKIP"
rm -f "$rr/usr/bin/no-display"
out="$(sm_ "$sample_py" FAKE_ACTIVE=)"; rc=$?
[ "$rc" = 0 ] && expect_contains "runner sample: with nobody signed in it is a SKIP" "$out" "SKIP: no profile is signed in: the sample was not run" || fail "runner sample: no profile: exit $rc, $out"
grep -q 'unshare -n runuser -u "$user" -- env -i' "$here/vm-runner-check.sh" && pass "vm-runner-check.sh runs the sample offline as the profile user" || fail "vm-runner-check.sh: the sample does not run under unshare -n as the profile user"
# The real script's own logic (the runner choice and the Proton argv and environment) on the host.
python3 -I "$here/../samples/hello-runner/test_run_windows.py" > "$tmp/sample-unit.log" 2>&1 && pass "samples/hello-runner/test_run_windows.py passes" || { cat "$tmp/sample-unit.log"; fail "samples/hello-runner/test_run_windows.py failed"; }

echo "== install-runners.sh: the image build's runner step (RUY-34) =="
ir="$tmp/install-runners"; ish="$tmp/install-shims"; mkdir -p "$ir/runners/ProtonGE11" "$ir/rel/GE-X/files" "$ish"
printf '#!/bin/sh\necho proton\n' > "$ir/rel/GE-X/proton"; chmod 0755 "$ir/rel/GE-X/proton"
echo data > "$ir/rel/GE-X/files/open.dll"; chmod 0666 "$ir/rel/GE-X/files/open.dll"
# A release without a licence text (as Kron4ek's Wine) first, then the same with its LICENSE (as GE-Proton).
(cd "$ir/rel" && tar -czf "$ir/release-nolicence.tar.gz" GE-X)
echo "the release's licence" > "$ir/rel/GE-X/LICENSE"
(cd "$ir/rel" && tar -czf "$ir/release.tar.gz" GE-X)
rsha="$(sha256sum "$ir/release.tar.gz" | cut -d' ' -f1)"
printf '# a comment\nurl=https://example.org/release.tar.gz\nsha256=%s\nroot=GE-X\n' "$rsha" > "$ir/runners/ProtonGE11/pin"
echo '{"format": 1}' > "$ir/runners/ProtonGE11/runner.json"
# curl -o <file> <url>: copies $FAKE_RELEASE. ruya-pack runner-check <dir> --write-hash.
cat > "$ish/curl" <<'SHIMEOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { cp "$FAKE_RELEASE" "$2"; exit 0; }; shift; done
exit 1
SHIMEOF
cat > "$ish/ruya-pack" <<'SHIMEOF'
#!/bin/sh
[ "$1" = runner-check ] && [ "$3" = --write-hash ] && [ "$#" = 3 ] || exit 2
[ -f "$2/runner.json" ] || exit 1
printf 'ab\n' > "$2/.ruya-runner-hash"
SHIMEOF
chmod +x "$ish"/*
ir_() { env FAKE_RELEASE="$ir/release.tar.gz" PATH="$ish:$PATH" bash "$here/../image/play/install-runners.sh" "$@" 2>&1; }
out="$(ir_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" = 0 ] && [ -f "$ir/play/runners/ProtonGE11/proton" ] && [ -f "$ir/play/runners/ProtonGE11/runner.json" ] && pass "install-runners: fetch unpacks the pinned release with its runner.json" || fail "install-runners: fetch: exit $rc, $out"
[ -z "$(find "$ir/play/runners/ProtonGE11" ! -type l -perm /022)" ] && pass "install-runners: nothing it unpacks is group- or world-writable" || fail "install-runners: writable files left: $(find "$ir/play/runners/ProtonGE11" ! -type l -perm /022)"
out="$(ir_ check "$ish/ruya-pack" "$ir/play" "$ir/meta")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$ir/meta/runners/ProtonGE11/.ruya-runner-hash")" = ab ] && pass "install-runners: check puts each runner's hash into the meta tree" || fail "install-runners: check: exit $rc, $out"
[ ! -e "$ir/meta/runners.list" ] && expect_contains "install-runners: check writes no runners.list and counts the runners (RUY-959)" "$out" "1 runner(s) checked" || fail "install-runners: check: $out"
mkdir -p "$ir/empty/runners"
out="$(ir_ check "$ish/ruya-pack" "$ir/empty" "$ir/meta-empty")"; rc=$?
[ "$rc" != 0 ] && expect_contains "install-runners: check without a runner fails the build" "$out" "no runner in" || fail "install-runners: check of no runner: exit $rc, $out"
rm -rf "$ir/play"
printf 'url=https://example.org/r\nsha256=%s\nroot=GE-X\n' "$(printf '0%.0s' $(seq 64))" > "$ir/runners/ProtonGE11/pin"
out="$(ir_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" != 0 ] && expect_contains "install-runners: another SHA-256 fails the build" "$out" "is not the pinned release" || fail "install-runners: a wrong hash: exit $rc"
[ ! -e "$ir/play/runners/ProtonGE11" ] && pass "install-runners: nothing is unpacked from a release that is not the pinned one" || fail "install-runners: a wrong release was unpacked"
printf 'url=https://example.org/r\nsha256=%s\nroot=GE-X\nmirror=x\n' "$rsha" > "$ir/runners/ProtonGE11/pin"
out="$(ir_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" != 0 ] && expect_contains "install-runners: an unknown pin line fails the build" "$out" "unknown line: mirror=x" || fail "install-runners: an unknown pin line: exit $rc"
printf 'url=http://example.org/r\nsha256=%s\nroot=GE-X\n' "$rsha" > "$ir/runners/ProtonGE11/pin"
out="$(ir_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" != 0 ] && expect_contains "install-runners: a URL that is not https fails the build" "$out" "url is not https" || fail "install-runners: an http URL: exit $rc"
# RUY-920: the pin grammar is written once in Rust (Pin::parse); check_pin gives the same verdict on
# every shared fixture (good* accepted, bad* refused), the ones Rust tests read too.
pins="$here/../services/ruya-play-format/tests/fixtures/pins"
npins=0
for f in "$pins"/*.pin; do
    b="$(basename "$f")"; npins=$((npins + 1))
    out="$(bash "$here/../image/play/install-runners.sh" check-pin "$f" 2>&1)"; rc=$?
    case "$b" in
    good*) [ "$rc" = 0 ] && pass "install-runners: check_pin accepts $b" || fail "install-runners: check_pin refused $b: $out" ;;
    bad*) [ "$rc" != 0 ] && pass "install-runners: check_pin refuses $b" || fail "install-runners: check_pin accepted $b" ;;
    *) fail "install-runners: pin fixture $b is neither good* nor bad*" ;;
    esac
done
[ "$npins" -ge 12 ] || fail "install-runners: only $npins pin fixtures"
# RUY-37: the pin folder's own files (licence texts) are laid over the release; none replaces a release
# file; a tree without a licence text fails the build.
nsha="$(sha256sum "$ir/release-nolicence.tar.gz" | cut -d' ' -f1)"
irn_() { env FAKE_RELEASE="$ir/release-nolicence.tar.gz" PATH="$ish:$PATH" bash "$here/../image/play/install-runners.sh" "$@" 2>&1; }
printf 'url=https://example.org/r\nsha256=%s\nroot=GE-X\n' "$nsha" > "$ir/runners/ProtonGE11/pin"
out="$(irn_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" != 0 ] && expect_contains "install-runners: a runner without a licence text fails the build" "$out" "ProtonGE11: no licence text at the runner's root" || fail "install-runners: no licence: exit $rc, $out"
rm -rf "$ir/play"
mkdir -p "$ir/runners/ProtonGE11/licences/zlib"
echo "LGPL text" > "$ir/runners/ProtonGE11/licences/COPYING.LIB"
echo "zlib text" > "$ir/runners/ProtonGE11/licences/zlib/LICENSE"
out="$(irn_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$ir/play/runners/ProtonGE11/licences/zlib/LICENSE")" = "zlib text" ] && [ -f "$ir/play/runners/ProtonGE11/licences/COPYING.LIB" ] && pass "install-runners: the pin folder's licences/ is installed into the runner's tree" || fail "install-runners: licences/: exit $rc, $out"
[ ! -e "$ir/play/runners/ProtonGE11/pin" ] && pass "install-runners: the pin file itself is not installed" || fail "install-runners: the pin was installed"
rm -rf "$ir/play"
echo "ours" > "$ir/runners/ProtonGE11/proton"
out="$(irn_ fetch "$ir/runners" "$ir/play")"; rc=$?
[ "$rc" != 0 ] && expect_contains "install-runners: a pin-folder file the release already has fails the build" "$out" "ProtonGE11: the release already has proton" || fail "install-runners: an overwrite: exit $rc, $out"
[ "$(cat "$ir/play/runners/ProtonGE11/proton" 2>/dev/null | tail -n 1)" = "echo proton" ] && pass "install-runners: the release's file is left as it was" || fail "install-runners: the release's proton was replaced"
rm -rf "$ir/play" "$ir/runners/ProtonGE11/proton" "$ir/runners/ProtonGE11/licences"
# RUY-1039: the pin folder's prune file deletes the release's files that shadow the runtime's libraries,
# before the runner hash is computed. A bad line, a glob that matches nothing and a glob that matches a
# folder fail the build; the prune file is not installed.
mkdir -p "$ir/rel/GE-X/files/lib/x86_64-linux-gnu" "$ir/rel/GE-X/files/lib/dir.so"
echo xk > "$ir/rel/GE-X/files/lib/x86_64-linux-gnu/libxk.so.0.0.9"
ln -s libxk.so.0.0.9 "$ir/rel/GE-X/files/lib/x86_64-linux-gnu/libxk.so.0"
echo keep > "$ir/rel/GE-X/files/lib/x86_64-linux-gnu/libkeep.so.1"
(cd "$ir/rel" && tar -czf "$ir/release-prune.tar.gz" GE-X)
psha="$(sha256sum "$ir/release-prune.tar.gz" | cut -d' ' -f1)"
irp_() { env FAKE_RELEASE="$ir/release-prune.tar.gz" PATH="$ish:$PATH" bash "$here/../image/play/install-runners.sh" "$@" 2>&1; }
printf 'url=https://example.org/r\nsha256=%s\nroot=GE-X\n' "$psha" > "$ir/runners/ProtonGE11/pin"
printf '# why\nfiles/lib/x86_64-linux-gnu/libxk.so*\n' > "$ir/runners/ProtonGE11/prune"
rm -rf "$ir/play"
out="$(irp_ fetch "$ir/runners" "$ir/play")"; rc=$?
pt="$ir/play/runners/ProtonGE11/files/lib/x86_64-linux-gnu"
[ "$rc" = 0 ] && [ ! -e "$pt/libxk.so.0.0.9" ] && [ ! -L "$pt/libxk.so.0" ] && pass "install-runners: the prune file's files are gone from the tree (a file and its link)" || fail "install-runners: prune: exit $rc, $out; left: $(ls "$pt" 2>&1)"
[ -f "$pt/libkeep.so.1" ] && [ -f "$ir/play/runners/ProtonGE11/proton" ] && pass "install-runners: a file no prune glob names stays" || fail "install-runners: prune removed a file it should keep"
expect_contains "install-runners: fetch says how many files it pruned" "$out" "pruned 2 file(s)"
[ ! -e "$ir/play/runners/ProtonGE11/prune" ] && pass "install-runners: the prune file itself is not installed" || fail "install-runners: the prune file was installed"
# The hash is computed after the prune: `check` hands ruya-pack the pruned tree.
cat > "$ish/ruya-pack" <<'SHIMEOF'
#!/bin/sh
[ "$1" = runner-check ] && [ "$3" = --write-hash ] && [ "$#" = 3 ] || exit 2
(cd "$2" && find . -name 'libxk*' | sort > "$FAKE_SEEN")
printf 'ab\n' > "$2/.ruya-runner-hash"
SHIMEOF
out="$(env FAKE_SEEN="$ir/seen.txt" PATH="$ish:$PATH" bash "$here/../image/play/install-runners.sh" check "$ish/ruya-pack" "$ir/play" "$ir/meta2" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$ir/seen.txt" ] && pass "install-runners: runner-check (the hash) sees the pruned tree" || fail "install-runners: check after the prune: exit $rc, $out; saw $(cat "$ir/seen.txt" 2>&1)"
for bad in 'files/../x' '/etc/passwd' 'files/nothing-here*' 'files/lib/*'; do
    rm -rf "$ir/play"
    printf '# why\n%s\n' "$bad" > "$ir/runners/ProtonGE11/prune"
    out="$(irp_ fetch "$ir/runners" "$ir/play")"; rc=$?
    case "$bad" in
    files/nothing-here*) want="matches nothing in the release" ;;
    files/lib/\*) want="matches the folder" ;;
    *) want="not a plain relative glob" ;;
    esac
    [ "$rc" != 0 ] && expect_contains "install-runners: the prune line '$bad' fails the build" "$out" "$want" || fail "install-runners: prune '$bad': exit $rc, $out"
done
# RUY-1039: check_prune gives the same verdict as Prune::parse on every shared fixture.
prunes="$here/../services/ruya-play-format/tests/fixtures/prunes"
nprunes=0
for f in "$prunes"/*.prune; do
    b="$(basename "$f")"; nprunes=$((nprunes + 1))
    out="$(bash "$here/../image/play/install-runners.sh" check-prune "$f" 2>&1)"; rc=$?
    case "$b" in
    good*) [ "$rc" = 0 ] && pass "install-runners: check_prune accepts $b" || fail "install-runners: check_prune refused $b: $out" ;;
    bad*) [ "$rc" != 0 ] && pass "install-runners: check_prune refuses $b" || fail "install-runners: check_prune accepted $b" ;;
    *) fail "install-runners: prune fixture $b is neither good* nor bad*" ;;
    esac
done
[ "$nprunes" -ge 12 ] || fail "install-runners: only $nprunes prune fixtures"
# A folder link in the release that leads out of the tree: the prune must not follow it (the file outside
# survives and the build fails).
mkdir -p "$ir/outside/lib" "$ir/rel2/GE-X"
echo outside > "$ir/outside/lib/libxk.so.0"
echo "the release's licence" > "$ir/rel2/GE-X/LICENSE"
printf '#!/bin/sh\n' > "$ir/rel2/GE-X/proton"
# MSYS: a real link on Windows too (Git Bash otherwise copies the folder); no effect on Linux.
MSYS=winsymlinks:nativestrict ln -s "$ir/outside" "$ir/rel2/GE-X/files"
(cd "$ir/rel2" && tar -czf "$ir/release-link.tar.gz" GE-X)
lsha="$(sha256sum "$ir/release-link.tar.gz" | cut -d' ' -f1)"
printf 'url=https://example.org/r\nsha256=%s\nroot=GE-X\n' "$lsha" > "$ir/runners/ProtonGE11/pin"
printf '# why\nfiles/lib/libxk.so*\n' > "$ir/runners/ProtonGE11/prune"
rm -rf "$ir/play"
out="$(env MSYS=winsymlinks:nativestrict FAKE_RELEASE="$ir/release-link.tar.gz" PATH="$ish:$PATH" bash "$here/../image/play/install-runners.sh" fetch "$ir/runners" "$ir/play" 2>&1)"; rc=$?
[ -L "$ir/rel2/GE-X/files" ] || fail "install-runners: the fixture could not make a folder link"
[ "$rc" != 0 ] && expect_contains "install-runners: a prune through a folder link that leaves the tree fails the build" "$out" "is outside the runner's tree" || fail "install-runners: prune through a link: exit $rc, $out"
[ -f "$ir/outside/lib/libxk.so.0" ] && pass "install-runners: the file outside the runner's tree survives the prune" || fail "install-runners: the prune deleted a file outside the tree"
rm -rf "$ir/play" "$ir/runners/ProtonGE11/prune"

echo "== check-image-manifest.sh: the Play platform's files have rows (RUY-34) =="
msh="$tmp/manifest-shims"; mkdir -p "$msh"
# podman run --rm <image> bash -c <script>: a documented leaf for dnf leaves, $FAKE_PLATFORM for the platform.
cat > "$msh/podman" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*"dnf leaves"*) echo bootc ;;
*ruyaos/play*) printf '%b' "$FAKE_PLATFORM" ;;
*) exit 1 ;;
esac
SHIMEOF
chmod +x "$msh/podman"
out="$(FAKE_PLATFORM='ruya-play-launch\nProtonGE11\n' PATH="$msh:$PATH" bash "$here/check-image-manifest.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && expect_contains "manifest: the launcher and ProtonGE11 are documented" "$out" "1 runner(s) and the launcher" || fail "manifest: a documented platform: exit $rc, $out"
out="$(FAKE_PLATFORM='ruya-play-launch\nProtonGE11\nWine99\n' PATH="$msh:$PATH" bash "$here/check-image-manifest.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && expect_contains "manifest: a runner without a row FAILs" "$out" "not in docs/image-packages.md: Wine99" || fail "manifest: an undocumented runner: exit $rc, $out"
out="$(FAKE_PLATFORM='ProtonGE11\n' PATH="$msh:$PATH" bash "$here/check-image-manifest.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && expect_contains "manifest: an image without the launcher FAILs" "$out" "has no /usr/lib/ruyaos/play/launcher/bin/ruya-play-launch" || fail "manifest: no launcher: exit $rc, $out"

echo "== build stage names (RUY-771) =="
source "$here/lib-stages.sh"
printf '%s\n' 'ARG X=1' 'FROM a/b:${X} AS one' 'RUN true' 'FROM c as Two' 'FROM d AS three-3' 'FROM quay.io/final:${X}' > "$tmp/Containerfile.stages"
got="$(ruya_stage_names "$tmp/Containerfile.stages" | tr '\n' ' ')"
[ "$got" = "one Two three-3 " ] && pass "stage names: 3 named, the final FROM skipped" || fail "stage names: '$got'"
real="$(ruya_stage_names "$here/../image/Containerfile" | tr '\n' ' ')"
expect_contains "stage names: real Containerfile" "$real" "shell-build services-build qt-dmabuf xwayland-satellite play-runners play-runners-check"

# RUY-1014: webp_checks wants the plugin file and a journal without "Unsupported image format".
echo "== vm-play-check.sh: the WebP plugin (RUY-1014) =="
wp="$tmp/webp"; mkdir -p "$wp/bin"; : > "$wp/libqwebp.so"
printf '#!/bin/sh
printf "%%s" "$FAKE_JOURNAL"
' > "$wp/bin/journalctl"; chmod +x "$wp/bin/journalctl"
webp_run() { # <plugin path>
    ( fail=0; ok() { echo "PASS: $*"; }; bad() { echo "FAIL: $*"; }
      eval "$(sed -n '/^webp_checks() {/,/^}/p' "$here/vm-play-check.sh")"
      PATH="$wp/bin:$PATH" WEBP_PLUGIN="$1" webp_checks )
}
out="$(FAKE_JOURNAL='shell started' webp_run "$wp/libqwebp.so")"
expect_contains "webp: plugin and a clean journal" "$out" "PASS: the Qt WebP image plugin is installed"
expect_contains "webp: clean journal passes" "$out" "PASS: no Unsupported image format"
expect_lacks "webp: no FAIL when all is well" "$out" "FAIL"
out="$(FAKE_JOURNAL='qt.gui: card-540.webp: Unsupported image format' webp_run "$wp/libqwebp.so")"
expect_contains "webp: the journal line fails" "$out" "FAIL: the shell could not decode an image"
out="$(FAKE_JOURNAL='' webp_run "$wp/missing.so")"
expect_contains "webp: a missing plugin fails" "$out" "FAIL: the Qt WebP image plugin is missing"
[ "$(grep -c '^webp_checks$' "$here/vm-play-check.sh")" = 1 ] && pass "vm-play-check.sh check mode runs webp_checks" || fail "vm-play-check.sh check mode does not run webp_checks"
grep -q 'qt6-qtimageformats' "$here/../image/build/20-base.sh" && pass "20-base.sh installs qt6-qtimageformats" || fail "20-base.sh lacks qt6-qtimageformats"

echo
if [ "$fails" = 0 ]; then echo "vm-check tests: all passed"; else echo "vm-check tests: $fails failed"; fi
exit $(( fails > 0 ))
