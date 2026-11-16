#!/usr/bin/env bash
# Does the "performance" energy-performance preference (EPP) pay on the Dell? (RUY-528, audit RUY-522
# finding 4.) Run from Git Bash or WSL on the host:
#   scripts/dell-epp-bench.sh [host]
# Needs the key ~/.ssh/ruyaos_dev and what dell-hub-check.sh needs (a shell image with RUYA_PERF_LOG
# support and a profile that can be signed in; RUYA_PIN as there). The Dell is a test machine
# (CLAUDE.md). For each run the script sets EPP on every cpufreq policy through sysfs, then measures:
#   - idle package power: RAPL intel-rapl:0 (package-0) energy_uj over 60 s on Home (every app stopped,
#     20 s to settle), in watts, and the package temperature at the end;
#   - SuperTuxKart FPS and frame-time p99 with the Hub closed: dell-hub-check.sh with RUYA_HUB_ONLY_FPS=1
#     (its step 4, the compositor's perf-frames lines), over RUYA_BENCH_GAME_SECS (default 30) seconds,
#     and the package temperature at the end of that window.
# Default order balance_performance, performance, performance, balance_performance (ABBA: a warm
# machine does not favour one side); RUYA_BENCH_ORDER="a b ..." overrides it. The original EPP of every
# policy is saved on the Dell and put back at exit, also on an error, Ctrl-C or a lost ssh: a local
# trap does it, and a systemd timer on the Dell (epp-bench-restore, 45 min) does it if this script
# dies without running the trap. Nothing is changed besides EPP (and what dell-hub-check.sh restarts
# and restores). Exit 0 done, 2 NOT RUN.
set -u
HOST="${1:-192.168.178.109}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SSHO="-i $HOME/.ssh/ruyaos_dev -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
r() { ssh $SSHO "root@$HOST" "$@"; }
BUS='runuser -u ruya-shell -- busctl --system'
ORDER="${RUYA_BENCH_ORDER:-balance_performance performance performance balance_performance}"
GAME_SECS="${RUYA_BENCH_GAME_SECS:-30}"
D=/var/tmp/epp-bench

r 'pgrep -x ruya-shell >/dev/null' || { echo "DELL EPP BENCH NOT RUN: the Dell is not reachable or ruya-shell is not running"; exit 2; }
r 'ls /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference /sys/class/powercap/intel-rapl:0/energy_uj >/dev/null' \
    || { echo "DELL EPP BENCH NOT RUN: no EPP file or no RAPL package counter on this machine"; exit 2; }

# The restore script lives on the Dell: it needs nothing from this host.
r "mkdir -p $D && cat > $D/restore.sh && chmod +x $D/restore.sh" <<'EOF'
#!/bin/bash
# put EPP back on every policy from the saved list (policy path, value)
[ -f /var/tmp/epp-bench/orig ] || exit 0
while read -r p v; do echo "$v" > "$p" 2>/dev/null; done < /var/tmp/epp-bench/orig
EOF
r "mkdir -p $D && : > $D/orig && for p in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do echo \"\$p \$(cat \$p)\" >> $D/orig; done; systemctl stop epp-bench-restore.timer epp-bench-restore.service 2>/dev/null; systemd-run --quiet --unit=epp-bench-restore --on-active=45min /var/tmp/epp-bench/restore.sh"
echo "original EPP: $(r "awk '{print \$2}' $D/orig | sort | uniq -c | tr '\n' ' '")"

restore() {
    trap - EXIT INT TERM
    r "$D/restore.sh; systemctl stop epp-bench-restore.timer epp-bench-restore.service 2>/dev/null"
    echo "EPP now: $(r "cat /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference | sort | uniq -c | tr '\n' ' '")"
}
trap restore EXIT
trap 'exit 130' INT TERM

setepp() { r "for p in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do echo $1 > \$p; done; cat /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference | sort -u | tr '\n' ' '"; }

# Stop every app (Home), settle 20 s, RAPL package energy over 60 s. Prints "<watts> <temp C>".
idle() {
    for i in $(r "$BUS --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning" | grep -o 'ruya-app-[^"]*service'); do
        r "$BUS call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Stop s $i" >/dev/null
    done
    r 'bash -s' <<'EOF'
sleep 20
z=/sys/class/powercap/intel-rapl:0
max=$(cat $z/max_energy_range_uj)
e0=$(cat $z/energy_uj); t0=$(date +%s.%N)
sleep 60
e1=$(cat $z/energy_uj); t1=$(date +%s.%N)
[ "$e1" -lt "$e0" ] && e1=$((e1 + max))
temp=0
for t in /sys/class/thermal/thermal_zone*; do [ "$(cat $t/type)" = x86_pkg_temp ] && temp=$(( $(cat $t/temp) / 1000 )); done
awk -v a="$e0" -v b="$e1" -v s="$t0" -v e="$t1" -v t="$temp" 'BEGIN{printf "%.2f %d\n", (b - a) / 1e6 / (e - s), t}'
EOF
}

summary=""
n=0
for epp in $ORDER; do
    n=$((n + 1))
    echo "== run $n: EPP $epp (set: $(setepp "$epp"))"
    set -- $(idle)
    [ $# -eq 2 ] || { echo "DELL EPP BENCH NOT RUN: no idle reading"; exit 2; }
    iw=$1; it=$2
    echo "idle on Home, 60 s: package $iw W, package temperature $it C"
    out=$(RUYA_HUB_ONLY_FPS=1 RUYA_HUB_FPS_SECS="$GAME_SECS" "$HERE/dell-hub-check.sh" "$HOST" 2>&1)
    rc=$?
    echo "$out" | grep -E 'Game FPS|frame time p99|NOT RUN' | sed 's/^/  /'
    [ "$rc" -eq 2 ] && { echo "DELL EPP BENCH NOT RUN: dell-hub-check.sh could not run"; exit 2; }
    # Closed-Hub FPS is the first number of "Game FPS: Hub closed <fps> (<n> samples)".
    fps=$(echo "$out" | sed -n 's/^Game FPS: Hub closed \([0-9.]*\) .*/\1/p' | head -1)
    p99=$(echo "$out" | sed -n 's/.*p99 (Hub closed): mean \([0-9.]*\) ms, worst \([0-9.]*\) ms; package temperature at the end of the window: \([0-9?]*\) C.*/\1 \2 \3/p' | head -1)
    summary="$summary
run $n  $epp  idle ${iw} W (${it} C)  SuperTuxKart ${fps:-?} FPS  p99 mean/worst ${p99:-? ? ?} (ms, ms, end temp C)"
done
echo
echo "== summary (idle W over 60 s on Home; FPS and p99 over ${GAME_SECS} s, Hub closed)$summary"
