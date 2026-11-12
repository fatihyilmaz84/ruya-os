#!/usr/bin/env bash
# The Ruya Hub's budgets over a game on the Dell (T-455, 02 section 1.6, ADR-033). Run from Git Bash
# or WSL on the host:
#   [RUYA_PIN=<digits>] scripts/dell-hub-check.sh [host]
# Needs the key ~/.ssh/ruyaos_dev and a shell image with the "page-open hub" journal line (T-455) and,
# for step 4, RUYA_PERF_LOG (also T-455). The Dell is a test machine (CLAUDE.md): the script signs in
# a profile if none is (a profile with no PIN, or RUYA_PIN for the first one), stops every running app,
# starts SuperTuxKart as the active profile and leaves it running. Keys are typed through a throw-away
# uinput keyboard (as dell-glass-check.sh). "Render" is the shell's drm fdinfo over 10 s (1000 ms in
# 10 s is 10 % of the GPU); CPU is the shell's utime+stime over 10 s (100 ticks is one core).
#   1. Hidden: SuperTuxKart in front, the Hub closed, 10 s. The shell draws the game's frames and
#      nothing of its own, so this is the cost of showing a game at 60 FPS. PASS: GPU under 20 % and
#      CPU under 20 % of a core (a guard rail set from the first measurement, 11 % and 11 %; the Hub
#      adds no frames of its own while hidden, which no number here can show on its own).
#   2. Open time: Guide, 2 s, Back, 2 s, ten times. The shell writes "page-open hub create= firstSwap=
#      afterAnim=" (ms from the Guide key reaching the shell: firstSwap is the first frame presented
#      after it, afterAnim the end of the slide). PASS: median firstSwap under 100 ms (budget).
#   3. Open and still: Guide, 6 s, then 10 s, with the game frozen (the default, T-457). PASS: under
#      300 ms render in 10 s (3 %): an open Hub over a frozen game draws nothing once its slide ended.
#   4. FPS (skipped with RUYA_HUB_NOFPS=1): the shell is restarted with RUYA_PERF_LOG=1 (a volatile
#      systemd drop-in in /run) and the setting hub/pauseGames=false (shell.conf is backed up and put
#      back), SuperTuxKart is started again, the compositor's frame meter (T-451) logs "perf-frames"
#      four times a second. The game's FPS with the Hub closed (10 s) against with it open (10 s, the
#      game is not frozen). PASS: the drop is under 10 % (budget). The shell is restarted again at the
#      end to take the drop-in and the setting back, and the profile is signed in again.
# Exit 0 PASS, 1 a FAIL, 2 NOT RUN.
set -u
HOST="${1:-192.168.178.109}"
SSHO="-i $HOME/.ssh/ruyaos_dev -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
r() { ssh $SSHO "root@$HOST" "$@"; }
BUS='runuser -u ruya-shell -- busctl --system'
APP=net.supertuxkart.SuperTuxKart
fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

BUDGET_HIDDEN_PCT=20      # shell GPU %, and CPU % of a core, with a game in front and the Hub closed
BUDGET_OPEN_MS=100        # median first frame after Guide
BUDGET_STILL_MS=300       # render ms in 10 s of an open Hub over a frozen game
BUDGET_FPS_DROP=10        # percent

r 'mkdir -p /var/tmp/dell-hub && cat > /var/tmp/dell-hub/keys.py' <<'EOF'
import fcntl, os, struct, sys, time
KEYS = {"esc": 1, "guide": 172}
def emit(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)
for code in KEYS.values():
    fcntl.ioctl(fd, 0x40045565, code)
fcntl.ioctl(fd, 0x405C5503, struct.pack("HHHH80sI", 3, 0x1209, 1, 1, b"dell-hub-keys".ljust(80, b"\0"), 0))
fcntl.ioctl(fd, 0x5501)
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
    fcntl.ioctl(fd, 0x5502)
    os.close(fd)
