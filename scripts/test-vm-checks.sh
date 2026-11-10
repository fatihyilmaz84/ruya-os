#!/usr/bin/env bash
# Host tests of the VM check scripts (T-296): the parts of scripts/vm-*-check.sh that can run without a
# VM, on canned data and with fake tools in front of PATH. Run by scripts/lint-vm-checks.ps1 (dev.ps1 test,
# CI); also directly:  bash scripts/test-vm-checks.sh
# It proves that a check FAILS when the thing it checks is broken, not only that it passes when fine:
#   - vm-devices-check.sh  picks the volume by its keys, whatever the order of the keys
#   - vm-storage-check.sh  a refused action is pkcheck exit 1 (not any non-zero); an error reply from
#                          ListVolumes is not "the volume left the list"
#   - vm-security-check.sh each step (exposure, port, SELinux, setuid, world-writable, account) can FAIL
#   - vm-sample-check.sh   an early failure still cleans up (trap on EXIT)
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
 "ports": [{"port": "tcp:22", "reason": "sshd"}, {"port": "udp:68", "reason": "dhcp"}],
 "unconfined": [{"process": "ruya-odd", "reason": "t"}],
 "setid": [{"path": "/usr/bin/passwd", "reason": "t"}],
 "accounts": [{"name": "root", "reason": "t"}]}
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
echo "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"
echo "tcp LISTEN 0 128 [::]:22 [::]:*"
echo "udp UNCONN 0 0 192.168.1.5:68 0.0.0.0:*"
[ -n "${FAKE_EXTRA_PORT:-}" ] && echo "tcp LISTEN 0 5 0.0.0.0:$FAKE_EXTRA_PORT 0.0.0.0:*"
exit 0
SHIMEOF
printf '#!/bin/sh\necho "${FAKE_ENFORCE:-Enforcing}"\n' > "$sec/bin/getenforce"
cat > "$sec/bin/ps" <<'SHIMEOF'
#!/bin/sh
echo "system_u:system_r:init_t:s0 systemd"
echo "system_u:system_r:ruya_t:s0 ruya-aaa"
[ -n "${FAKE_UNCONFINED:-}" ] && echo "system_u:system_r:unconfined_service_t:s0 $FAKE_UNCONFINED"
exit 0
SHIMEOF
cat > "$sec/bin/find" <<'SHIMEOF'
#!/bin/sh
case "$*" in
*-4000*) echo /usr/bin/passwd; [ -n "${FAKE_SETUID:-}" ] && echo "$FAKE_SETUID" ;;
*-0002*) [ -n "${FAKE_WW:-}" ] && echo "$FAKE_WW" ;;
esac
exit 0
SHIMEOF
chmod +x "$sec"/bin/*
printf 'root:x:0:0:root:/root:/bin/bash\nruya-shell:x:990:990::/var/lib/ruya-shell:/usr/sbin/nologin\n' > "$sec/passwd"
printf 'root:!locked:19000::::::\nruya-shell:!*:19000::::::\n' > "$sec/shadow"
runsec() { # env assignments are inherited from the caller's prefix
    SEC_BASELINE="$sec/baseline.json" SEC_UNITDIRS="$sec/units" SEC_PASSWD="${PW:-$sec/passwd}" SEC_SHADOW="${SH:-$sec/shadow}" \
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
expect_contains "an extra port: FAIL" "$out" "FAIL: unexpected listening sockets: tcp:8080"
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

echo
if [ "$fails" = 0 ]; then echo "vm-check tests: all passed"; else echo "vm-check tests: $fails failed"; fi
exit $(( fails > 0 ))
