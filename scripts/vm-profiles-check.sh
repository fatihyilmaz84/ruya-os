#!/usr/bin/env bash
# modes: create guests introspect lifecycle security state private migrate
# Looks at the Profiles service inside a running VM (T-120). Copy it over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-profiles-check.sh image/security-baseline.json root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-profiles-check.sh [introspect|state|security|create|lifecycle|guests|private|migrate]
# No argument = state: what the service lists and what is on disk.
# create: on an empty store, creates an admin "Check Admin" (PIN 1234) and a standard profile
# "Check Kid" over the bus as root (no UI), then prints the state and the modes of the account
# files useradd rewrote (T-126: the unit's UMask must not leak into them). It also asks for a
# profile with role guest (RUY-716, RUY-728): FAIL (exit 1) unless the answer is not-allowed and
# no new ruya-p* user appeared.
# guests (RUY-125, after create): temporary guests with PASS/FAIL lines and exit 1 on a failure:
# three CreateGuest are ok and a fourth not-allowed, each user has a uid in 50000-59999 and the
# comment "RuyaOS profile (guest)" and gid == uid, ListProfiles never lists one, VerifyPin with a wrong PIN leaves
# ActiveProfile alone, RemoveGuest leaves no user and no home and the next guest's uid is greater,
# Lock wipes every guest. Host fixtures: scripts/test-vm-checks.sh.
# private (RUY-1130, after create; copy image/security-baseline.json next to the script): PASS/FAIL,
# exit 1 on a failure: the store directory is 700 root:root and the store 600 root:root, the old
# /var/lib/ruyaos/profiles.toml is gone, ruya-profiles sees its store, and every other ruya-* system
# unit that runs as root, but the baseline's private_state exceptions, lists /var/lib/ruyaos/profiles
# and the aliases (/sysroot) in InaccessiblePaths and, when it runs, sees neither the store nor its
# /sysroot/ostree/deploy/*/var copy from its mount namespace (nsenter -m), and, when it holds
# cap_dac_read_search, has a SystemCallFilter allow list without open_by_handle_at; a transient with
# ruya-play's capabilities answers DENIED for the store through /proc/<ruya-profiles pid>/root (it is
# not dumpable; READ, no answer or a failed systemd-run FAIL), while this root shell can read it (the
# probe is not vacuous). The open window: ruya-profiles' children (useradd, userdel, loginctl,
# getent) are dumpable after execve; this mode does not probe them (ADR-049 closes it).
# migrate (RUY-1130, after create): puts the store back where an earlier image kept it, restarts
# ruya-profiles, and checks that it moved the store (600 root:root, the old file gone, the same
# profiles) and that the admin still signs in with the PIN; ends locked.
set -u
svc=org.ruyaos.Profiles1
path=/org/ruyaos/Profiles1
# The store (RUY-1130): its own 0700 directory; earlier images kept it at $old_store.
# RUYA_STATE_ROOT is for the host fixtures only; the units hide the real $hidden.
state_root="${RUYA_STATE_ROOT:-/var/lib/ruyaos}"
store_dir="$state_root/profiles"
store="$store_dir/profiles.toml"
old_store="$state_root/profiles.toml"
hidden=/var/lib/ruyaos/profiles
# The host's views of the same store (RUYA_PROC_ROOT, RUYA_SYSROOT: host fixtures only).
proc_root="${RUYA_PROC_ROOT:-/proc}"
sysroot="${RUYA_SYSROOT:-/sysroot}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
call() { busctl --system --json=short call "$svc" "$path" "$svc" "$@"; }
# field <n> < reply: data[n] of a busctl --json reply ("" when it is not one)
field() {
    python3 -c 'import json, sys
try: print(json.load(sys.stdin)["data"][int(sys.argv[1])])
except Exception: print("")' "$1" | tr -d '\r'
}
# first_fields < reply: the first member of every struct in data[0], one per line
first_fields() {
    python3 -c 'import json, sys
try:
    for row in json.load(sys.stdin)["data"][0]: print(row[0])
except Exception: pass' | tr -d '\r'
}
# profile_users: the Unix users of every profile and guest (ruya-p*), sorted, one per line
profile_users() { getent passwd | tr -d '\r' | awk -F: '$1 ~ /^ruya-p/ { print $1 }' | sort; }
# modes_of <path>: "<octal mode> <user>:<group>" ("" when it is not there)
modes_of() { stat -c '%a %U:%G' "$1" 2>/dev/null | tr -d '\r'; }
# expect_modes <path> <want>
expect_modes() {
    local got
    got="$(modes_of "$1")"
    if [ "$got" = "$2" ]; then pass "$1 is $2"; else fail "$1 is '${got:-missing}', want $2"; fi
}
# prop <name> < `systemctl show -p ...` output: the value of one property
prop() { tr -d '\r' | sed -n "s/^$1=//p" | head -1; }

