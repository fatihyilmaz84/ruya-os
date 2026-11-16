#!/usr/bin/env bash
# Checks ruya-notifications (org.ruyaos.Notifications1, RUY-730) inside a running VM, as root over busctl.
# Copy it (and image/security-baseline.json) over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-notifications-check.sh image/security-baseline.json root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-notifications-check.sh [check|state]
# check (the default) prints PASS/FAIL lines and exits 1 on a failure:
#   (a) the unit is active and its `systemd-analyze security` exposure is within security-baseline.json
#   (b) a Post for the signed-in profile is in List, unread, and Added is seen; MarkRead clears unread (Changed seen)
#   (c) the item survives `systemctl restart ruya-notifications` with the same id; a new Post gets a higher id
#   (d) a keyed Post replaces the earlier one (Removed "replaced"); Withdraw removes it (Removed "withdrawn")
#   (e) a source switched off (SourcesEnabled) keeps nothing: Post answers ok with id 0, List does not grow
#   (f) a Post as nobody is refused (by the bus policy, or "forbidden")
#   (g) a setting written (ToastSeconds) survives a service restart
#   (h) the shell: a Post from ruya-shell's uid works; when the service goes away the shell's journal says
#       "Notifications1 is not on the bus; notifications are not kept"; when it is back the shell reads the
#       settings again (a GetAll from the shell, seen with busctl monitor). The shell has no test hook that
#       makes it toast, so its own Post of a controller toast is the owner's look on the Dell.
# Nobody signed in: it signs ADMIN_ID (default the first profile; one "Check Admin", PIN 1234, is made on an
# empty store) in with ADMIN_PIN (default 1234) and locks again at the end. What it changed (its items, the
# setting, the source switches) is put back by an exit trap, also after a FAIL.
# state: the unit, the profile files' modes and the active profile's List.
# Host fixtures: scripts/test-vm-checks.sh (a fake service; each assertion can FAIL).
set -u
svc=org.ruyaos.Notifications1
path=/org/ruyaos/Notifications1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
unit=ruya-notifications.service
state_dir="${NOTIF_STATE_DIR:-/var/lib/ruyaos/notifications}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseline="${NOTIF_BASELINE:-}"
for c in "$here/security-baseline.json" "$here/../image/security-baseline.json" /root/security-baseline.json; do
    [ -n "$baseline" ] || { [ -f "$c" ] && baseline="$c"; }
done

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
call() { busctl --system --json=short call "$svc" "$path" "$svc" "$@"; }
pcall() { busctl --system --json=short call "$psvc" "$ppath" "$psvc" "$@"; }
# py <program> [args...] < input: a small python3 helper; prints "" when the input is not what it expects
py() { python3 -I -c "$@" | tr -d '\r'; }
# field <n> < reply: data[n] of a busctl --json reply
field() {
    py 'import json, sys
try: print(json.load(sys.stdin)["data"][int(sys.argv[1])])
except Exception: print("")' "$1"
}
prop() { # <name>: the property's value as JSON
    busctl --system --json=short get-property "$svc" "$path" "$svc" "$1" | py 'import json, sys
try: print(json.dumps(json.load(sys.stdin)["data"]))
except Exception: print("")'
}
active() {
    busctl --system --json=short get-property "$psvc" "$ppath" "$psvc" ActiveProfile | py 'import json, sys
try: print(json.load(sys.stdin)["data"])
except Exception: print("")'
}
# post <profile> <key> <source> <title>: the Post reply (status and id as JSON)
post() { call Post 'ssssssssa(ss)sb' "$1" "$2" "$3" "" info "$4" "" "" 0 normal false; }
# items <profile>: "id unread title" per item of List
items() {
    call List s "$1" | py 'import json, sys
try:
    for it in json.load(sys.stdin)["data"][0]: print(it[0], str(it[10]).lower(), it[4])
except Exception: pass'
}
has_id() { items "$1" | awk -v id="$2" '$1 == id { found = 1 } END { exit !found }'; }
unread_of() { items "$1" | awk -v id="$2" '$1 == id { print $2 }'; }
count() { items "$1" | wc -l | tr -d ' '; }
name_up() { busctl --system status "$svc" >/dev/null 2>&1; }
wait_up() { # waits for the bus name, up to 20 s
    n=0
    while [ "$n" -lt 100 ]; do name_up && return 0; sleep 0.2; n=$((n + 1)); done
    return 1
}
restart_service() {
    systemctl restart "$unit" && wait_up
}

