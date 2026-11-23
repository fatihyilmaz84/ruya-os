#!/usr/bin/env bash
# The performance baseline of the Dell (RUY-842, formation RUY-558): every OS-level performance change
# is kept or dropped on these numbers. Run from Git Bash or WSL on the host:
#   scripts/dell-perf-bench.sh [host] [label]          one baseline (label defaults to the image version)
#   scripts/dell-perf-bench.sh --compare a.json b.json the differences of two baselines
# Needs the key ~/.ssh/ruyaos_dev, python3 on the host and a signed-in profile on the Dell (RUYA_PIN as
# for dell-hub-check.sh if the script has to sign one in). The Dell is a test machine (CLAUDE.md).
#
# Items, RUYA_PERF_RUNS (default 3) runs each, interleaved (run 1 of every item, then run 2, ...):
#   supertuxkart  SuperTuxKart's menu scene (the same fixed 3D scene hub-check uses; the game cannot be
#                 driven to a replay without input): frames, cold start, shell cost, power, temperature,
#                 and the relay latency of ruya-inputd.
#   play          one installed .play Windows game (RUYA_PERF_PLAY_APP, default
#                 play.com.example.utgotylocal, UT GOTY): the same numbers but the latency. SKIPPED when
#                 it is not installed; Steam games are never installed or run.
#   home          nothing running: the shell's cost, power and temperature.
# Every game run: stop all apps, start the app as the signed-in profile, wait for its first frame
# (cold start), settle RUYA_PERF_SETTLE s (default 20), then measure RUYA_PERF_WINDOW s (default 30).
#
# Where each number comes from (no change to any game's permissions, no MangoHud):
#   frames        the compositor's frame meter (RUY-347, FrameMeter) through the shell's perf-frames
#                 journal lines (RUYA_PERF_LOG=1, a volatile systemd drop-in this script adds and takes
#                 away). The log has the last second's mean and p99 frame time four times a second, not
#                 every frame: dell-perf-stats.py says what is derived (fps, frame p50, the slowest
#                 frame per second, the worst frame, seconds with a frame over twice the median).
#   cold start    "Starting ruya-app-*.service" (Play pressed: the launch) to the first perf-frames line
#                 with a frame, both journal lines, to about a second.
#   shell cost    the shell's drm fdinfo render time and utime+stime over the window (lib/dell-cost.sh).
#   power, temp   RAPL package-0 energy_uj over the window, the x86_pkg_temp zone at its end.
#   relay latency the Dell has no pad, so a uinput gamepad made by root stands in for the physical one
#                 (an unattended stand-in, not a real controller): dell-perf-latency.py presses a button
#                 100 times and compares the kernel timestamp on that pad's node with the one on the
#                 virtual pad ruya-inputd makes from it. SKIPPED, with the reason, if no virtual pad
#                 appears. The pad is plugged before the game starts and stays until the game is
#                 stopped (a seated player whose pad is gone opens the Hub over the game, which would
#                 pause it); with a pad the Hub is open over a game that starts, so the pad taps Back
#                 once to close it before anything is measured. The play item has no pad.
# Output: output/perf/<label>-<date>.json and a summary of at most 15 lines (median and min-max of the
# runs). --compare shows every number of both files with the noise band, the larger run-to-run spread:
# a change inside it is "within noise".
# Nothing is changed that is not put back: the drop-in, the shell restart, the pad and /var/tmp/dell-perf
# are undone by a trap at exit (also on an error, Ctrl-C or a lost ssh), and every app is stopped. The
# shell restarts at the start and at the end (the signed-in profile stays). The pad leaves player 1's seat
# held for 60 s, as an unplugged pad does. Exit 0 done, 2 NOT RUN.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3 || command -v python)"
if [ "${1:-}" = "--compare" ]; then
    [ $# -eq 3 ] || { echo "usage: $0 --compare a.json b.json"; exit 2; }
    exec "$PY" -I "$HERE/dell-perf-stats.py" compare "$2" "$3"
fi
HOST="${1:-192.168.178.109}"
. "$HERE/lib/dell-common.sh"   # SSHO, r, BUS, SESSION, active, signin, stop_apps, shell_cost, image_version, perflog_*
RUNS="${RUYA_PERF_RUNS:-3}"
WINDOW="${RUYA_PERF_WINDOW:-30}"
SETTLE="${RUYA_PERF_SETTLE:-20}"
PLAY_APP="${RUYA_PERF_PLAY_APP:-play.com.example.utgotylocal}"
STK_APP=net.supertuxkart.SuperTuxKart
PRESSES=100
D=/var/tmp/dell-perf
DROPIN=perf-bench.conf
OUT="$HERE/../output/perf"

r 'pgrep -x ruya-shell >/dev/null' || { echo "DELL PERF BENCH NOT RUN: the Dell is not reachable or ruya-shell is not running"; exit 2; }
[ -n "$PY" ] || { echo "DELL PERF BENCH NOT RUN: no python3 on this host"; exit 2; }
stats() { "$PY" -I "$HERE/dell-perf-stats.py" "$@"; }
image="$(image_version)"
label="${2:-${image:-dell}}"
mkdir -p "$OUT"
work="$(mktemp -d)"
runs="$work/runs.tsv"; : > "$runs"

restore() {
    trap - EXIT INT TERM
    r "[ -f $D/lat.pid ] && kill \$(cat $D/lat.pid) 2>/dev/null; true"
    stop_apps
    perflog_dropin_rm "$DROPIN"
    r "systemctl restart ruya-compositor@tty1; rm -rf $D"
    rm -rf "$work"
}
trap restore EXIT
trap 'exit 130' INT TERM

r "mkdir -p $D"
for f in vm-input-probe.py vm_uinput_trust.py dell-perf-latency.py; do r "cat > $D/$f" < "$HERE/$f"; done
perflog_dropin_add "$DROPIN"
r "systemctl restart ruya-compositor@tty1"
sleep 12
[ -n "$(active)" ] || signin || { echo "DELL PERF BENCH NOT RUN: nobody is signed in and no profile can be signed in (a PIN: set RUYA_PIN)"; exit 2; }
profile="$(active)"
echo "Dell $HOST, image $image, profile $profile, label $label: $RUNS runs of supertuxkart, play ($PLAY_APP), home; window $WINDOW s"

# add <item> <key=value>...: one run's line in runs.tsv (tab separated)
add() { local IFS=$'\t'; echo "$*" >> "$runs"; }

# cost_fields <shell_cost output>: shell_gpu_pct, shell_cpu_pct, power_w, temp_c of a WINDOW-second cost
cost_fields() {
    set -- $1
    awk -v ms="$1" -v ticks="$2" -v w="$3" -v t="$4" -v secs="$WINDOW" 'BEGIN{
        printf "shell_gpu_pct=%.1f\tshell_cpu_pct=%.1f", ms / (secs * 10), ticks / secs
        if (w != "-") printf "\tpower_w=%s", w
        if (t != "-") printf "\ttemp_c=%s", t }'
}

