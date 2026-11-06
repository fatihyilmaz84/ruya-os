#!/usr/bin/env bash
# Checks the sample game (samples/hello-game, T-214) inside a running VM, as root: it follows
# docs/developers/ from the other side. It installs the sample from a local repository, starts it
# for a profile through Session1.Launch, and checks that it saves under the profile's
# ~/.var/app/<id>/data/saves/, that Stop (SIGTERM, grace 5 s) makes it save once more and exit with
# the reason "quit" (not "killed"), that a second launch loads the save, and that uninstalling with
# "keep data" (Store1.Uninstall delete_data=false) keeps the save.
#
# The guest needs the network once, for the runtime (org.freedesktop.Platform//26.08 from Flathub).
# There is no Wayland socket for profile apps yet (T-164) and no controller in the VM, so the game
# is run with SDL's dummy video and audio drivers (a `flatpak override`, which the check removes):
# what is checked is the lifecycle and the saves, not the picture or the input.
#
# Build the repository on a Linux host (see samples/hello-game/README.md) and pack it:
#   tar -C ~/hello-game -czf hello-repo.tgz repo
# Boot with plain smoke-test.ps1 -Keep, then:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 hello-repo.tgz scripts/vm-sample-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-sample-check.sh [check|clean] [/root/hello-repo.tgz]
# On an empty profile store it creates the admin "Check Admin" (PIN 1234) and a standard profile
# "Check Kid" and deletes the kid at the end (as vm-session-check.sh does); profiles that were
# there before are used as they are and not deleted.
set -u
mode="${1:-check}"
tgz="${2:-/root/hello-repo.tgz}"
svc=org.ruyaos.Session1
path=/org/ruyaos/Session1
ifc=org.ruyaos.Session1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
ssvc=org.ruyaos.Store1
spath=/org/ruyaos/Store1
app=org.ruyaos.HelloGame
runtime=org.freedesktop.Platform//26.08
remote=ruyaos-hello-test
work=/var/lib/ruya-sample-test
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

as_shell() { runuser -u ruya-shell -- "$@"; }
launch() { as_shell busctl --system call "$svc" "$path" "$ifc" Launch ss "$1" "$2"; }
stop_app() { as_shell busctl --system call "$svc" "$path" "$ifc" Stop s "$1"; }
unit_of() { sed -n 's/^ss "ok" "\(.*\)"$/\1/p'; }
# Waits for a line of the signal log (an extended-regex pattern), up to $2 seconds.
wait_sig() {
    n=0
    while [ "$n" -lt "$2" ]; do
        grep -E -q "$1" "$work/signals.log" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}
# The value of a key in the save file.
field() { sed -n "s/^$1=//p" "$slot" 2>/dev/null | head -1; }
# Waits until the save file shows `$1` (a key) with a value for which `$2` (a test on "$v") holds.
wait_field() {
    n=0
    while [ "$n" -lt "$3" ]; do
        v="$(field "$1")"
        [ -n "$v" ] && eval "$2" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}
cleanup() {
    flatpak override --system --reset "$app" >/dev/null 2>&1
    flatpak uninstall --system -y --noninteractive "$app" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
}

if [ "$mode" = clean ]; then
    cleanup
    rm -rf "$work"
    exit 0
fi

echo "--- the services"
systemctl is-active ruya-session >/dev/null && ok "ruya-session is active" || { bad "ruya-session is not active"; exit 1; }
flatpak --version

echo "--- a profile to run the game as"
created=0
pid="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
if [ -z "$pid" ]; then
    busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "" "" "Check Admin" admin 1234
    admin="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
    busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$admin" 1234 "Check Kid" standard ""
    pid="$(busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | grep -v "\"$admin\"" | head -1 | tr -d '"')"
    created=1
fi
[ -n "$pid" ] && ok "profile $pid (created by the check: $created)" || { bad "no profile"; exit 1; }
user="ruya-$pid"
data="/var/home/$user/.var/app/$app/data"
slot="$data/saves/slot1.sav"

echo "--- install the sample (runtime from Flathub, the game from the local repository)"
rm -rf "$work"; mkdir -p "$work"
tar -xzf "$tgz" -C "$work" || { bad "cannot unpack $tgz (build it as in samples/hello-game/README.md)"; exit 1; }
cleanup
flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" || { bad "remote-add"; exit 1; }
flatpak install --system -y --noninteractive flathub "$runtime" >"$work/install.log" 2>&1 \
    || { cat "$work/install.log"; bad "cannot install $runtime from flathub (is the guest online?)"; exit 1; }
flatpak install --system -y --noninteractive "$remote" "$app" >>"$work/install.log" 2>&1 \
    && ok "$app installed system-wide" || { cat "$work/install.log"; bad "flatpak install of $app failed"; exit 1; }
# The Store learns apps it did not install itself only on a refresh: restart it so Uninstall knows the game.
systemctl restart ruya-store; sleep 3
flatpak override --system --env=SDL_VIDEODRIVER=dummy --env=SDL_AUDIODRIVER=dummy "$app"
rm -rf "/var/home/$user/.var/app/$app"

: > "$work/signals.log"
busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
mon=$!
sleep 2

