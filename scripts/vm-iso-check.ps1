# Lead-run VM check (T-178): install the installer ISO onto a blank scratch disk in QEMU, boot the
# installed disk and require that it reaches the shell and greenboot's success with no manual step.
#   .\scripts\vm-iso-check.ps1 [-Iso output\bootiso\install.iso] [-Disk output\iso-test.qcow2]
#                              [-InstallTimeoutSec 1800] [-BootTimeoutSec 900] [-KeepDisk]
# Steps: 1. blank 64G qcow2  2. QEMU boots the ISO (it installs automatically and erases the disk;
# the serial log ends with "Install finished" and -no-reboot makes QEMU exit)  3. smoke-test.ps1
# -Disk ... -Persistent -Keep must print RUYA_BOOT_OK  4. over SSH: default.target, greenboot's
# health check, the version. The scratch disk is deleted at the end, also on failure (-KeepDisk keeps it).
# Takes about 10 minutes; not part of dev.ps1 test. Needs image/bib/config.toml's SSH key
# (%USERPROFILE%\.ssh\ruyaos_dev) in the ISO, as for every VM check. Exits 0 when everything holds.
param(
    [string]$Iso = "output\bootiso\install.iso",
    [string]$Disk = "output\iso-test.qcow2",
    [int]$InstallTimeoutSec = 1800,
    [int]$BootTimeoutSec = 900,
    [string]$QemuDir = "C:\Program Files\qemu",
    [string]$Key = (Join-Path $env:USERPROFILE ".ssh\ruyaos_dev"),
    [switch]$KeepDisk
)
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo

# T-193: the script deletes the scratch disk first and at the end, so -Disk must be a file strictly
# inside <repo>\output\. A relative path is taken from the repository root, an absolute one as it is
# (Join-Path would glue it to the root); ".." parts are resolved before the comparison.
function Resolve-ScratchDisk([string]$Path, [string]$Root) {
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $Root $Path)) }
    $outDir = [System.IO.Path]::GetFullPath((Join-Path $Root "output")).TrimEnd('\') + '\'
    if (-not $full.StartsWith($outDir, [System.StringComparison]::OrdinalIgnoreCase) -or $full.Length -le $outDir.Length) {
        throw "refusing -Disk '$Path' (resolves to $full): it is deleted before and after the check, so it must be a file inside $outDir"
    }
    return $full
}
$diskFull = Resolve-ScratchDisk $Disk $Repo