EOF
r 'cat > /var/tmp/dell-hub/cost.sh' <<'EOF'
# cost.sh: the shell's render ms (drm fdinfo, once per client id) and CPU ticks over 10 s
sp=$(pgrep -x ruya-shell | head -1); declare -A f a
for d in /proc/$sp/fdinfo/*; do id=$(awk '/drm-client-id/{print $2}' $d 2>/dev/null); [ -n "$id" ] && [ -z "${f[$id]:-}" ] && f[$id]=$d && a[$id]=$(awk '/drm-engine-render/{print $2}' $d); done
c0=$(awk '{print $14+$15}' /proc/$sp/stat)
sleep 10; t=0
for id in "${!f[@]}"; do b=$(awk '/drm-engine-render/{print $2}' ${f[$id]}); t=$((t + (b - a[$id]) / 1000000)); done
c1=$(awk '{print $14+$15}' /proc/$sp/stat)
echo "$t $((c1 - c0))"
EOF
keys() { r "python3 /var/tmp/dell-hub/keys.py $*"; }
cost() { r 'bash /var/tmp/dell-hub/cost.sh'; }
now() { r 'date +%s'; }

r 'pgrep -x ruya-shell >/dev/null' || { echo "DELL HUB CHECK NOT RUN: ruya-shell is not running"; exit 2; }

# The shell must be signed in; with nobody signed in a profile without a PIN (or RUYA_PIN for the
# first one) is signed in over D-Bus.
active() { r "$BUS get-property org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ActiveProfile" | sed -n 's/^s "\(.*\)"/\1/p'; }
signin() {
    local id pin
    if [ -n "${RUYA_PIN:-}" ]; then
        id=$(r "$BUS --json=short call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles" | grep -o '\["[^"]*"' | head -1 | tr -d '[""')
        pin="$RUYA_PIN"
    else
        id=$(r "$BUS --json=short call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles" | grep -o '\["[^"]*","[^"]*","[^"]*","[^"]*",false' | head -1 | cut -d'"' -f2)
        pin=""
    fi
    [ -n "$id" ] || return 1
    r "$BUS call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 SwitchTo ss $id '$pin'" | grep -q '"ok"' || return 1
    sleep 3
}
profile="$(active)"
if [ -z "$profile" ]; then
    signin || { echo "DELL HUB CHECK NOT RUN: nobody is signed in and no profile can be signed in (a PIN: set RUYA_PIN)"; exit 2; }
    profile="$(active)"
fi
echo "profile: $profile; image: $(r "bootc status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"status\"][\"booted\"][\"image\"][\"version\"])'" 2>/dev/null)"

stk() {   # stop every app, start SuperTuxKart as the profile, let it reach its menu
    for i in $(r "$BUS --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning" | grep -o 'ruya-app-[^"]*service'); do
        r "$BUS call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Stop s $i" >/dev/null
    done
    sleep 4
    r "$BUS call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss $APP $profile" | grep -q '"ok"' || { echo "DELL HUB CHECK NOT RUN: SuperTuxKart did not start"; exit 2; }
    sleep 30
}
frozen() { r "$BUS --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning" | grep -o '"frozen":{"type":"b","data":true}' | wc -l; }

echo "== 1. Hidden, SuperTuxKart in front"
stk
set -- $(cost)
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

echo "== 3. Open and still, the game frozen"
keys guide w8
echo "frozen games while open: $(frozen)"
set -- $(cost)
echo "Hub open, still: render $1 ms in 10 s ($(( $1 / 100 )) % of the GPU), shell CPU $2 ticks in 10 s"
[ "$1" -lt "$BUDGET_STILL_MS" ] && ok "an open Hub over a frozen game draws (almost) nothing ($1 ms in 10 s)" || bad "an open Hub keeps the GPU busy: $1 ms in 10 s (budget $BUDGET_STILL_MS)"
keys esc w2

if [ -z "${RUYA_HUB_NOFPS:-}" ]; then
    echo "== 4. The game's FPS with the Hub closed and open"
    conf=/var/lib/ruya-shell/.config/ruyaos/shell.conf
    D=/run/systemd/system/ruya-compositor@tty1.service.d
    # Put shell.conf and the drop-in back however the script ends (exit 2 in stk(), a lost ssh, Ctrl-C).
    restore() {
        trap - EXIT INT TERM
        r "systemctl stop ruya-compositor@tty1; [ -f /var/tmp/dell-hub/shell.conf.bak ] && cp -p /var/tmp/dell-hub/shell.conf.bak $conf; rm -f $D/hub-check.conf; rmdir $D 2>/dev/null; systemctl daemon-reload; systemctl start ruya-compositor@tty1; rm -rf /var/tmp/dell-hub"
    }
    trap restore EXIT
    trap 'exit 130' INT TERM
    r "cp -p $conf /var/tmp/dell-hub/shell.conf.bak; mkdir -p $D; printf '[Service]\nEnvironment=RUYA_PERF_LOG=1\n' > $D/hub-check.conf; systemctl daemon-reload"
    # pauseGames=false while the shell is stopped (a running shell would not read it, and a settings write would undo it)
    r "systemctl stop ruya-compositor@tty1; grep -q '^\[hub\]' $conf && sed -i 's/^pauseGames=.*/pauseGames=false/' $conf || printf '\n[hub]\npauseGames=false\n' >> $conf; grep -q '^pauseGames=false' $conf || sed -i '/^\[hub\]/a pauseGames=false' $conf; systemctl start ruya-compositor@tty1"
    sleep 12
    [ -n "$(active)" ] || signin || echo "note: could not sign in"
    profile="$(active)"
    stk
    t1=$(now)
    sleep 10
    t2=$(now)
    keys guide w4
    t3=$(now)
    sleep 10
    t4=$(now)
    keys esc
    fps() {   # mean fps of the "full" perf-frames lines between two epochs
        r "journalctl -b -o cat --since @$1 --until @$2 --no-pager | grep -a 'perf-frames' | grep -a 'full=1' | sed -n 's/.*fps=\([0-9]*\).*/\1/p' | awk '{s+=\$1; n++} END{if (n) printf \"%.1f %d\", s/n, n; else print \"0 0\"}'"
    }
    set -- $(fps "$t1" "$t2"); before=$1; nb=$2
    set -- $(fps "$t3" "$t4"); during=$1; nd=$2
    echo "Game FPS: Hub closed $before ($nb samples), Hub open $during ($nd samples)"
    if [ "$nb" -lt 10 ] || [ "$nd" -lt 10 ]; then
        bad "the frame meter gave too few samples (an image without RUYA_PERF_LOG, or no app in front)"
    else
        drop=$(awk -v b="$before" -v d="$during" 'BEGIN{ if (b <= 0) print 100; else printf "%d", (b - d) * 100 / b }')
        [ "$drop" -lt "$BUDGET_FPS_DROP" ] && ok "the game's FPS drops $drop % with the Hub open (budget $BUDGET_FPS_DROP %)" || bad "the game's FPS drops $drop % with the Hub open (budget $BUDGET_FPS_DROP %)"
    fi
    restore
    sleep 12
    [ -n "$(active)" ] || signin || echo "note: could not sign in again"
fi

r 'rm -rf /var/tmp/dell-hub'
echo "note: SuperTuxKart is still running as $profile"
[ "$fails" -eq 0 ] && echo "DELL HUB CHECK PASS" || { echo "DELL HUB CHECK FAIL ($fails)"; exit 1; }