work="$(mktemp -d)"
mon=""
mon_start() { # busctl monitor of the service's traffic into $work/mon.log (signals and calls to it)
    : > "$work/mon.log"
    stdbuf -oL busctl --system --json=short monitor "$svc" > "$work/mon.log" 2>&1 &
    mon=$!
    sleep 1
}
mon_stop() { [ -n "$mon" ] && kill "$mon" 2>/dev/null; mon=""; }
# seen <member> <python condition on d (the payload's data) and m (the message)>: is such a message in the log?
seen() {
    py 'import json, sys
member, cond = sys.argv[1], sys.argv[2]
hit = False
for line in open(sys.argv[3], encoding="utf-8", errors="replace"):
    try: m = json.loads(line)
    except Exception: continue
    if m.get("member") != member: continue
    d = (m.get("payload") or {}).get("data") or []
    try:
        if eval(cond): hit = True
    except Exception: pass
print("yes" if hit else "no")' "$1" "$2" "$work/mon.log"
}
wait_seen() { # <member> <cond>: up to 5 s (NOTIF_WAIT tries of 0.2 s; the host fixtures shorten it)
    n=0
    while [ "$n" -lt "${NOTIF_WAIT:-25}" ]; do [ "$(seen "$1" "$2")" = yes ] && return 0; sleep 0.2; n=$((n + 1)); done
    return 1
}

# --- put back what the check changed (also after a FAIL) ---
signed_in_by_us=0
posted=""
toast_old=""
sources_old=""
on_exit() {
    mon_stop
    if name_up; then
        for id in $posted; do call Dismiss u "$id" >/dev/null 2>&1; done
        call Withdraw s vm-check-key >/dev/null 2>&1
        [ -n "$toast_old" ] && busctl --system set-property "$svc" "$path" "$svc" ToastSeconds u "$toast_old" >/dev/null 2>&1
        if [ -n "$sources_old" ]; then
            # shellcheck disable=SC2046 # the a{sb} arguments are words on purpose
            busctl --system set-property "$svc" "$path" "$svc" SourcesEnabled 'a{sb}' $(echo "$sources_old" | sources_args) >/dev/null 2>&1
        fi
    fi
    [ "$signed_in_by_us" = 1 ] && pcall Lock >/dev/null 2>&1
    rm -rf "$work"
}
trap on_exit EXIT
trap 'exit 1' INT TERM HUP
# sources_args [key value]... < JSON object: busctl's a{sb} arguments, with the extra pairs set
sources_args() {
    py 'import json, sys
try: m = json.load(sys.stdin)
except Exception: m = {}
extra = sys.argv[1:]
for k, v in zip(extra[::2], extra[1::2]): m[k] = v == "true"
print(len(m), " ".join("%s %s" % (k, "true" if v else "false") for k, v in sorted(m.items())))' "$@"
}

case "${1:-check}" in
state)
    systemctl status "$unit" --no-pager | head -8
    ls -la "$state_dir" 2>/dev/null || echo "(no $state_dir)"
    a="$(active)"; echo "active profile: \"$a\""
    [ -n "$a" ] && items "$a"
    exit 0
    ;;
check) ;;
*) echo "usage: $0 [check|state]" >&2; exit 2 ;;
esac

echo "--- (a) the unit and its hardening"
if [ "$(systemctl is-active "$unit" 2>/dev/null | tr -d '\r')" = active ]; then pass "$unit is active"; else fail "$unit is not active"; fi
exposure="$(systemd-analyze security --no-pager "$unit" 2>&1 | sed -n 's/.*Overall exposure level for [^:]*: \([0-9][0-9.]*\).*/\1/p' | tail -1 | tr -d '\r')"
limit=""
[ -n "$baseline" ] && limit="$(py 'import json, sys
try: print(json.load(open(sys.argv[1], encoding="utf-8"))["units"]["ruya-notifications.service"]["max_exposure"])
except Exception: print("")' "$baseline")"
if [ -z "$exposure" ]; then
    fail "systemd-analyze security $unit gave no exposure"
elif [ -z "$limit" ]; then
    fail "no ruya-notifications.service in the baseline (${baseline:-not found})"
elif python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$exposure" "$limit"; then
    pass "exposure $exposure (baseline $limit)"
else
    fail "exposure $exposure is above the baseline $limit"
fi
name_up || { fail "$svc is not on the bus"; echo "$fails CHECK(S) FAILED"; exit 1; }

