#!/usr/bin/env bash
# Headless boot test: boots the qcow2 and waits for the shell's readiness marker on serial.
#   scripts/smoke-test.sh [disk.qcow2] [timeout-seconds]
set -euo pipefail
cd "$(dirname "$0")/.."

disk="${1:-output/qcow2/disk.qcow2}"
timeout="${2:-420}"
rm -f output/serial.log

AUDIODEV=none SNAPSHOT=on scripts/run-vm.sh "$disk" --headless &
qemu_pid=$!
trap 'kill $qemu_pid 2>/dev/null || true' EXIT

for ((t = 0; t < timeout; t += 5)); do
    if grep -q "RUYA_BOOT_OK" output/serial.log 2>/dev/null; then
        grep "RUYA_BOOT_OK" output/serial.log
        exit 0
    fi
    if grep -q "RUYA_BOOT_FAIL" output/serial.log 2>/dev/null; then
        echo "shell did not become ready" >&2
        exit 1
    fi
    kill -0 $qemu_pid 2>/dev/null || { echo "qemu exited early" >&2; exit 1; }
    sleep 5
done
echo "timed out after ${timeout}s waiting for the boot marker" >&2
exit 1
