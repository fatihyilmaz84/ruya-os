#!/usr/bin/env bash
# Checks the play ledger of ruya-session (org.ruyaos.Session1: ReportPresence, ListSessions,
# GetTotals, ClearHistory, UsageChanged; T-247) inside a running VM, as root, over the system bus
# as ruya-shell. Like vm-session-check.sh it builds a tiny local Flatpak repository (a runtime made
# of the guest's own bash and sleep, one app that sleeps), installs it system-wide and creates
# the profiles it needs: the admin "Check Admin" (PIN 1234) and the standard profiles
# "Check Kid" and "Check Other" (no PIN), all deleted again at the end. Boot with plain
# smoke-test.ps1 -Keep, then:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-usage-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-usage-check.sh [check|security|clean]
# The check plays the shell: it says which profile is active (Profiles1.SwitchTo) and, every 5 s,
# that the sleeper is in front (ReportPresence). It takes about three minutes (real waits of 40 s
# and 35 s: the service counts monotonic seconds, nothing to fake).
set -u
svc=org.ruyaos.Session1
path=/org/ruyaos/Session1
ifc=org.ruyaos.Session1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
rt=org.ruyaos.TestRuntime
sleeper=org.ruyaos.TestUsageSleeper
remote=ruyaos-usage-test
work=/var/lib/ruya-usage-test
store=/var/lib/ruya-session/usage
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

as_shell() { runuser -u ruya-shell -- "$@"; }
sess() { as_shell busctl --system --json=short call "$svc" "$path" "$ifc" "$@"; }
prof() { as_shell busctl --system call "$psvc" "$ppath" "$psvc" "$@"; }
# The numbers of the foreground_seconds keys in a --json=short answer, one per line.
fg_of() { grep -o '"foreground_seconds":{"type":"u","data":[0-9]*' | sed 's/.*://'; }
reason_of() { grep -o '"exit_reason":{"type":"s","data":"[a-z-]*"' | sed 's/.*:"//;s/"$//'; }
ids() { busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"'; }
launch() { as_shell busctl --system call "$svc" "$path" "$ifc" Launch ss "$sleeper" "$1" | sed -n 's/^ss "ok" "\(.*\)"$/\1/p'; }

build_repo() {
    rm -rf "$work"; mkdir -p "$work/rt/usr/bin" "$work/rt/usr/lib64" "$work/rt/files" "$work/rt/var"
    for b in bash sleep; do cp "/usr/bin/$b" "$work/rt/usr/bin/$b" || return 1; done
    cp "/usr/bin/bash" "$work/rt/usr/bin/sh"
    for lib in $(ldd /usr/bin/bash /usr/bin/sleep | awk '/=> \//{print $3} /ld-linux/{print $1}' | sort -u); do
        cp "$lib" "$work/rt/usr/lib64/" || return 1
    done
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    flatpak build-export --runtime "$work/repo" "$work/rt" stable >/dev/null 2>&1 || return 1
    mkdir -p "$work/$sleeper/files/bin" "$work/$sleeper/var"
    printf '#!/bin/sh\nexec sleep 3000\n' > "$work/$sleeper/files/bin/run"; chmod 755 "$work/$sleeper/files/bin/run"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=run\n' "$sleeper" "$rt" "$rt" > "$work/$sleeper/metadata"
    flatpak build-finish --command=run "$work/$sleeper" >/dev/null 2>&1 || return 1
    flatpak build-export "$work/repo" "$work/$sleeper" stable >/dev/null 2>&1 || return 1
}

# Says "the sleeper is in front and the person is there" every 5 s, as the shell does (20 s in the
# real shell; the service accepts reports up to 75 s old).
present_loop() {
    while :; do
        as_shell busctl --system call "$svc" "$path" "$ifc" ReportPresence sss "$1" "$2" active >/dev/null 2>&1
        sleep 5
    done
}

case "${1:-check}" in
security)
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
    ;;
clean)
    flatpak uninstall --system -y "$sleeper" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    ;;
