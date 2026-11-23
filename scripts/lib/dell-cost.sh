#!/bin/bash
# Runs on the Dell (lib/dell-common.sh shell_cost <seconds>). Over the given seconds (default 10):
# the shell's render ms (drm fdinfo, once per client id) and CPU ticks (utime+stime), the RAPL
# package-0 power and the x86_pkg_temp temperature at the end. Prints
# "<render ms> <cpu ticks> <watts> <degrees C>" ("-" where a counter is missing).
secs=${1:-10}
sp=$(pgrep -x ruya-shell | head -1); declare -A f a
for d in /proc/$sp/fdinfo/*; do id=$(awk '/drm-client-id/{print $2}' $d 2>/dev/null); [ -n "$id" ] && [ -z "${f[$id]:-}" ] && f[$id]=$d && a[$id]=$(awk '/drm-engine-render/{print $2}' $d); done
z=/sys/class/powercap/intel-rapl:0
e0=; [ -r $z/energy_uj ] && e0=$(cat $z/energy_uj)
c0=$(awk '{print $14+$15}' /proc/$sp/stat)
t0=$(date +%s.%N)
sleep "$secs"
t1=$(date +%s.%N)
t=0
for id in "${!f[@]}"; do b=$(awk '/drm-engine-render/{print $2}' ${f[$id]}); t=$((t + (b - a[$id]) / 1000000)); done
c1=$(awk '{print $14+$15}' /proc/$sp/stat)
w=-
if [ -n "$e0" ]; then
    e1=$(cat $z/energy_uj); max=$(cat $z/max_energy_range_uj)
    [ "$e1" -lt "$e0" ] && e1=$((e1 + max))
    w=$(awk -v a="$e0" -v b="$e1" -v s="$t0" -v e="$t1" 'BEGIN{printf "%.2f", (b - a) / 1e6 / (e - s)}')
fi
temp=-
for tz in /sys/class/thermal/thermal_zone*; do [ "$(cat $tz/type)" = x86_pkg_temp ] && temp=$(( $(cat $tz/temp) / 1000 )); done
echo "$t $((c1 - c0)) $w $temp"
