# Reboot the persistent test VM and report its state after boot: deployed versions, shell
# readiness and greenboot's verdict. The VM must have been started with
#   .\scripts\smoke-test.ps1 -Disk output\qcow2\drill.qcow2 -Persistent -Keep
# QEMU runs with -no-reboot (WHPX hangs on guest reset), so this script waits for QEMU to exit
# after the guest reboots and starts it again on the same disk: a cold restart, which is
# equivalent for bootc because the deployment choice is stored on disk.
#   .\scripts\vm-reboot-check.ps1 [-Disk output\qcow2\drill.qcow2] [-TimeoutSec 600]
# Exits with smoke-test.ps1's result (0 = the shell became ready on the new boot).
param(
    [string]$Disk = "output\qcow2\drill.qcow2",
    [int]$TimeoutSec = 600,
    [string]$Key = (Join-Path $env:USERPROFILE ".ssh\ruyaos_dev")
)
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
$o = @("-i", $Key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-p", "2222")

ssh @o root@127.0.0.1 "systemctl reboot" 2>$null | Out-Null
Write-Host "guest reboot requested; waiting for QEMU to exit"
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force

& (Join-Path $PSScriptRoot "smoke-test.ps1") -Disk $Disk -Persistent -Keep -TimeoutSec $TimeoutSec
$code = $LASTEXITCODE
# Give greenboot's health check time to record its verdict before reporting.
Start-Sleep -Seconds 30
ssh @o root@127.0.0.1 "sh /root/vm-state.sh" 2>$null
exit $code
