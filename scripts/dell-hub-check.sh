#!/usr/bin/env bash
# The Ruya Hub's budgets over a game on the Dell (T-455, 02 section 1.6, ADR-033). Run from Git Bash
# or WSL on the host:
#   [RUYA_PIN=<digits>] scripts/dell-hub-check.sh [host]
# Needs the key ~/.ssh/ruyaos_dev and a shell image with the "page-open hub" journal line (T-455) and,
# for steps 1 and 4, RUYA_PERF_LOG (T-455) and the "hub-resume" and "perf-own" lines (RUY-405). The Dell is a test machine (CLAUDE.md): the script signs in
# a profile if none is (a profile with no PIN, or RUYA_PIN for the first one), stops every running app,
# starts SuperTuxKart as the active profile and leaves it running. Keys are typed through a throw-away
# uinput keyboard (as dell-glass-check.sh). "Render" is the shell's drm fdinfo over 10 s (1000 ms in
# 10 s is 10 % of the GPU); CPU is the shell's utime+stime over 10 s (100 ticks is one core).
#   1. Hidden: SuperTuxKart in front, the Hub closed, 10 s. The shell draws the game's frames and
#      nothing of its own, so this is the cost of showing a game at 60 FPS. PASS: GPU under 20 % and
#      CPU under 20 % of a core (a guard rail set from the first measurement, 11 % and 11 %). Also the
#      shell's own frames (RUY-405): with RUYA_PERF_LOG the shell logs "perf-own frames=<n> window=1s"
#      once a second, the presented frames that follow no commit of the game's surface (a frame that
#      only presents the game's buffer follows a commit and is not counted). PASS: 0 in the 10 s, a
#      hidden Hub over a game draws nothing by itself. The script restarts the shell once at the start
#      for the RUYA_PERF_LOG drop-in (below), so every step runs with the log on.
#   2. Open time: Guide, 2 s, Back, 2 s, ten times. The shell writes "page-open hub create= firstSwap=
#      afterAnim=" (ms from the Guide key reaching the shell: firstSwap is the first frame presented
#      after it, afterAnim the end of the slide). PASS: median firstSwap under 100 ms (budget).
#   2b. Resume: Guide, 2 s, Accept on the game card (Resume has the focus), 2 s, ten times. The shell
#      writes "hub-resume thawReply=<ms> firstFrame=<ms> status=<s>" (ms from the Hub's close: the
#      Thaw's answer, and the game's next presented frame). Reports the median and the worst firstFrame
#      and thawReply with no PASS line: no budget is written in ADR-033 or 02 section 1.6 yet. FAIL only
#      when fewer than 5 lines come, or a line has a status other than ok (a firstFrame=timeout is noted).
#   3. Open and still: Guide, 6 s, then 10 s, with the game frozen (the default, T-457). PASS: under
#      300 ms render in 10 s (3 %): an open Hub over a frozen game draws nothing once its slide ended.
#   4. FPS (skipped with RUYA_HUB_NOFPS=1): the shell is restarted with the setting hub/pauseGames=false
#      (shell.conf is backed up and put back; RUYA_PERF_LOG=1 is on since the start, a volatile systemd
#      drop-in in /run), SuperTuxKart is started again, the compositor's frame meter (T-451) logs "perf-frames"
#      four times a second. The game's FPS with the Hub closed (10 s) against with it open (10 s, the
#      game is not frozen). PASS: the drop is under 10 % (budget). The shell is restarted again at the
#      end to take the drop-in and the setting back, and the profile is signed in again. It also prints
#      the closed-Hub frame-time p99 and the package temperature (RUYA_HUB_FPS_SECS sets the closed
#      window, default 10 s). RUYA_HUB_ONLY_FPS=1 skips steps 1 to 3 (dell-epp-bench.sh uses it).
# The shell restarts once more at the end (restore): it copies the shell.conf backup back and removes the
# drop-in whether or not step 4 ran (RUYA_HUB_NOFPS=1 too), and the profile is signed in again.
# Exit 0 PASS, 1 a FAIL, 2 NOT RUN.
set -u
HOST="${1:-192.168.178.109}"
. "$(dirname "$0")/lib/dell-common.sh"   # SSHO, r, BUS, now, active, signin, stop_apps, shell_cost
APP=net.supertuxkart.SuperTuxKart
fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