profile="$(active)"
if [ -z "$profile" ]; then
    admin="${ADMIN_ID:-}"
    if [ -z "$admin" ]; then
        admin="$(pcall ListProfiles | py 'import json, sys
try: print(json.load(sys.stdin)["data"][0][0][0])
except Exception: print("")')"
    fi
    if [ -z "$admin" ]; then
        pcall CreateProfile sssss "" "" "Check Admin" admin 1234 >/dev/null
        admin="$(pcall ListProfiles | py 'import json, sys
try: print(json.load(sys.stdin)["data"][0][0][0])
except Exception: print("")')"
    fi
    out="$(pcall SwitchTo ss "$admin" "${ADMIN_PIN:-1234}")"
    if [ "$(echo "$out" | field 0)" = ok ]; then signed_in_by_us=1; pass "signed $admin in for the check"; else fail "cannot sign $admin in: $out"; fi
    sleep 1
    profile="$(active)"
fi
[ -n "$profile" ] || { fail "nobody is signed in"; echo "$fails CHECK(S) FAILED"; exit 1; }
echo "the signed-in profile: $profile"

echo "--- (b) Post, List, Added, MarkRead"
mon_start
tag="vm-check-$$"
out="$(post "$profile" "" system "$tag one")"
st="$(echo "$out" | field 0)"; id1="$(echo "$out" | field 1)"
if [ "$st" = ok ] && [ "${id1:-0}" -gt 0 ] 2>/dev/null; then pass "Post: ok, id $id1"; posted="$posted $id1"; else fail "Post: $out"; id1=0; fi
if has_id "$profile" "$id1"; then pass "List has item $id1"; else fail "List does not have item $id1"; fi
if [ "$(unread_of "$profile" "$id1")" = true ]; then pass "item $id1 is unread"; else fail "item $id1 is not unread: '$(unread_of "$profile" "$id1")'"; fi
if wait_seen Added "d[0] == '$profile' and d[1][0] == $id1"; then pass "Added($profile, $id1) was seen"; else fail "no Added for item $id1"; fi
out="$(call MarkRead s "$profile")"
[ "$(echo "$out" | field 0)" = ok ] || fail "MarkRead: $out"
if [ "$(unread_of "$profile" "$id1")" = false ]; then pass "MarkRead cleared unread"; else fail "MarkRead left item $id1 unread"; fi
if wait_seen Changed "d[0] == '$profile'"; then pass "Changed($profile) was seen"; else fail "no Changed after MarkRead"; fi
mon_stop

echo "--- (c) a restart keeps the item and its id; the next id is higher"
suid="$(id -u ruya-shell 2>/dev/null | tr -d '\r')"
mon_start
t0="$(date +%s)"
restart_service || fail "$svc did not come back after the restart"
if has_id "$profile" "$id1" && items "$profile" | grep -q "$tag one"; then pass "item $id1 survived the restart"; else fail "item $id1 is gone after the restart"; fi
out="$(post "$profile" "" system "$tag two")"
id2="$(echo "$out" | field 1)"
[ -n "$id2" ] && [ "$id2" != 0 ] && posted="$posted $id2"
if [ "${id2:-0}" -gt "$id1" ] 2>/dev/null; then pass "the next id $id2 is above $id1"; else fail "the next id '$id2' is not above $id1: $out"; fi

echo "--- (h) the shell sees the restart"
if [ -z "$suid" ]; then
    fail "no ruya-shell user"
else
    if journalctl -b _UID="$suid" --since "@$t0" --no-pager -o cat 2>/dev/null | grep -a -q "Notifications1 is not on the bus; notifications are not kept"; then
        pass "the shell's journal says the service went away"
    else
        fail "no 'Notifications1 is not on the bus; notifications are not kept' in the shell's journal after the restart"
    fi
    # busctl list: NAME PID PROCESS USER CONNECTION ...; the shell's unique names
    shell_names="$(busctl --system list --no-legend 2>/dev/null | tr -d '\r' | awk '$1 ~ /^:/ && $4 == "ruya-shell" { print $1 }' | tr '\n' ' ')"
    if wait_seen GetAll "m.get('sender') in '$shell_names'.split() and d[0] == '$svc'"; then
        pass "the shell read the settings again when the service was back (GetAll)"
    else
        fail "no GetAll from the shell ($shell_names) after the restart"
    fi
    out="$(runuser -u ruya-shell -- busctl --system --json=short call "$svc" "$path" "$svc" Post 'ssssssssa(ss)sb' "$profile" "" devices "" info "$tag shell" "" "" 0 normal false 2>&1)"
    sid="$(echo "$out" | field 1)"
    if [ "$(echo "$out" | field 0)" = ok ] && [ "${sid:-0}" -gt 0 ] 2>/dev/null; then pass "a Post from ruya-shell's uid works (id $sid)"; posted="$posted $sid"; else fail "a Post from ruya-shell: $out"; fi
