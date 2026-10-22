# Boot the qcow2 with QEMU for Windows (WHPX acceleration, no KVM).
#   .\scripts\run-vm.ps1 [-Disk output\qcow2\disk.qcow2]
# Graphics are software-rendered here: use it for functional checks, never for KPI numbers.
param(
    [string]$Disk = "output\qcow2\disk.qcow2",
    [string]$QemuDir = "C:\Program Files\qemu"
)
$ErrorActionPreference = "Stop"
$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$ovmf = Join-Path $QemuDir "share\edk2-x86_64-code.fd"
if (-not (Test-Path $qemu)) { throw "QEMU not found at $qemu" }
if (-not (Test-Path $ovmf)) { throw "UEFI firmware not found at $ovmf" }
if (-not (Test-Path $Disk)) { throw "Disk image not found: $Disk (build it with scripts/make-disk.sh)" }

& $qemu -machine q35 -accel whpx,kernel-irqchip=off -accel tcg -cpu max -smp 4 -m 4096 `
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf" `
    -drive "file=$Disk,if=virtio,format=qcow2" `
    -device virtio-vga -display sdl `
    -device qemu-xhci -device usb-tablet -device usb-kbd `
    -audiodev dsound,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 `
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 `
    -serial file:output\serial.log