BUDGET_HIDDEN_PCT=20      # shell GPU %, and CPU % of a core, with a game in front and the Hub closed
BUDGET_OPEN_MS=100        # median first frame after Guide
BUDGET_STILL_MS=300       # render ms in 10 s of an open Hub over a frozen game
BUDGET_FPS_DROP=10        # percent

# Root vouches for its keyboard (vm_uinput_trust.py, RUY-1063): an unvouched uinput device is foreign
# and the shell never reads it.
r 'mkdir -p /var/tmp/dell-hub && cat > /var/tmp/dell-hub/vm_uinput_trust.py' < "$(dirname "$0")/vm_uinput_trust.py"
r 'cat > /var/tmp/dell-hub/keys.py' <<'EOF'
import fcntl, os, struct, sys, time
import vm_uinput_trust
KEYS = {"esc": 1, "guide": 172, "ret": 28}
def emit(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)
for code in KEYS.values():
    fcntl.ioctl(fd, 0x40045565, code)
fcntl.ioctl(fd, 0x405C5503, struct.pack("HHHH80sI", 3, 0x1209, 1, 1, b"dell-hub-keys".ljust(80, b"\0"), 0))
fcntl.ioctl(fd, 0x5501)
trusted = vm_uinput_trust.trust(fd)
try:
    time.sleep(1.5)
    for k in sys.argv[1:]:
        if k.startswith("w"):           # w<seconds>: wait
            time.sleep(float(k[1:]))
            continue
        for v in (1, 0):
            emit(fd, 1, KEYS[k], v)
            emit(fd, 0, 0, 0)
            time.sleep(0.1)
finally:
    vm_uinput_trust.untrust(trusted)
    fcntl.ioctl(fd, 0x5502)
    os.close(fd)
EOF
keys() { r "python3 /var/tmp/dell-hub/keys.py $*"; }
cost() { shell_cost 10; }

r 'pgrep -x ruya-shell >/dev/null' || { echo "DELL HUB CHECK NOT RUN: ruya-shell is not running"; exit 2; }

# The shell must be signed in; with nobody signed in a profile without a PIN (or RUYA_PIN for the
# first one) is signed in over D-Bus (signin).
profile="$(active)"
if [ -z "$profile" ]; then
    signin || { echo "DELL HUB CHECK NOT RUN: nobody is signed in and no profile can be signed in (a PIN: set RUYA_PIN)"; exit 2; }
    profile="$(active)"
fi
echo "profile: $profile; image: $(image_version)"

stk() {   # stop every app, start SuperTuxKart as the profile, let it reach its menu
    stop_apps
    sleep 4
    r "$BUS call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss $APP $profile" | grep -q '"ok"' || { echo "DELL HUB CHECK NOT RUN: SuperTuxKart did not start"; exit 2; }
    sleep 30
}
frozen() { r "$BUS --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning" | grep -o '"frozen":{"type":"b","data":true}' | wc -l; }

conf=/var/lib/ruya-shell/.config/ruyaos/shell.conf
# Put shell.conf and the drop-in back however the script ends (exit 2 in stk(), a lost ssh, Ctrl-C).
restore() {
    trap - EXIT INT TERM
    perflog_dropin_rm hub-check.conf
    r "systemctl stop ruya-compositor@tty1; [ -f /var/tmp/dell-hub/shell.conf.bak ] && cp -p /var/tmp/dell-hub/shell.conf.bak $conf; systemctl start ruya-compositor@tty1; rm -rf /var/tmp/dell-hub"
}
trap restore EXIT
trap 'exit 130' INT TERM
# RUYA_PERF_LOG=1 from the start (a volatile drop-in): the shell-own frame count of step 1 needs it, and
# step 4's frame meter too.
r "cp -p $conf /var/tmp/dell-hub/shell.conf.bak"
perflog_dropin_add hub-check.conf
r "systemctl restart ruya-compositor@tty1"
sleep 12
[ -n "$(active)" ] || signin || { echo "DELL HUB CHECK NOT RUN: could not sign in after the restart"; exit 2; }
profile="$(active)"