# game_run <item> <app> <presses>: one run of a game; appends its line to runs.tsv, or says why not.
game_run() {
    local item=$1 app=$2 presses=$3 t0 t1 t2 n=0 lat="" frames cost reply front
    stop_apps
    sleep 4
    if [ "$presses" -gt 0 ]; then   # the stand-in pad, plugged in before the game starts
        r "rm -f $D/front $D/go $D/stop $D/lat.out; (nohup python3 $D/dell-perf-latency.py $profile $presses $D > $D/lat.out 2>&1 < /dev/null & echo \$! > $D/lat.pid)"
        until r "grep -q '^ready' $D/lat.out" || [ $((n += 1)) -gt 15 ]; do sleep 1; done
        r "grep -q '^ready' $D/lat.out" || { echo "  $item: the stand-in pad did not come up: $(r "cat $D/lat.out")"; return 1; }
        sleep 3
    fi
    t0=$(r 'date +%s.%N')
    reply=$(r "$SESSION Launch ss $app $profile")
    case "$reply" in *'"ok"'*) ;; *) echo "  $item: $app did not start: $reply"; return 1 ;; esac
    if [ "$presses" -gt 0 ]; then   # with a pad the Hub is open over the game that starts: the pad closes it
        r "touch $D/front"
        n=0
        until r "grep -q '^front' $D/lat.out" || [ $((n += 1)) -gt 20 ]; do sleep 2; done
        front=$(r "grep '^front' $D/lat.out")
        echo "  $item: $front"
        [ "$front" = "front app" ] || { stop_apps; r "touch $D/stop"; return 3; }   # the Hub or a prompt is over the game: the shell's cost would be its own
    fi
    n=0
    until [ "$(r "journalctl -b -o cat --since @${t0%.*} --no-pager | grep -ac 'perf-frames fps=[1-9]'")" -gt 0 ] || [ $((n += 1)) -gt 60 ]; do sleep 3; done
    sleep "$SETTLE"
    t1=$(r 'date +%s.%N')
    cost=$(shell_cost "$WINDOW")
    t2=$(r 'date +%s.%N')
    r "journalctl -b -o short-unix --since @${t0%.*} --no-pager | grep -a 'perf-frames\|Starting ruya-app-'" > "$work/$item.journal"
    frames=$(stats frames "$work/$item.journal" "$t1" "$t2" "$t0" | tr ' ' $'\t')
    if [ "$presses" -gt 0 ]; then
        r "touch $D/go"
        n=0
        until r "grep -q 'relay_\|skipped' $D/lat.out" || [ $((n += 1)) -gt 40 ]; do sleep 2; done
        lat=$(r "grep 'relay_\|skipped' $D/lat.out" | tr ' ' $'\t')
    fi
    stop_apps
    r "touch $D/stop"
    case "$lat" in skipped=*) echo "  $item: relay latency SKIPPED ($lat)"; lat="relay_${lat}" ;; esac
    if [ -z "$frames" ]; then
        echo "  $item: no frame in the window (the app did not draw, or it is not in front)"
        return 1
    fi
    add "$item" $frames "$(cost_fields "$cost")" ${lat:+$lat}
}