case "${1:-state}" in
introspect)
    busctl --system introspect "$svc" "$path" "$svc"
    ;;
security)
    systemctl is-active ruya-profiles
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
    ;;
create)
    echo "--- CreateProfile: first admin (empty store, no admin credentials needed)"
    busctl --system call "$svc" "$path" "$svc" CreateProfile sssss "" "" "Check Admin" admin 1234
    admin="$(busctl --system call "$svc" "$path" "$svc" ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
    echo "--- CreateProfile: standard profile, with the admin ($admin) PIN"
    busctl --system call "$svc" "$path" "$svc" CreateProfile sssss "$admin" 1234 "Check Kid" standard ""
    echo "--- CreateProfile: role guest (RUY-716, no new kept guests): expect not-allowed, no user made"
    before="$(profile_users)"
    out="$(call CreateProfile sssss "$admin" 1234 "Check Guest" guest "")"
    echo "$out"
    st="$(echo "$out" | field 0)"
    if [ "$st" = not-allowed ]; then pass "CreateProfile role guest: not-allowed"; else fail "CreateProfile role guest answered '$st', want not-allowed: $out"; fi
    made="$(comm -13 <(echo "$before") <(profile_users) | tr '\n' ' ')"
    if [ -z "${made// /}" ]; then pass "CreateProfile role guest made no user"; else fail "CreateProfile role guest made the user(s) $made"; fi
    bash "$0" state
    echo "--- account files (expect 644 passwd/group, 0 shadow/gshadow)"
    stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow
    if [ "$fails" != 0 ]; then echo "$fails CHECK(S) FAILED"; exit 1; fi
    ;;
lifecycle)
    # T-118: after `create`, rename and delete the standard profile (p2) as the admin (p1, PIN 1234),
    # then show that the admin is refused for its own deletion and that the Unix user and home are gone.
    echo "--- RenameProfile p2 -> 'Renamed Kid'"
    busctl --system call "$svc" "$path" "$svc" RenameProfile ssss p1 1234 p2 "Renamed Kid"
    busctl --system call "$svc" "$path" "$svc" ListProfiles
    echo "--- DeleteProfile p1 (last admin): expect not-allowed"
    busctl --system call "$svc" "$path" "$svc" DeleteProfile sss p1 1234 p1
    echo "--- DeleteProfile p2"
    busctl --system call "$svc" "$path" "$svc" DeleteProfile sss p1 1234 p2
    bash "$0" state
    echo "--- account files (expect 644 passwd/group, 0 shadow/gshadow)"
    stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow
    ;;
