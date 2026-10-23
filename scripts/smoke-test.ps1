# Headless boot test on Windows (QEMU + WHPX): boots the qcow2 and waits for the shell's
# readiness marker on the serial port (written by ruya-boot-marker.service in VMs).
#   .\scripts\smoke-test.ps1 [-Disk output\qcow2\disk.qcow2] [-TimeoutSec 600] [-Keep] [-Audio [-AudioBackend wav]]
# -Keep leaves the VM running (SSH on localhost:2222) instead of stopping it after the result.
# Runs on a snapshot (the disk image is never modified) unless -Persistent is given, which the
# update/rollback drill needs so deployments survive reboots. Use it on a copy of the disk.
param(
    [string]$Disk = "output\qcow2\disk.qcow2",
    [int]$TimeoutSec = 600,
    [string]$QemuDir = "C:\Program Files\qemu",
    [switch]$Keep,
    [switch]$Persistent,
    # Adds an Intel HDA sound card. dsound plays on the host's default output; wav records what the
    # guest plays to output\vm-audio.wav (written when QEMU exits), so a check needs no ears.
    [switch]$Audio,
    [ValidateSet("dsound", "wav")][string]$AudioBackend = "dsound"
)
$snapshot = if ($Persistent) { "off" } else { "on" }

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$ovmf = Join-Path $QemuDir "share\edk2-x86_64-code.fd"
foreach ($f in $qemu, $ovmf, $Disk) { if (-not (Test-Path $f)) { throw "missing: $f" } }

$serial = Join-Path $Repo "output\serial.log"
Remove-Item $serial -ErrorAction SilentlyContinue

$qemuArgs = @(
    "-machine", "q35", "-accel", "whpx,kernel-irqchip=off", "-cpu", "max", "-smp", "4", "-m", "4096",
    "-drive", "if=pflash,format=raw,readonly=on,file=$ovmf",
    "-drive", "file=$Disk,if=virtio,format=qcow2,snapshot=$snapshot",
    "-device", "virtio-vga", "-display", "none",
    "-device", "qemu-xhci", "-device", "usb-kbd",
    "-nic", "user,model=virtio-net-pci,hostfwd=tcp::2222-:22",
    "-serial", "file:$serial",
    # Human monitor on a local port: vm-screenshot.ps1 and vm-keys.ps1 use it (never a public address).
    "-monitor", "tcp:127.0.0.1:4444,server,nowait",
    # QEMU on WHPX hangs on guest reset (0% CPU after "reboot: Restarting system"), so a guest
    # reboot makes QEMU exit instead; vm-reboot-check.ps1 relaunches it on the same disk.
    "-no-reboot"
)
if ($Audio) {
    $audiodev = if ($AudioBackend -eq "wav") { "wav,id=snd0,path=$(Join-Path $Repo 'output\vm-audio.wav')" } else { "dsound,id=snd0" }
    $qemuArgs += @("-audiodev", $audiodev, "-device", "intel-hda", "-device", "hda-output,audiodev=snd0")
}
# PS 5.1 Start-Process does not quote array elements: wrap any with spaces ("C:\Program Files").
$qemuArgs = $qemuArgs | ForEach-Object { if ($_ -match ' ') { '"' + $_ + '"' } else { $_ } }
$vm = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -WindowStyle Hidden
Write-Host "QEMU pid $($vm.Id); waiting up to $TimeoutSec s for the boot marker ($serial)"

$result = "timeout"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ($vm.HasExited) { $result = "qemu-exited"; break }
    if (Test-Path $serial) {
        $text = Get-Content $serial -Raw -ErrorAction SilentlyContinue
        if ($text -match "RUYA_BOOT_OK[^\r\n]*") { $result = $Matches[0]; break }
        if ($text -match "RUYA_BOOT_FAIL[^\r\n]*") { $result = $Matches[0]; break }
    }
    Start-Sleep -Seconds 5
}

Write-Host "result: $result"
if (-not $Keep -and -not $vm.HasExited) { Stop-Process -Id $vm.Id -Force }
if ($Keep -and -not $vm.HasExited) { Write-Host "VM left running (pid $($vm.Id)); ssh -p 2222 dev@localhost" }
if ($result -like "RUYA_BOOT_OK*") { exit 0 }
exit 1
