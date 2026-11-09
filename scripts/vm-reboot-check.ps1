# Reboot the persistent test VM and report its state after boot: deployed versions, shell
# readiness and greenboot's verdict. The VM must have been started with
#   .\scripts\smoke-test.ps1 -Disk output\qcow2\drill.qcow2 -Persistent -Keep
# QEMU runs with -no-reboot (WHPX hangs on guest reset), so this script waits for QEMU to exit
# after the guest reboots and starts it again on the same disk: a cold restart, which is
# equivalent for bootc because the deployment choice is stored on disk.
#   .\scripts\vm-reboot-check.ps1 [-Disk output\qcow2\drill.qcow2] [-TimeoutSec 600] [-SavedOutput]
# -SavedOutput (T-360): before the reboot choose a sound output (SetOutput), after it check that
# output is the default again (scripts/vm-saved-output-check.sh, AUDIO_REBOOT_SAVED_OUTPUT_OK).
# -Audio restarts the VM with a sound card (implied by -SavedOutput: without one the saved output
# cannot come back and the default is auto_null).
# Exits with smoke-test.ps1's result (0 = the shell became ready on the new boot); with
# -SavedOutput also 1 when the saved output is not the default again.
param(
    [string]$Disk = "output\qcow2\drill.qcow2",
    [int]$TimeoutSec = 600,
    [switch]$SavedOutput,
    [switch]$Audio,
    [string]$Key = (Join-Path $env:USERPROFILE ".ssh\ruyaos_dev")
)
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
# A scratch known_hosts: every fresh disk has a new host key, and the ssh on PATH here may be
# MSYS2's, which writes a real file named NUL for UserKnownHostsFile=NUL.
$KnownHosts = Join-Path $Repo "output\vm-known_hosts"
$o = @("-i", $Key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$KnownHosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-p", "2222")

if ($SavedOutput) {
    $scp = @($o[0..($o.Count - 3)] + @("-P", "2222"))
    scp @scp (Join-Path $PSScriptRoot "vm-saved-output-check.sh") root@127.0.0.1:/root/ 2>$null | Out-Null
    ssh @o root@127.0.0.1 "bash /root/vm-saved-output-check.sh choose" 2>$null
}
ssh @o root@127.0.0.1 "systemctl reboot" 2>$null | Out-Null
Write-Host "guest reboot requested; waiting for QEMU to exit"
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force

$smokeArgs = @{ Disk = $Disk; Persistent = $true; Keep = $true; TimeoutSec = $TimeoutSec }
if ($Audio -or $SavedOutput) { $smokeArgs.Audio = $true }
& (Join-Path $PSScriptRoot "smoke-test.ps1") @smokeArgs
$code = $LASTEXITCODE
# Give greenboot's health check time to record its verdict before reporting.
Start-Sleep -Seconds 30
ssh @o root@127.0.0.1 "sh /root/vm-state.sh" 2>$null
if ($SavedOutput) {
    $saved = ssh @o root@127.0.0.1 "bash /root/vm-saved-output-check.sh verify" 2>$null
    $saved
    if (($saved | Out-String) -notmatch "AUDIO_REBOOT_SAVED_OUTPUT_OK") { $code = 1 }
}
exit $code