guests)
    # RUY-125: temporary guests over the bus as root, with assertions. Needs an admin to sign in:
    # after `create` that is p1 with PIN 1234 (ADMIN_ID / ADMIN_PIN override it). Starts with a
    # Lock and ends locked (the picker). RUYA_HOME_ROOT is for the host fixtures only.
    admin="${ADMIN_ID:-p1}"
    admin_pin="${ADMIN_PIN:-1234}"
    homes="${RUYA_HOME_ROOT:-/var/home}"
    etc="${RUYA_ETC_ROOT:-/etc}"
    active() {
        busctl --system --json=short get-property "$svc" "$path" "$svc" ActiveProfile | python3 -c 'import json, sys
try: print(json.load(sys.stdin)["data"])
except Exception: print("?")' | tr -d '\r'
    }
    # guest_uid <id>: the uid of ruya-<id> when it is a temporary guest user (comment, home), else ""
    guest_uid() {
        getent passwd "ruya-$1" | tr -d '\r' |
            awk -F: -v home="/var/home/ruya-$1" '$5 == "RuyaOS profile (guest)" && $6 == home { print $3 }'
    }
    # guest_gid <id>: the gid in the passwd line of the guest user ruya-<id>
    guest_gid() {
        getent passwd "ruya-$1" | awk -F: '{ print $4 }' | tr -d "[:cntrl:]"
    }
    gone() { # <id> <step>: no user and no home left
        if getent passwd "ruya-$1" >/dev/null; then fail "$2 left the user ruya-$1"; return; fi
        if [ -e "$homes/ruya-$1" ]; then fail "$2 left $homes/ruya-$1"; return; fi
        pass "$2 left no user ruya-$1 and no $homes/ruya-$1"
    }

    call Lock >/dev/null
    out="$(call SwitchTo ss "$admin" "$admin_pin")"
    if [ "$(echo "$out" | field 0)" = ok ]; then pass "SwitchTo $admin"; else fail "SwitchTo $admin: $out"; fi

    ids=""
    for n in 1 2 3; do
        out="$(call CreateGuest)"
        st="$(echo "$out" | field 0)"; id="$(echo "$out" | field 1)"; num="$(echo "$out" | field 2)"
        if [ "$st" = ok ] && [ "$num" = "$n" ]; then pass "CreateGuest $n: ok, $id, number $num"; else fail "CreateGuest $n: $out"; fi
        [ -n "$id" ] && ids="$ids $id"
    done
    out="$(call CreateGuest)"
    st="$(echo "$out" | field 0)"; id="$(echo "$out" | field 1)"
    if [ "$st" = not-allowed ]; then pass "a fourth CreateGuest is not-allowed"; else fail "a fourth CreateGuest: $out"; fi
    [ -n "$id" ] && ids="$ids $id"

    max=0
    for id in $ids; do
        uid="$(guest_uid "$id")"
        if [ -n "$uid" ] && [ "$uid" -ge 50000 ] && [ "$uid" -le 59999 ]; then
            pass "ruya-$id: uid $uid, comment 'RuyaOS profile (guest)'"
        else
            fail "ruya-$id is no guest user in 50000-59999: $(getent passwd "ruya-$id" || echo 'no such user')"
        fi
        gid="$(guest_gid "$id")"
        if [ -n "$uid" ] && [ "$gid" = "$uid" ]; then pass "ruya-$id: gid $gid equals its uid"; else fail "ruya-$id: gid '$gid' is not its uid '$uid'"; fi
        if [ -n "$uid" ] && [ "$uid" -gt "$max" ]; then max="$uid"; fi
        if [ -d "$homes/ruya-$id" ]; then pass "$homes/ruya-$id exists"; else fail "no $homes/ruya-$id"; fi
        # RUY-652: useradd -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 leaves no subordinate id range
        if grep -qs "^ruya-$id:" "$etc/subuid" "$etc/subgid"; then
            fail "ruya-$id has a line in $etc/subuid or $etc/subgid"
        else
            pass "ruya-$id: no $etc/subuid or $etc/subgid line"
        fi
    done

    listed=" $(call ListProfiles | first_fields | tr '\n' ' ') "
    leaked=""
    for id in $ids; do case "$listed" in *" $id "*) leaked="$leaked $id" ;; esac; done
    if [ -z "$leaked" ]; then pass "ListProfiles lists no guest"; else fail "ListProfiles lists the guest(s)$leaked"; fi
    listed=" $(call ListGuests | first_fields | tr '\n' ' ') "
    missing=""
    for id in $ids; do case "$listed" in *" $id "*) ;; *) missing="$missing $id" ;; esac; done
    if [ -z "$missing" ]; then pass "ListGuests lists every guest"; else fail "ListGuests misses$missing"; fi

    out="$(call VerifyPin ss "$admin" 0000)"
    if [ "$(echo "$out" | field 0)" = wrong-pin ]; then pass "VerifyPin with a wrong PIN: wrong-pin"; else fail "VerifyPin with a wrong PIN: $out"; fi
    now="$(active)"
    if [ "$now" = "$admin" ]; then pass "ActiveProfile is still $admin"; else fail "VerifyPin changed ActiveProfile to '$now'"; fi
    call VerifyPin ss "$admin" "$admin_pin" >/dev/null # a right PIN resets the failure counter

    read -r first _ <<< "$ids"
    out="$(call RemoveGuest s "$first")"
    if [ "$(echo "$out" | field 0)" = ok ]; then pass "RemoveGuest $first"; else fail "RemoveGuest $first: $out"; fi
    gone "$first" RemoveGuest
    out="$(call CreateGuest)"
    id="$(echo "$out" | field 1)"
    [ -n "$id" ] && ids="$ids $id"
    uid="$(guest_uid "$id")"
    if [ -n "$uid" ] && [ "$uid" -gt "$max" ]; then
        pass "the new guest $id has uid $uid, greater than $max"
    else
        fail "the new guest's uid '$uid' is not greater than $max: $out"
    fi

    call Lock >/dev/null
    left="$(call ListGuests | first_fields | tr '\n' ' ')"
    if [ -z "${left// /}" ]; then pass "Lock: ListGuests is empty"; else fail "Lock left the guests $left"; fi
    for id in $ids; do gone "$id" Lock; done

    if [ "$fails" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
    ;;
private)
    # RUY-1130: the PIN store is ruya-profiles' alone. A mode does not stop root, so every other
    # root unit must have the directory hidden in its own mount namespace, also where /var comes
    # from (/sysroot), and ruya-profiles itself must not be dumpable (/proc/<pid>/root).
    baseline="${PROFILES_BASELINE:-}"
    for c in "$here/security-baseline.json" "$here/../image/security-baseline.json" /root/security-baseline.json; do
        [ -n "$baseline" ] || { [ -f "$c" ] && baseline="$c"; }
    done
    if [ -z "$baseline" ]; then echo "FAIL: no security-baseline.json next to the script: copy image/security-baseline.json over"; exit 1; fi
    # private_state_of <field>: the entry's aliases, or its exception units, one line, space-separated.
    # Python prints every entry and bash picks this one: Git Bash would turn a path handed to a
    # Windows python (argument or environment) into a Windows path.
    private_state_of() {
        python3 -c 'import json, sys
for e in json.load(open(sys.argv[1], encoding="utf-8")).get("private_state", []):
    v = e.get(sys.argv[2], [])
    print(e["path"] + "|" + " ".join(x["unit"] if isinstance(x, dict) else x for x in v))' "$baseline" "$1" |
            tr -d '\r' | awk -F'|' -v p="$hidden" '$1 == p { print $2 }'
    }
    aliases="$(private_state_of aliases)"
    exceptions=" $(private_state_of exceptions) "
    expect_modes "$store_dir" "700 root:root"
    expect_modes "$store" "600 root:root"
    if [ -e "$old_store" ]; then fail "the old store $old_store is still there"; else pass "no old store $old_store"; fi
    # The store's other view, which a unit must hide as well (else the check of it is vacuous).
    if ls -d "$sysroot"/ostree/deploy/*"$hidden" >/dev/null 2>&1; then
        pass "the store's directory is also at $sysroot/ostree/deploy/*$hidden (hidden by the /sysroot alias)"
    else
        fail "no $sysroot/ostree/deploy/*$hidden: the alias probe below would prove nothing"
    fi
    owner="$(systemctl show ruya-profiles.service -p MainPID | prop MainPID)"
    if [ "${owner:-0}" -gt 0 ] && nsenter -m -t "$owner" -- test -e "$hidden/profiles.toml"; then
        pass "ruya-profiles (pid $owner) sees its store"
    else
        fail "ruya-profiles (pid ${owner:-none}) does not see $hidden/profiles.toml (not running, or no store: run create first)"
    fi
    # /proc/<pid>/root: open to this full-capability root shell, closed to ruya-play's capabilities.
    if [ "${owner:-0}" -gt 0 ] && [ -e "$proc_root/$owner/root$hidden/profiles.toml" ]; then
        pass "this root shell reads $proc_root/$owner/root$hidden/profiles.toml (the probe can succeed)"
    else
        fail "this root shell cannot read $proc_root/${owner:-none}/root$hidden/profiles.toml: the ruya-play probe would prove nothing"
    fi
    # The transient says what it saw: DENIED is the only pass. It first checks that it can walk its own
    # /proc/self/root, so an empty answer, a systemd-run that did not start (a property it refused) or
    # a broken probe is a FAIL, never a pass.
    play_caps="$(systemctl show ruya-play.service -p CapabilityBoundingSet | prop CapabilityBoundingSet)"
    probe='if ! test -e /proc/self/root/; then echo SELFCHECK-FAILED; exit 0; fi
if test -e "/proc/$1/root$2/profiles.toml"; then echo READ; else echo DENIED; fi'
    verdict="$(systemd-run --quiet --wait --pipe --collect -p "CapabilityBoundingSet=$play_caps" -p NoNewPrivileges=yes \
        /bin/sh -c "$probe" sh "${owner:-0}" "$hidden" 2>&1)"; rc=$?
    verdict="$(echo "$verdict" | tr -d '\r' | tail -1)"
    if [ "$rc" = 0 ] && [ "$verdict" = DENIED ]; then
        pass "a root process with ruya-play's capabilities: DENIED reading the store through /proc/$owner/root"
    elif [ "$verdict" = READ ]; then
        fail "a root process with ruya-play's capabilities ($play_caps): READ the store through /proc/$owner/root: ruya-profiles is dumpable"
    else
        fail "the /proc/$owner/root probe with ruya-play's capabilities did not answer DENIED or READ (exit $rc): '$verdict'"
    fi
    for unit in $(systemctl list-unit-files --type=service --no-legend 'ruya-*' | tr -d '\r' | awk '{ print $1 }'); do
        [ "$unit" = ruya-profiles.service ] && continue
        name="$unit"
        case "$unit" in *@.service) name="${unit%@.service}@check.service" ;; esac
        props="$(systemctl show "$name" -p User -p DynamicUser -p InaccessiblePaths -p MainPID -p CapabilityBoundingSet -p SystemCallFilter)"
        user="$(echo "$props" | prop User)"
        if [ "$(echo "$props" | prop DynamicUser)" = yes ] || { [ -n "$user" ] && [ "$user" != root ]; }; then
            echo "skip: $unit runs as ${user:-a dynamic user} (the 0700 root directory is closed to it)"
            continue
        fi
        case "$exceptions" in *" $unit "*)
            echo "skip: $unit is a private_state exception (its reason: image/security-baseline.json)"
            continue ;;
        esac
        paths=" $(echo "$props" | prop InaccessiblePaths) "
        for p in "$hidden" $aliases; do
            case "$paths" in
            *" $p "*) pass "$unit hides $p (InaccessiblePaths)" ;;
            *) fail "$unit runs as root and does not hide $p: InaccessiblePaths='${paths# }'" ;;
            esac
        done
        # CAP_DAC_READ_SEARCH opens a file by handle (open_by_handle_at) past any mount hiding: such a unit's
        # filter, as systemd expanded it, must be an allow list without that call.
        case " $(echo "$props" | prop CapabilityBoundingSet) " in
        *" cap_dac_read_search "*)
            filter="$(echo "$props" | prop SystemCallFilter)"
            case "$filter" in
            "" | "~"*) fail "$unit holds cap_dac_read_search and its SystemCallFilter is no allow list: '${filter:0:60}'" ;;
            *) case " $filter " in
                *" open_by_handle_at "*) fail "$unit holds cap_dac_read_search and its SystemCallFilter allows open_by_handle_at" ;;
                *) pass "$unit holds cap_dac_read_search; its SystemCallFilter has no open_by_handle_at" ;;
                esac ;;
            esac ;;
        esac
        pid="$(echo "$props" | prop MainPID)"
        if [ "${pid:-0}" -gt 0 ]; then
            if nsenter -m -t "$pid" -- test -e "$hidden/profiles.toml"; then
                fail "$unit (pid $pid) sees $hidden/profiles.toml in its mount namespace"
            else
                pass "$unit (pid $pid) cannot see $hidden/profiles.toml"
            fi
            if nsenter -m -t "$pid" -- sh -c "ls -d /sysroot/ostree/deploy/*$hidden" >/dev/null 2>&1; then
                fail "$unit (pid $pid) sees the store's directory under /sysroot/ostree/deploy/*/var"
            else
                pass "$unit (pid $pid) cannot see it under /sysroot either"
            fi
        fi
    done
    if [ "$fails" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
    ;;
migrate)
    # RUY-1130: an earlier image's store (the old path, no directory copy) is moved at the next start,
    # and a PIN still signs in. ADMIN_ID / ADMIN_PIN as in guests.
    admin="${ADMIN_ID:-p1}"
    admin_pin="${ADMIN_PIN:-1234}"
    if [ ! -e "$store" ]; then echo "FAIL: no $store: run create first"; exit 1; fi
    before="$(call ListProfiles | first_fields | sort | tr '\n' ' ')"
    systemctl stop ruya-profiles.service
    mv "$store" "$old_store"
    echo "--- the store is back at $old_store, as an earlier image left it; starting ruya-profiles"
    systemctl start ruya-profiles.service
    if [ -e "$old_store" ]; then fail "the old store $old_store is still there after the start"; else pass "the old store $old_store is gone"; fi
    expect_modes "$store" "600 root:root"
    expect_modes "$store_dir" "700 root:root"
    after="$(call ListProfiles | first_fields | sort | tr '\n' ' ')"
    if [ -n "${before// /}" ] && [ "$after" = "$before" ]; then pass "ListProfiles lists the same profiles: $after"; else fail "ListProfiles lists '$after', before the move '$before'"; fi
    out="$(call SwitchTo ss "$admin" "$admin_pin")"
    if [ "$(echo "$out" | field 0)" = ok ]; then pass "SwitchTo $admin with the PIN after the move"; else fail "SwitchTo $admin after the move: $out"; fi
    call Lock >/dev/null
    if [ "$fails" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
    ;;
state)
    echo "--- ListProfiles"
    busctl --system call "$svc" "$path" "$svc" ListProfiles
    echo "--- ActiveProfile"
    busctl --system get-property "$svc" "$path" "$svc" ActiveProfile
    echo "--- $store"
    if [ -e "$store" ]; then
        stat -c '%a %U:%G %n' "$store_dir" "$store"
        # PINs are stored as argon2id hashes only: show the file with the hashes cut off.
        sed -E 's/(pin_hash *= *"[^"]{0,24})[^"]*/\1…"/' "$store"
    else
        echo "(does not exist)"
    fi
    if [ -e "$old_store" ]; then echo "--- $old_store is still there (an earlier image's store, RUY-1130)"; fi
    echo "--- unix users ruya-p*"
    getent passwd | grep '^ruya-p' || echo "(none)"
    ls -ld /var/home/ruya-p* 2>/dev/null || echo "(no /var/home/ruya-p*)"
    ;;
*)
    echo "usage: $0 [introspect|state|security|create|lifecycle|guests|private|migrate]" >&2
    exit 2
    ;;
esac