fi
mon_stop

echo "--- (d) keyed replace and Withdraw"
mon_start
out="$(post "$profile" vm-check-key updates "$tag keyed A")"; k1="$(echo "$out" | field 1)"
out="$(post "$profile" vm-check-key updates "$tag keyed B")"; k2="$(echo "$out" | field 1)"
if [ "${k1:-0}" -gt 0 ] && [ "${k2:-0}" -gt "${k1:-0}" ] 2>/dev/null && ! has_id "$profile" "$k1" && has_id "$profile" "$k2"; then
    pass "the keyed Post $k2 replaced $k1"
else
    fail "the keyed Post did not replace: ids '$k1' '$k2', List: $(items "$profile" | grep "$tag keyed" | tr '\n' ';')"
fi
if wait_seen Removed "d[0] == '$profile' and ${k1:-0} in d[1] and d[2] == 'replaced'"; then pass "Removed($k1, replaced) was seen"; else fail "no Removed 'replaced' for $k1"; fi
out="$(call Withdraw s vm-check-key)"
if [ "$(echo "$out" | field 0)" = ok ] && ! has_id "$profile" "$k2"; then pass "Withdraw removed $k2"; else fail "Withdraw: $out; $k2 still listed: $(has_id "$profile" "$k2" && echo yes || echo no)"; fi
if wait_seen Removed "d[0] == '$profile' and ${k2:-0} in d[1] and d[2] == 'withdrawn'"; then pass "Removed($k2, withdrawn) was seen"; else fail "no Removed 'withdrawn' for $k2"; fi
mon_stop

echo "--- (e) a source that is off keeps nothing"
sources_old="$(prop SourcesEnabled)"
[ -n "$sources_old" ] || sources_old="{}"
# shellcheck disable=SC2046 # the a{sb} arguments are words on purpose
busctl --system set-property "$svc" "$path" "$svc" SourcesEnabled 'a{sb}' $(echo "$sources_old" | sources_args store false) || fail "cannot switch the store source off"
before="$(count "$profile")"
out="$(post "$profile" "" store "$tag store")"
after="$(count "$profile")"
if [ "$(echo "$out" | field 0)" = ok ] && [ "$(echo "$out" | field 1)" = 0 ] && [ "$after" = "$before" ]; then
    pass "Post of a switched-off source: ok, id 0, nothing kept"
else
    fail "a switched-off source: $out, List $before -> $after"
    sid="$(echo "$out" | field 1)"; [ -n "$sid" ] && [ "$sid" != 0 ] && posted="$posted $sid"
fi

echo "--- (f) a Post as nobody is refused"
out="$(runuser -u nobody -- busctl --system --json=short call "$svc" "$path" "$svc" Post 'ssssssssa(ss)sb' "$profile" "" system "" info "$tag nobody" "" "" 0 normal false 2>&1)"; rc=$?
if [ "$rc" != 0 ] && echo "$out" | grep -qi "access.*denied\|AccessDenied"; then
    pass "nobody: refused by the bus policy"
elif [ "$rc" = 0 ] && [ "$(echo "$out" | field 0)" = forbidden ]; then
    pass "nobody: forbidden"
else
    fail "a Post as nobody was not refused (exit $rc): $out"
    nid="$(echo "$out" | field 1)"; [ -n "$nid" ] && [ "$nid" != 0 ] && posted="$posted $nid"
fi

echo "--- (g) a setting survives a restart"
toast_old="$(prop ToastSeconds)"
want=11; [ "$toast_old" = 11 ] && want=12
busctl --system set-property "$svc" "$path" "$svc" ToastSeconds u "$want" || fail "cannot set ToastSeconds"
restart_service || fail "$svc did not come back after the restart"
got="$(prop ToastSeconds)"
if [ "$got" = "$want" ]; then pass "ToastSeconds $want survived the restart"; else fail "ToastSeconds is '$got' after the restart, not $want"; fi

if [ "$fails" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
