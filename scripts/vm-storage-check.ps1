# Drives scripts/vm-storage-check.sh (T-174, Devices1.Storage over udisks2) in a running VM and
# hot-plugs a USB stick through the QEMU monitor (device_add usb-storage). Start the VM first:
#   .\scripts\smoke-test.ps1 -Keep            (monitor on 127.0.0.1:4444, SSH on 2222, a qemu-xhci controller)
#   .\scripts\vm-storage-check.ps1
# Steps: baseline (no stick), attach a blank 64 MiB image, format it exFAT in the guest, detach it,
# start recording signals, attach it again (the hot-plug under test), then plugged, busy and eject
# checks; then (T-184) a second 96 MiB stick with three partitions, two exFAT and one ext2: every
# partition is listed with the same "drive", the ext2 one stays unmounted, one VolumeAdded per
# partition, and Eject of one partition takes the whole drive off. Finally systemd-analyze security.
# Exits 0 when every step passed.
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 4444,
    [int]$SshPort = 2222,
    [string]$Key = (Join-Path $env:USERPROFILE ".ssh\ruyaos_dev")
)
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "vm-lib.ps1")
$Repo = Split-Path -Parent $PSScriptRoot
# A scratch known_hosts (see vm-reboot-check.ps1): UserKnownHostsFile=NUL makes MSYS2's ssh write a file named NUL.
$KnownHosts = Join-Path $Repo "output\vm-known_hosts"
$ssh = @("-i", $Key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$KnownHosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10")

function Invoke-Guest([string]$Step) {
    Write-Host "== guest: $Step"
    & ssh @ssh -p $SshPort root@127.0.0.1 "bash /root/vm-storage-check.sh $Step" 2>&1 | ForEach-Object { Write-Host "$_" }
    return [int]$LASTEXITCODE
}

function Send-Monitor([string[]]$Commands) {
    # The monitor echoes every typed character with cursor codes; only its answers (errors) matter.
    foreach ($line in (Send-VmMonitor -Command $Commands -Port $Port)) {
        $plain = ($line -replace "\x1b\[[0-9;]*[A-Za-z]", "").Trim()
        if ($plain -match "(?i)error|could not|failed") { Write-Host "monitor: $($plain.Substring([Math]::Max(0, $plain.IndexOf('Error'))))" }
    }
}

$outDir = Join-Path $Repo "output"
New-Item -ItemType Directory -Force $outDir | Out-Null
$image = Join-Path $outDir "stick.img"
Remove-Item $image -ErrorAction SilentlyContinue
$fs = [System.IO.File]::Create($image)
$fs.SetLength(64MB)
$fs.Close()
$monitorImage = $image -replace "\\", "/"
$image2 = Join-Path $outDir "stick2.img"
$monitorImage2 = $image2 -replace "\\", "/"

& scp @ssh -P $SshPort (Join-Path $PSScriptRoot "vm-storage-check.sh") "root@127.0.0.1:/root/" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "scp failed: is the VM running (smoke-test.ps1 -Keep)?" }

$failed = @()
function Step([string]$Name) { if ((Invoke-Guest $Name) -ne 0) { $script:failed += $Name } }

Step "baseline"

Write-Host "== host: attach the blank stick"
Send-Monitor @("drive_add 0 if=none,id=stick0,format=raw,file=$monitorImage", "device_add usb-storage,id=stick,drive=stick0,removable=on")
Step "format"

Write-Host "== host: detach it again"
Send-Monitor @("device_del stick")
Step "gone"

Step "watch"
Write-Host "== host: hot-plug the formatted stick"
# device_del takes the legacy drive with it: define it again (the image keeps what was formatted).
Send-Monitor @("drive_add 0 if=none,id=stick0,format=raw,file=$monitorImage", "device_add usb-storage,id=stick,drive=stick0,removable=on")
Step "plugged"
Step "busy"
Step "eject"

# T-184: a stick with three partitions (two exFAT, one ext2 the service does not mount). The first
# stick is detached first (QEMU keeps the device after the guest powered it off).
Write-Host "== host: detach the first stick, attach a blank second one"
Send-Monitor @("device_del stick")
Step "gone"
Remove-Item $image2 -ErrorAction SilentlyContinue
$fs = [System.IO.File]::Create($image2)
$fs.SetLength(96MB)
$fs.Close()
Send-Monitor @("drive_add 0 if=none,id=stick1,format=raw,file=$monitorImage2", "device_add usb-storage,id=stick2,drive=stick1,removable=on")
Step "mformat"

Write-Host "== host: detach it again"
Send-Monitor @("device_del stick2")
Step "gone"
Step "watch"
Write-Host "== host: hot-plug the partitioned stick"
Send-Monitor @("drive_add 0 if=none,id=stick1,format=raw,file=$monitorImage2", "device_add usb-storage,id=stick2,drive=stick1,removable=on")
Step "mplugged"
Step "meject"

Step "security"

Write-Host "== host: clean up"
try { Send-Monitor @("device_del stick") } catch { }
try { Send-Monitor @("device_del stick2") } catch { }
Remove-Item $image -ErrorAction SilentlyContinue
Remove-Item $image2 -ErrorAction SilentlyContinue

if ($failed.Count -eq 0) { Write-Host "STORAGE CHECKS PASSED"; exit 0 }
Write-Host "STORAGE CHECKS FAILED: $($failed -join ', ')"
exit 1