$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$qemuImg = Join-Path $QemuDir "qemu-img.exe"
$ovmf = Join-Path $QemuDir "share\edk2-x86_64-code.fd"
foreach ($f in $qemu, $qemuImg, $ovmf, $Iso, $Key) { if (-not (Test-Path $f)) { throw "missing: $f" } }
$isoFull = (Resolve-Path $Iso).Path
$installLog = Join-Path $Repo "output\iso-install-serial.log"
$KnownHosts = Join-Path $Repo "output\vm-known_hosts"
$ssh = @("-i", $Key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$KnownHosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-p", "2222")

function Stop-Qemu { Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }

if (Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue) { throw "a QEMU is already running; stop it first (one VM at a time)" }

$report = [ordered]@{}
$ok = $false
try {
    # 1. blank disk (sparse; the ISO's kickstart partitions it)
    Remove-Item $diskFull, $installLog -ErrorAction SilentlyContinue
    & $qemuImg create -f qcow2 $diskFull 64G | Out-Null
    if (-not (Test-Path $diskFull)) { throw "could not create $diskFull" }

    # 2. install. The disk is blank, so UEFI falls through to the ISO. No monitor or port forward:
    # the install needs no network, and smoke-test.ps1 uses those ports for the boot afterwards.
    $args1 = @(
        "-machine", "q35", "-accel", "whpx,kernel-irqchip=off", "-cpu", "max", "-smp", "4", "-m", "4096",
        "-drive", "if=pflash,format=raw,readonly=on,file=$ovmf",
        "-drive", "file=$diskFull,if=virtio,format=qcow2",
        "-drive", "file=$isoFull,media=cdrom,readonly=on",
        "-device", "virtio-vga", "-display", "none",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-nic", "user,model=virtio-net-pci",
        "-serial", "file:$installLog",
        "-no-reboot"
    ) | ForEach-Object { if ($_ -match ' ') { '"' + $_ + '"' } else { $_ } }
    $vm = Start-Process -FilePath $qemu -ArgumentList $args1 -PassThru -WindowStyle Hidden
    Write-Host "installing: QEMU pid $($vm.Id), up to $InstallTimeoutSec s ($installLog)"
    $start = Get-Date
    $deadline = $start.AddSeconds($InstallTimeoutSec)
    $finished = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $installLog) {
            $t = Get-Content $installLog -Raw -ErrorAction SilentlyContinue
            if ($t -match "Install finished") { $finished = $true }
        }
        if ($vm.HasExited) { break }
        if ($finished) { $vm.WaitForExit(60000) | Out-Null; break }
        Start-Sleep -Seconds 5
    }
    $report["install"] = if ($finished) { "Install finished after {0:N0} s" -f ((Get-Date) - $start).TotalSeconds } else { "NO 'Install finished' within $InstallTimeoutSec s (qemu exited: $($vm.HasExited))" }
    Stop-Qemu
    Write-Host $report["install"]
    if (-not $finished) { throw "install did not finish; see $installLog" }

    # 3. first boot of the installed disk: persistent (the first boots write to it), VM kept for SSH.
    & (Join-Path $PSScriptRoot "smoke-test.ps1") -Disk $diskFull -Persistent -Keep -TimeoutSec $BootTimeoutSec
    $boot = $LASTEXITCODE
    $serial = Get-Content (Join-Path $Repo "output\serial.log") -Raw -ErrorAction SilentlyContinue
    $report["boot"] = if ($serial -match "RUYA_BOOT_(OK|FAIL)[^\r\n]*") { $Matches[0] } else { "no marker (exit $boot)" }
    if ($boot -ne 0) { throw "installed disk did not print RUYA_BOOT_OK: $($report['boot'])" }

    # 4. state of the installed system. Greenboot's verdict can lag the shell by a minute: poll.
    $probe = Join-Path $Repo "output\iso-probe.sh"
    $lines = @(
        'echo "default.target: $(systemctl get-default)"',
        'echo "etc default.target link: $(readlink /etc/systemd/system/default.target)"',
        'echo "version: $(cat /usr/lib/ruyaos/version)"',
        'for f in /boot/loader/entries/*.conf; do [ -e "$f" ] || { echo "boot entries: none in /boot/loader/entries"; break; }; echo "boot entry $(basename "$f"): $(sed -n "s/^title[[:space:]]*//p" "$f")"; done',
        '. /usr/lib/os-release; echo "pretty name: $PRETTY_NAME"',
        'echo "greenboot-healthcheck: $(systemctl is-active greenboot-healthcheck.service)"',
        'echo "boot-complete.target: $(systemctl is-active boot-complete.target)"',
        'echo "greenboot-success.target: $(systemctl is-active greenboot-success.target)"',
        'echo "grubenv: $(grub2-editenv list 2>&1 | tr "\n" " ")"',
        'echo "bootc: $(bootc status --format humanreadable 2>&1 | head -4 | tr "\n" " ")"'
    )
    [System.IO.File]::WriteAllText($probe, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    scp -i $Key -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$KnownHosts" -o LogLevel=ERROR -P 2222 $probe root@127.0.0.1:/root/iso-probe.sh 2>$null | Out-Null
    $state = ""
    $until = (Get-Date).AddSeconds(240)
    do {
        $state = (ssh @ssh root@127.0.0.1 "sh /root/iso-probe.sh" 2>$null) -join "`n"
        if ($state -match "greenboot-healthcheck: active" -and $state -match "greenboot-success.target: active") { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $until)
    Write-Host $state
    $report["state"] = $state
    $okGreenboot = ($state -match "greenboot-healthcheck: active") -and ($state -match "greenboot-success.target: active")
    $report["greenboot"] = if ($okGreenboot) { "success" } else { "NOT reported as success" }
    $ok = $okGreenboot
} catch {
    Write-Host "FAILED: $_"
} finally {
    Stop-Qemu
    if (-not $KeepDisk) { Remove-Item $diskFull -ErrorAction SilentlyContinue; Write-Host "deleted $diskFull" }
}

Write-Host ""
Write-Host "vm-iso-check: install=$($report['install']); boot=$($report['boot']); greenboot=$($report['greenboot'])"
if ($ok) { Write-Host "ISO CHECK PASSED"; exit 0 }
Write-Host "ISO CHECK FAILED"
exit 1
