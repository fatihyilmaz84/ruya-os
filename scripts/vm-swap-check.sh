#!/usr/bin/env bash
# Checks the image's swap (T-465, docs/specs/01-platform.md 1.4) inside a running VM, as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-swap-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-swap-check.sh [check]
#
#   check   /dev/zram0 exists with disksize = min(RAM / 2, 4096 MiB) and algorithm zstd, it is the only
#           swap and is on (/proc/swaps), vm.swappiness is the kernel default 60, systemd-oomd has not
#           failed and has no swap-kill policy on any slice, and the swap really takes memory: a
#           transient service holds 256 MiB of compressible data, `memory.reclaim` pushes it out, and
#           the cgroup's swap use and zram's compressed size are checked (compressed < 50% of original).
#           The service is stopped again, also when the check stops early (exit trap).
set -u
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
unit=ruya-swap-check
cleanup() { systemctl stop "$unit.service" 2>/dev/null; systemctl reset-failed "$unit.service" 2>/dev/null; }
trap cleanup EXIT

check() {
    echo "--- zram device"
    if [ -b /dev/zram0 ]; then ok "/dev/zram0 exists"; else bad "/dev/zram0 does not exist"; return; fi
    ram_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    ram_mib=$(( ram_kb / 1024 ))
    want_mib=$(( ram_mib / 2 )); [ "$want_mib" -gt 4096 ] && want_mib=4096
    got="$(cat /sys/block/zram0/disksize)"
    got_mib=$(( got / 1048576 ))
    diff=$(( got_mib - want_mib )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -le 1 ]; then
        ok "disksize $got_mib MiB = min(RAM $ram_mib MiB / 2, 4096)"
    else
        bad "disksize $got_mib MiB, expected about $want_mib MiB (RAM $ram_mib MiB)"
    fi
    algo="$(cat /sys/block/zram0/comp_algorithm)"
    case "$algo" in *"[zstd]"*) ok "compression algorithm zstd ($algo)" ;; *) bad "compression algorithm: $algo" ;; esac

    echo "--- swap is on"
    swaps="$(tail -n +2 /proc/swaps)"
    n="$(printf '%s\n' "$swaps" | grep -c .)"
    if [ "$n" = 1 ] && printf '%s\n' "$swaps" | grep -q '^/dev/zram0 '; then
        ok "/dev/zram0 is the only swap: $(printf '%s' "$swaps" | tr -s ' \t' ' ')"
    else
        bad "swap devices: ${swaps:-none}"
    fi
    systemctl is-active -q systemd-zram-setup@zram0.service && ok "systemd-zram-setup@zram0.service is active" \
        || bad "systemd-zram-setup@zram0.service: $(systemctl is-active systemd-zram-setup@zram0.service)"
    if swapon --show=NAME,PRIO --noheadings | grep -q '^/dev/zram0 *100$'; then ok "swap priority 100"; else bad "swap priority: $(swapon --show=NAME,PRIO --noheadings)"; fi

    echo "--- kernel defaults and systemd-oomd"
    sw="$(sysctl -n vm.swappiness)"
    [ "$sw" = 60 ] && ok "vm.swappiness = 60 (kernel default, unchanged)" || bad "vm.swappiness = $sw (expected the kernel default 60)"
    state="$(systemctl is-active systemd-oomd.service)"
    case "$state" in failed) bad "systemd-oomd.service failed" ;; *) ok "systemd-oomd.service is $state (not failed)" ;; esac
    if grep -rqs '^ManagedOOM' /usr/lib/systemd/system /etc/systemd/system /run/systemd/system 2>/dev/null; then
        bad "a unit sets ManagedOOM*: $(grep -rls '^ManagedOOM' /usr/lib/systemd/system /etc/systemd/system /run/systemd/system 2>/dev/null | tr '\n' ' ')"
    else
        ok "no unit sets ManagedOOM* (oomd watches nothing; swap use cannot make it kill)"
    fi

    echo "--- the swap takes memory"
    reclaim_check
}

reclaim_check() {
    if ! command -v python3 >/dev/null; then echo "UNVERIFIED: python3 is missing, the reclaim part was skipped"; return; fi
    cleanup
    # 256 MiB of very compressible data (a repeating pattern: this proves the plumbing, not the ratio of a real game, which was 3.1x), held until stopped.
    systemd-run -q --unit="$unit" -p MemoryAccounting=yes -p MemorySwapMax=infinity \
        python3 -c 'import time; b = bytearray(b"ruyaos-" * (256 * 1024 * 1024 // 7)); print("held", len(b), flush=True); time.sleep(600)' \
        >/dev/null 2>&1 || { bad "could not start the transient memory holder"; return; }
    cg="/sys/fs/cgroup/system.slice/$unit.service"
    for _ in $(seq 1 40); do
        [ -r "$cg/memory.current" ] && [ "$(cat "$cg/memory.current")" -gt 200000000 ] && break
        sleep 0.25
    done
    cur="$(cat "$cg/memory.current" 2>/dev/null || echo 0)"
    if [ "$cur" -le 200000000 ]; then bad "the holder never reached 200 MB (memory.current=$cur)"; return; fi
    if [ ! -w "$cg/memory.reclaim" ]; then echo "UNVERIFIED: $cg/memory.reclaim is missing (kernel older than 5.19?), the reclaim part was skipped"; return; fi
    before="$(awk '{print $3}' /sys/block/zram0/mm_stat)"
    echo 200M > "$cg/memory.reclaim" 2>/dev/null || true
    sleep 1
    swapped="$(cat "$cg/memory.swap.current" 2>/dev/null || echo 0)"
    read -r orig compr used _ < /sys/block/zram0/mm_stat
    echo "info: swapped out $((swapped / 1048576)) MiB; zram holds $((orig / 1048576)) MiB as $((compr / 1048576)) MiB (mem used $((used / 1048576)) MiB); before: $before"
    if [ "$swapped" -gt 100000000 ]; then ok "memory.reclaim moved $((swapped / 1048576)) MiB of the holder into swap"; else bad "only $swapped bytes in swap after memory.reclaim 200M"; fi
    if [ "$orig" -gt 0 ] && [ $(( compr * 2 )) -lt "$orig" ]; then ok "zram compresses it to under half (${orig} -> ${compr} bytes)"; else bad "zram mm_stat: orig=$orig compressed=$compr"; fi
    cleanup
    sleep 1
    after="$(awk '{print $1}' /sys/block/zram0/mm_stat)"
    [ "$after" -lt 20000000 ] && ok "swap is given back when the holder stops (zram holds $after bytes)" || bad "zram still holds $after bytes after the holder stopped"
}

case "${1:-check}" in
    check) check ;;
    *) echo "usage: vm-swap-check.sh [check]"; exit 2 ;;
esac
if [ "$fail" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$fail"
