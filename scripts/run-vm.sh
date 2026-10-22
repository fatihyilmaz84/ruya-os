#!/usr/bin/env bash
# Boot the qcow2 in QEMU/KVM with UEFI. Serial console is written to output/serial.log.
#   scripts/run-vm.sh [disk.qcow2] [--headless]
# Functional testing only: virtio-gpu frame rates are not KPI data.
set -euo pipefail
cd "$(dirname "$0")/.."

disk="${1:-output/qcow2/disk.qcow2}"
headless="${2:-}"

ovmf=""
for candidate in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do
    [[ -f "$candidate" ]] && { ovmf="$candidate"; break; }
done
[[ -n "$ovmf" ]] || { echo "OVMF firmware not found (install edk2-ovmf / ovmf)" >&2; exit 1; }

display=(-device virtio-vga-gl -display gtk,gl=on)
if [[ "$headless" == "--headless" ]]; then
    display=(-device virtio-vga -display none)
fi

accel=(-enable-kvm -cpu host)
[[ -w /dev/kvm ]] || { echo "warning: no /dev/kvm, falling back to TCG (slow)" >&2; accel=(-cpu max); }

exec qemu-system-x86_64 \
    -machine q35 "${accel[@]}" -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf" \
    -drive file="$disk",if=virtio,format=qcow2,snapshot="${SNAPSHOT:-off}" \
    "${display[@]}" \
    -device qemu-xhci -device usb-tablet -device usb-kbd \
    -audiodev "${AUDIODEV:-pa},id=snd0" -device intel-hda -device hda-output,audiodev=snd0 \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
    -serial file:output/serial.log