if [ -z "${RUYA_HUB_ONLY_FPS:-}" ]; then
echo "== 1. Hidden, SuperTuxKart in front"
stk
ta=$(now)
set -- $(cost)
tb=$(now)
own=$(r "journalctl -b -o cat --since @$ta --until @$tb --no-pager | grep -a 'perf-own' | sed -n 's/.*frames=\([0-9]*\).*/\1/p' | awk '{s+=\$1; n++} END{print s+0, n+0}'")
set -- $own $@
ownframes=$1; ownn=$2; shift 2
echo "Hub hidden: the shell drew $ownframes frames of its own in 10 s ($ownn perf-own lines)"
if [ "$ownn" -lt 5 ]; then
    bad "too few perf-own lines ($ownn) to count the shell's own frames (an image without RUY-405, or no game in front)"
elif [ "$ownframes" -eq 0 ]; then
    ok "a hidden Hub draws no frame of its own (0 shell-own frames in 10 s)"
else
    bad "the shell drew $ownframes frames of its own in 10 s with the Hub hidden"
fi
echo "Hub hidden: render $1 ms in 10 s ($(( $1 / 100 )) % of the GPU), shell CPU $2 ticks in 10 s ($(( $2 / 10 )) % of a core)"
if [ "$(( $1 / 100 ))" -lt "$BUDGET_HIDDEN_PCT" ] && [ "$(( $2 / 10 ))" -lt "$BUDGET_HIDDEN_PCT" ]; then
    ok "showing a game costs the shell $(( $1 / 100 )) % GPU and $(( $2 / 10 )) % of a core (budget $BUDGET_HIDDEN_PCT %)"
else
    bad "showing a game costs the shell $(( $1 / 100 )) % GPU and $(( $2 / 10 )) % of a core (budget $BUDGET_HIDDEN_PCT %)"
fi

echo "== 2. Open time (ten Guide presses)"
t0=$(now)
keys guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2 guide w2 esc w2
lines=$(r "journalctl -b -o cat --since @$t0 --no-pager | grep -a 'page-open hub '")
n=$(echo "$lines" | grep -c 'page-open hub')
echo "$lines" | sed 's/^ruya-shell: /  /' | head -12
if [ "$n" -lt 5 ]; then
    bad "the shell wrote $n open-time lines for 10 presses (an image without T-455, or the Hub did not open)"
