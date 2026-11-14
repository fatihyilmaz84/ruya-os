#!/usr/bin/env bash
# Looks at the Profiles service inside a running VM (T-120). Copy it over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-profiles-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-profiles-check.sh [introspect|state|security|create|lifecycle|guests]
# No argument = state: what the service lists and what is on disk.
# create: on an empty store, creates an admin "Check Admin" (PIN 1234) and a standard profile
# "Check Kid" over the bus as root (no UI), then prints the state and the modes of the account
# files useradd rewrote (T-126: the unit's UMask must not leak into them).
# guests (RUY-125, after create): temporary guests with PASS/FAIL lines and exit 1 on a failure:
# three CreateGuest are ok and a fourth not-allowed, each user has a uid in 50000-59999 and the
# comment "RuyaOS profile (guest)", ListProfiles never lists one, VerifyPin with a wrong PIN leaves
# ActiveProfile alone, RemoveGuest leaves no user and no home and the next guest's uid is greater,
# Lock wipes every guest. Host fixtures: scripts/test-vm-checks.sh.
set -u
svc=org.ruyaos.Profiles1
path=/org/ruyaos/Profiles1

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
    bash "$0" state
    echo "--- account files (expect 644 passwd/group, 0 shadow/gshadow)"
    stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow
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
        if [ -n "$uid" ] && [ "$uid" -gt "$max" ]; then max="$uid"; fi
        if [ -d "$homes/ruya-$id" ]; then pass "$homes/ruya-$id exists"; else fail "no $homes/ruya-$id"; fi
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

    # shellcheck disable=SC2086 # the ids are words on purpose
    set -- $ids
    first="${1:-}"
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
state)
    echo "--- ListProfiles"
    busctl --system call "$svc" "$path" "$svc" ListProfiles
    echo "--- ActiveProfile"
    busctl --system get-property "$svc" "$path" "$svc" ActiveProfile
    echo "--- /var/lib/ruyaos/profiles.toml"
    if [ -e /var/lib/ruyaos/profiles.toml ]; then
        stat -c '%a %U:%G %n' /var/lib/ruyaos/profiles.toml
        # PINs are stored as argon2id hashes only: show the file with the hashes cut off.
        sed -E 's/(pin_hash *= *"[^"]{0,24})[^"]*/\1…"/' /var/lib/ruyaos/profiles.toml
    else
        echo "(does not exist)"
    fi
    echo "--- unix users ruya-p*"
    getent passwd | grep '^ruya-p' || echo "(none)"
    ls -ld /var/home/ruya-p* 2>/dev/null || echo "(no /var/home/ruya-p*)"
    ;;
*)
    echo "usage: $0 [introspect|state|security|create|lifecycle|guests]" >&2
    exit 2
    ;;
esac
