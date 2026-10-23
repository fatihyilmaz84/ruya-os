# Headless boot test on Windows (QEMU + WHPX): boots the qcow2 and waits for the shell's
# readiness marker on the serial port (written by ruya-boot-marker.service in VMs).
#   .\scripts\smoke-test.ps1 [-Disk output\qcow2\disk.qcow2] [-TimeoutSec 600] [-Keep] [-Audio [-AudioBackend wav]]
# -Keep leaves the VM running (SSH on localhost:2222) instead of stopping it after the result.
# Runs on a snapshot (the disk image is never modified) unless -Persistent is given, which the
# update/rollback drill needs so deployments survive reboots. Use it on a copy of the disk.
# -Work is the usual way to get that copy: it boots output\qcow2\work.qcow2 persistently, and
# makes it again from disk.qcow2 whenever make-disk.sh wrote a newer disk.qcow2. There is one
# working copy for every task (each copy is ~2.6 GB; per-task copies filled the disk).
param(
    [string]$Disk = "output\qcow2\disk.qcow2",
    [int]$TimeoutSec = 600,
    [string]$QemuDir = "C:\Program Files\qemu",
    [switch]$Keep,
    [switch]$Persistent,
    [switch]$Work,
    # Adds an Intel HDA sound card. dsound plays on the host's default output; wav records what the
    # guest plays to output\vm-audio.wav (written when QEMU exits), so a check needs no ears.
    [switch]$Audio,
    [ValidateSet("dsound", "wav")][string]$AudioBackend = "dsound"
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo

$qcowDir = Join-Path $Repo "output\qcow2"
if ($Work) {
    # Not $work: PowerShell names ignore case, so that would overwrite the -Work switch.
    $workDisk = Join-Path $qcowDir "work.qcow2"
    if (-not (Test-Path $workDisk) -or (Get-Item $Disk).LastWriteTime -gt (Get-Item $workDisk).LastWriteTime) {
        Write-Host "work disk: fresh copy of $Disk"
        Copy-Item $Disk $workDisk -Force
    } else {
        Write-Host "work disk: reusing $workDisk (its state is kept; delete it for a fresh one)"
    }
    $Disk = $workDisk
    $Persistent = $true
}
$snapshot = if ($Persistent) { "off" } else { "on" }

# Anything else in output\qcow2 is a leftover copy: say so, with its size.
$stale = Get-ChildItem $qcowDir -Filter *.qcow2 -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @("disk.qcow2", "work.qcow2") }
if ($stale) {
    $gb = [math]::Round(($stale | Measure-Object Length -Sum).Sum / 1GB, 1)
    Write-Warning "stale VM disks in output\qcow2 ($gb GB): $($stale.Name -join ', '). Delete them unless a drill is running (use -Work)."
}
$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$ovmf = Join-Path $QemuDir "share\edk2-x86_64-code.fd"
foreach ($f in $qemu, $ovmf, $Disk) { if (-not (Test-Path $f)) { throw "missing: $f" } }

$serial = Join-Path $Repo "output\serial.log"
# A stale log would report the last run's marker: if a QEMU still holds it, stop here.
Remove-Item $serial -ErrorAction SilentlyContinue
if (Test-Path $serial) { throw "cannot delete $serial (is another QEMU still running?)" }

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
if (-not $Keep -and -not $vm.HasExited) { Stop-Process -Id $vm.Id -Force; $vm.WaitForExit(30000) | Out-Null }
if ($Keep -and -not $vm.HasExited) { Write-Host "VM left running (pid $($vm.Id)); ssh -p 2222 dev@localhost" }
if ($result -like "RUYA_BOOT_OK*") { exit 0 }
exit 1