home_run() {
    stop_apps
    sleep "$SETTLE"
    add home "$(cost_fields "$(shell_cost "$WINDOW")")"
}

play_ok=1
r "flatpak list --columns=application | grep -qx $PLAY_APP" || play_ok=0
# A run with the Hub or a prompt over the game (game_run returns 3) is made again, up to three times.
retry_run() {
    local try rc
    for try in 1 2 3; do
        game_run "$@"; rc=$?
        [ "$rc" -eq 3 ] || return "$rc"
        echo "  $1: made again"
    done
    return 1
}
failed_stk=0; failed_play=0
for run in $(seq 1 "$RUNS"); do
    echo "== run $run of $RUNS"
    retry_run supertuxkart "$STK_APP" "$PRESSES" || failed_stk=$((failed_stk + 1))
    [ "$play_ok" = 1 ] && { retry_run play "$PLAY_APP" 0 || failed_play=$((failed_play + 1)); }
    home_run
done
[ "$play_ok" = 0 ] && add play "skipped=${PLAY_APP}_is_not_installed"
[ "$failed_stk" -gt 0 ] && echo "supertuxkart: $failed_stk of $RUNS runs gave no frames"
[ "$failed_play" -gt 0 ] && echo "play: $failed_play of $RUNS runs gave no frames"

date_s=$(date +%F)
json="$OUT/$label-$date_s.json"; n=1
while [ -e "$json" ]; do n=$((n + 1)); json="$OUT/$label-$date_s-$n.json"; done
echo
stats build "$runs" "$label" "${image:-?}" "$HOST" "$date_s" "$json"
echo "written: ${json#"$HERE/../"}"