echo "--- first launch: a new game"
out="$(launch "$app" "$pid")"; echo "$out"
inst="$(echo "$out" | unit_of)"
[ -n "$inst" ] && ok "Launch answered ok ($inst)" || { bad "Launch: $out"; kill "$mon"; exit 1; }
wait_sig "\"member\":\"AppStarted\".*$app" 60 && ok "AppStarted arrived" || bad "no AppStarted within 60 s"
wait_field plays '[ "$v" = 1 ]' 60 && ok "the save exists: $slot (plays=1)" || bad "no save with plays=1 within 60 s"
[ "$(stat -c %U "$slot" 2>/dev/null)" = "$user" ] && ok "the save belongs to $user" || bad "owner of the save: $(stat -c %U "$slot" 2>&1)"
[ "$(stat -c %a "/var/home/$user" 2>/dev/null)" = 700 ] && ok "the profile's home is 0700" || bad "home mode: $(stat -c %a "/var/home/$user")"
# Let it play for a few seconds, so the save written at the stop differs from the one at the start.
sleep 6

echo "--- Stop: SIGTERM, the game saves and exits within the grace"
t0="$(date +%s)"
case "$(stop_app "$inst")" in 's "ok"') ok "Stop answered ok";; *) bad "Stop";; esac
wait_sig "\"member\":\"AppExited\".*$app" 20 && ok "AppExited arrived after $(( $(date +%s) - t0 )) s" || bad "no AppExited within 20 s"
line="$(grep -E "\"member\":\"AppExited\".*$app" "$work/signals.log" | head -1)"
echo "$line" | grep -q '"quit"' && ok "reason quit (not killed)" || bad "AppExited: $line"
[ $(( $(date +%s) - t0 )) -le 5 ] && ok "it was gone within the 5 s grace" || bad "it needed more than 5 s"
v="$(field played)"
[ -n "$v" ] && [ "$v" -ge 3 ] && ok "the save written at SIGTERM holds the play time (played=$v s)" || bad "played=$v: the stop did not save"
[ -f "$slot.bak" ] && ok "the previous save is kept as slot1.sav.bak" || bad "no .bak"
ls -l "$data/saves"
if journalctl -b --no-pager 2>/dev/null | grep -q "hello-game: saved (sigterm)"; then ok "the journal shows 'saved (sigterm)'"; else echo "(note: no 'saved (sigterm)' line in the journal: the app's output may not reach it)"; fi
pgrep -u "$user" -x hello-game >/dev/null && bad "the game is still running" || ok "no game process of $user remains"
ls "$data/saves" | grep -q 'tmp-' && bad "a temporary file was left behind" || ok "no temporary file left behind"

echo "--- second launch: it loads the save"
out="$(launch "$app" "$pid")"; inst2="$(echo "$out" | unit_of)"
[ -n "$inst2" ] && ok "Launch again ($inst2)" || bad "Launch again: $out"
wait_field plays '[ "$v" = 2 ]' 60 && ok "plays=2: the first save was loaded and counted on" || bad "plays is $(field plays), not 2"
v="$(field played)"
[ -n "$v" ] && [ "$v" -ge 3 ] && ok "the play time survived (played=$v s)" || bad "played=$v after the second start"
case "$(stop_app "$inst2")" in 's "ok"') ok "Stop answered ok";; *) bad "Stop (second)";; esac
n0="$(grep -c "\"member\":\"AppExited\".*$app" "$work/signals.log")"
n=0; while [ "$(grep -c "\"member\":\"AppExited\".*$app" "$work/signals.log")" -le "$n0" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
grep -E "\"member\":\"AppExited\".*$app" "$work/signals.log" | tail -1 | grep -q '"quit"' && ok "second stop: reason quit" || bad "second stop was not quit"

echo "--- a damaged newest save: the game starts from the .bak"
printf 'hello-game 1\nscore=99' > "$slot"
out="$(launch "$app" "$pid")"; inst3="$(echo "$out" | unit_of)"
[ -n "$inst3" ] && ok "Launch with a torn save ($inst3)" || bad "Launch: $out"
wait_field plays '[ "$v" -ge 3 ]' 60 && ok "it came up from the .bak (plays=$(field plays))" || bad "no start from the .bak (plays=$(field plays))"
stop_app "$inst3" >/dev/null
sleep 8

echo "--- uninstall, keeping the data (what the shell's 'Keep saves?' will do)"
case "$(as_shell busctl --system call "$ssvc" "$spath" "$ssvc" Uninstall sb "$app" false)" in
    'ss "ok"'*) ok "Store1.Uninstall(delete_data=false) queued";;
    *) bad "Store1.Uninstall did not answer ok"; flatpak uninstall --system -y --noninteractive "$app" >/dev/null 2>&1;;
esac
n=0; while flatpak list --system --app | grep -q "$app" && [ "$n" -lt 60 ]; do sleep 1; n=$((n + 1)); done
flatpak list --system --app | grep -q "$app" && bad "the game is still installed" || ok "the game is uninstalled"
[ -f "$slot" ] && ok "the save is still there: $slot" || bad "the save was deleted"

kill "$mon" 2>/dev/null
if [ "$created" = 1 ]; then
    busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$admin" 1234 "$pid" >/dev/null
fi
cleanup
rm -rf "$work"
echo "--- journal of the service (warnings)"
journalctl -u ruya-session -b --no-pager -p warning | tail -5
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