else
    med=$(echo "$lines" | sed -n 's/.*firstSwap=\([0-9]*\).*/\1/p' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    worst=$(echo "$lines" | sed -n 's/.*firstSwap=\([0-9]*\).*/\1/p' | sort -n | tail -1)
    anim=$(echo "$lines" | sed -n 's/.*afterAnim=\([0-9]*\).*/\1/p' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    echo "Hub open ($n of 10): first frame median $med ms, worst $worst ms; slide ended at median $anim ms"
    [ "$med" -lt "$BUDGET_OPEN_MS" ] && ok "the Hub's first frame comes in $med ms (median; budget $BUDGET_OPEN_MS)" || bad "the Hub's first frame takes $med ms (median; budget $BUDGET_OPEN_MS)"
fi

echo "== 2b. Resume (ten times: Guide, Accept on Resume)"
t0=$(now)
keys guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2 guide w2 ret w2
lines=$(r "journalctl -b -o cat --since @$t0 --no-pager | grep -a 'hub-resume '")
n=$(echo "$lines" | grep -c 'hub-resume ')
echo "$lines" | sed 's/^ruya-shell: /  /' | head -12
if [ "$n" -lt 5 ]; then
    bad "the shell wrote $n Resume lines for 10 Resumes (an image without RUY-405, or the Hub did not open or Resume was not focused)"
elif echo "$lines" | grep -qv 'status=ok'; then
    bad "a Resume had a Thaw status other than ok"
else
    resume_stat() {   # median and worst of a field over the lines that carry a number
        echo "$lines" | sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" | sort -n | awk '{a[NR]=$1} END{if (NR) print a[int((NR+1)/2)], a[NR], NR; else print "- - 0"}'
    }
    set -- $(resume_stat firstFrame); fmed=$1; fworst=$2; fn=$3
    set -- $(resume_stat thawReply); rmed=$1; rworst=$2
    echo "Resume ($n of 10): game's next frame median $fmed ms, worst $fworst ms ($fn with a frame); Thaw answered median $rmed ms, worst $rworst ms"
    echo "$lines" | grep -q 'firstFrame=timeout' && echo "note: $(echo "$lines" | grep -c 'firstFrame=timeout') Resumes saw no frame within 2 s"
    echo "Resume time: no budget is set (ADR-033, 02 1.6), reported without a PASS"
fi

echo "== 3. Open and still, the game frozen"
keys guide w8
echo "frozen games while open: $(frozen)"
set -- $(cost)
echo "Hub open, still: render $1 ms in 10 s ($(( $1 / 100 )) % of the GPU), shell CPU $2 ticks in 10 s"
[ "$1" -lt "$BUDGET_STILL_MS" ] && ok "an open Hub over a frozen game draws (almost) nothing ($1 ms in 10 s)" || bad "an open Hub keeps the GPU busy: $1 ms in 10 s (budget $BUDGET_STILL_MS)"
keys esc w2
fi   # RUYA_HUB_ONLY_FPS

if [ -z "${RUYA_HUB_NOFPS:-}" ]; then
    echo "== 4. The game's FPS with the Hub closed and open"
    # pauseGames=false while the shell is stopped (a running shell would not read it, and a settings write would undo it)
    r "systemctl stop ruya-compositor@tty1; grep -q '^\[hub\]' $conf && sed -i 's/^pauseGames=.*/pauseGames=false/' $conf || printf '\n[hub]\npauseGames=false\n' >> $conf; grep -q '^pauseGames=false' $conf || sed -i '/^\[hub\]/a pauseGames=false' $conf; systemctl start ruya-compositor@tty1"
    sleep 12
    [ -n "$(active)" ] || signin || echo "note: could not sign in"
    profile="$(active)"
    stk
    t1=$(now)
    sleep "${RUYA_HUB_FPS_SECS:-10}"
    t2=$(now)
    pkgtemp=$(r 'for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type)" = x86_pkg_temp ] && echo $(( $(cat $z/temp) / 1000 )); done | head -1')
    keys guide w4
    t3=$(now)
    sleep 10
    t4=$(now)
    keys esc
    fps() {   # mean fps of the "full" perf-frames lines between two epochs
        r "journalctl -b -o cat --since @$1 --until @$2 --no-pager | grep -a 'perf-frames' | grep -a 'full=1' | sed -n 's/.*fps=\([0-9]*\).*/\1/p' | awk '{s+=\$1; n++} END{if (n) printf \"%.1f %d\", s/n, n; else print \"0 0\"}'"
    }
    set -- $(fps "$t1" "$t2"); before=$1; nb=$2
    # frame-time p99 of the closed-Hub window (the perf-frames p99Ms of each second): mean and worst
    p99=$(r "journalctl -b -o cat --since @$t1 --until @$t2 --no-pager | grep -a 'perf-frames' | grep -a 'full=1' | sed -n 's/.*p99Ms=\([0-9.]*\).*/\1/p' | awk '{s+=\$1; n++; if (\$1>m) m=\$1} END{if (n) printf \"%.1f %.1f\", s/n, m; else print \"0 0\"}'")
    echo "Game frame time p99 (Hub closed): mean $(echo $p99 | cut -d' ' -f1) ms, worst $(echo $p99 | cut -d' ' -f2) ms; package temperature at the end of the window: ${pkgtemp:-?} C"
    set -- $(fps "$t3" "$t4"); during=$1; nd=$2
    echo "Game FPS: Hub closed $before ($nb samples), Hub open $during ($nd samples)"
    if [ "$nb" -lt 10 ] || [ "$nd" -lt 10 ]; then
        bad "the frame meter gave too few samples (an image without RUYA_PERF_LOG, or no app in front)"
    else
        drop=$(awk -v b="$before" -v d="$during" 'BEGIN{ if (b <= 0) print 100; else printf "%d", (b - d) * 100 / b }')
        [ "$drop" -lt "$BUDGET_FPS_DROP" ] && ok "the game's FPS drops $drop % with the Hub open (budget $BUDGET_FPS_DROP %)" || bad "the game's FPS drops $drop % with the Hub open (budget $BUDGET_FPS_DROP %)"
    fi
fi
# The shell is restarted once more to take the drop-in (and the setting) back.
restore
sleep 12
[ -n "$(active)" ] || signin || echo "note: could not sign in again"
echo "note: SuperTuxKart is still running as $profile"
[ "$fails" -eq 0 ] && echo "DELL HUB CHECK PASS" || { echo "DELL HUB CHECK FAIL ($fails)"; exit 1; }