check)
    echo "--- unit, state directory, bus policy"
    systemctl is-active ruya-session && ok "ruya-session is active" || bad "ruya-session not active"
    [ "$(stat -c '%a %U' "$store" 2>/dev/null || stat -c '%a %U' /var/lib/ruya-session)" = "700 root" ] \
        && ok "the state directory is root-only (0700)" || bad "state directory mode: $(stat -c '%a %U' /var/lib/ruya-session)"
    if runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListSessions sxu p1 0 5 >/dev/null 2>&1; then
        bad "nobody can call ListSessions"
    else
        ok "a caller other than ruya-shell is refused by the bus policy"
    fi

    echo "--- profiles"
    before="$(ids)"
    if [ -z "$before" ]; then
        prof CreateProfile sssss "" "" "Check Admin" admin 1234 >/dev/null
        admin="$(ids | head -1)"
    else
        echo "FAIL: this check needs an empty profile store (it creates and deletes its own profiles)"; exit 1
    fi
    prof CreateProfile sssss "$admin" 1234 "Check Kid" standard "" >/dev/null
    prof CreateProfile sssss "$admin" 1234 "Check Other" standard "" >/dev/null
    kid="$(ids | sed -n 2p)"; other="$(ids | sed -n 3p)"
    [ -n "$kid" ] && [ -n "$other" ] && ok "profiles $admin (admin), $kid, $other" || { bad "profiles not created"; exit 1; }
    user="ruya-$kid"

    echo "--- the test app"
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" || { bad "remote-add"; exit 1; }
    flatpak install --system -y --noninteractive "$remote" "$rt" "$sleeper" >/dev/null 2>&1 \
        && ok "test app installed" || { bad "flatpak install failed"; exit 1; }
    systemctl --user -M "$user@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null

    echo "--- a session is counted while the app is in front and the profile active"
    prof SwitchTo ss "$kid" "" >/dev/null
    inst="$(launch "$kid")"
    [ -n "$inst" ] && ok "Launch: $inst" || { bad "Launch failed"; exit 1; }
    sleep 3
    present_loop "$kid" "$inst" & loop=$!
    sleep 36
    f="$(ls "$store/$kid/open/"*.rec 2>/dev/null | head -1)"
    [ -n "$f" ] && ok "a heartbeat file exists after 36 s ($(basename "$f"))" || bad "no heartbeat file under $store/$kid/open"
    [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ] && ok "heartbeat file mode 0600" || bad "heartbeat file mode $(stat -c %a "$f" 2>/dev/null)"
    [ "$(stat -c %a "$store/$kid" 2>/dev/null)" = 700 ] && ok "the profile's directory is 0700" || bad "profile directory mode"
    out="$(sess ListSessions sxu "$kid" 0 10)"; echo "$out" | cut -c1-300
    echo "$out" | grep -q '"open":{"type":"b","data":true}' && ok "the running session is listed with open=true" || bad "no open session in ListSessions"
    sleep 6
    as_shell busctl --system call "$svc" "$path" "$ifc" Stop s "$inst" >/dev/null
    sleep 8
    kill "$loop" 2>/dev/null
    out="$(sess ListSessions sxu "$kid" 0 10)"; echo "$out" | cut -c1-400
    n="$(echo "$out" | fg_of | head -1)"
    r="$(echo "$out" | reason_of | head -1)"
    [ -n "$n" ] && [ "$n" -ge 36 ] && [ "$n" -le 52 ] && ok "foreground seconds $n (about 36-50 played with a report every 5 s)" || bad "foreground seconds: '$n'"
    [ "$r" = quit ] && ok "exit reason quit" || bad "exit reason: '$r'"
    echo "$out" | grep -q "\"app_id\":{\"type\":\"s\",\"data\":\"$sleeper\"" && ok "the session names the app" || bad "app id missing"
    [ -s "$store/$kid/ledger.tsv" ] && ok "the ledger file holds the session" || bad "no ledger.tsv"
    [ "$(stat -c %a "$store/$kid/ledger.tsv")" = 600 ] && ok "ledger.tsv mode 0600" || bad "ledger mode"
    [ -z "$(ls "$store/$kid/open/" 2>/dev/null)" ] && ok "the heartbeat file is gone after the end" || bad "heartbeat file left behind"
    tot="$(sess GetTotals sss "$kid" "" "")"; echo "$tot" | cut -c1-300
    today="$(date +%F)"
    echo "$tot" | grep -q "\"$today\"" && ok "GetTotals: today is $today and a row has that day" || bad "GetTotals today: $tot"

    echo "--- the day follows the device time zone (T-213)"
    orig="$(timedatectl show -p Timezone --value)"
    timedatectl set-timezone Pacific/Kiritimati
    want="$(TZ=Pacific/Kiritimati date +%F)"
    got="$(sess GetTotals sss "$kid" "" "" | grep -o '"data":\["[a-z]*","[0-9-]*"' | sed 's/.*,"//;s/"$//')"
    [ "$got" = "$want" ] && ok "GetTotals today = $got in Pacific/Kiritimati (UTC+14)" || bad "today in Kiritimati: got '$got', want '$want'"
    timedatectl set-timezone "$orig"

    echo "--- a power cut: the session ends at the last heartbeat"
    inst="$(launch "$kid")"
    [ -n "$inst" ] && ok "Launch: $inst" || bad "Launch 2 failed"
    sleep 3
    present_loop "$kid" "$inst" & loop=$!
    sleep 40
    kill "$loop" 2>/dev/null
    # A power cut takes the app down with the service. Since T-290 the service adopts a running app after a
    # restart, so killing only the service would (rightly) leave the session open.
    pkill -9 -f '/usr/bin/ruya-session' ; systemctl --user -M "$user@.host" kill --signal=SIGKILL 'ruya-app-*.service' </dev/null >/dev/null 2>&1
    echo "(service and app killed with SIGKILL)"
    n=0; until systemctl is-active ruya-session >/dev/null 2>&1 || [ "$n" -ge 20 ]; do sleep 1; n=$((n + 1)); done
    sleep 3
    prof SwitchTo ss "$kid" "" >/dev/null
    out="$(sess ListSessions sxu "$kid" 0 10)"; echo "$out" | cut -c1-500
    fgs="$(echo "$out" | fg_of | tr '\n' ' ')"; rs="$(echo "$out" | reason_of | tr '\n' ' ')"
    echo "$rs" | grep -q crashed && ok "the interrupted session came back with reason crashed" || bad "reasons: $rs"
    echo "$fgs" | tr ' ' '\n' | awk '$1 >= 20 && $1 <= 40 {f=1} END {exit !f}' && ok "its time is that of the last heartbeat (20-40 s of 40, the heartbeat is every 30 s: $fgs)" || bad "foreground seconds: $fgs"
    systemctl --user -M "$user@.host" stop 'ruya-app-*.service' </dev/null 2>&1 | cat >/dev/null

    echo "--- ClearHistory"
    prof SwitchTo ss "$other" "" >/dev/null
    out="$(sess ClearHistory sss "$kid" "" "")"
    echo "$out" | grep -q '"not-allowed"' && ok "clearing another profile's history without an admin: not-allowed" || bad "clear as other: $out"
    out="$(sess ClearHistory sss "$kid" "$admin" 0000)"
    echo "$out" | grep -q '"wrong-pin"' && ok "a wrong admin PIN: wrong-pin" || bad "clear with a wrong PIN: $out"
    out="$(sess ListSessions sxu "$kid" 0 10)"
    echo "$out" | grep -q '"not-allowed"' && ok "another profile's history cannot be read (not-allowed), admin or not" || bad "read of the kid's history as $other: $out"
    out="$(sess GetTotals sss "$kid" "" "")"
    echo "$out" | grep -q '"not-allowed"' && ok "nor its totals" || bad "totals as $other: $out"
    out="$(sess ListSessions sxu "$other" 0 10)"
    echo "$out" | grep -q '"ok"' && [ -z "$(echo "$out" | fg_of)" ] && ok "$other sees an empty history of its own" || bad "$other history: $out"
    prof SwitchTo ss "$kid" "" >/dev/null
    out="$(sess ClearHistory sss "$kid" "" "")"
    echo "$out" | grep -q '"ok"' && ok "ClearHistory by the active profile: ok" || bad "own clear: $out"
    out="$(sess ListSessions sxu "$kid" 0 10)"
    [ -z "$(echo "$out" | fg_of)" ] && ok "the history is empty" || bad "history after clear: $out"
    [ ! -e "$store/$kid/ledger.tsv" ] && ok "the ledger file is gone" || bad "ledger.tsv still there"
    out="$(sess ClearHistory sss "$kid" "x;y" 1234)"
    echo "$out" | grep -q '"invalid"\|"not-allowed"' && ok "a bad admin id is refused" || bad "bad admin id: $out"

    echo "--- deleting a profile deletes its usage data"
    prof SwitchTo ss "$other" "" >/dev/null
    out="$(prof DeleteProfile sss "$admin" 1234 "$kid")"
    case "$out" in 'suu "ok"'*) ok "DeleteProfile $kid";; *) bad "DeleteProfile: $out";; esac
    n=0; while [ -e "$store/$kid" ] && [ "$n" -lt 80 ]; do sleep 1; n=$((n + 1)); done
    [ ! -e "$store/$kid" ] && ok "the usage directory of $kid is gone after $n s" || bad "usage data of the deleted profile is still there"

    prof DeleteProfile sss "$admin" 1234 "$other" >/dev/null
    flatpak uninstall --system -y "$sleeper" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    echo "--- journal of the service (warnings)"
    journalctl -u ruya-session -b --no-pager -p warning | tail -5
    echo "--- security exposure"
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
