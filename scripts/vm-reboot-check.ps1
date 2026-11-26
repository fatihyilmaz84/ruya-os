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
# -Shutdown (RUY-888): before the reboot `vm-session-check.sh shutdown` (a frozen test game that
# saves at quit, its profile locked; ruya-session's shutdown delay lock), after it
# `vm-session-check.sh shutdown-verify` (the game was stopped and saved before the shutdown, and the
# previous boot's journal has no SIGKILL of its user manager). Needs a profile (run
# `vm-session-check.sh check` once on an empty store first).
# -PadShutdown (RUY-1238): before the reboot `vm-input-check.sh shutdown` (the Wayland test app
# frozen behind Home with its virtual pad, the shell signed in), after it `vm-input-check.sh
# shutdown-verify` (no virtual pad destroyed and no route away from the game before its unit ended
# while the system went down). Needs the shell, a profile and the Wayland test app (`vm-session-check.sh
# display`); not with -Shutdown, which locks the console (a Lock takes the pads).
# Exits with smoke-test.ps1's result (0 = the shell became ready on the new boot); with
# -SavedOutput also 1 when the saved output is not the default again, with -Shutdown or -PadShutdown
# also 1 when either half printed a FAIL line.
param(
    [string]$Disk = "output\qcow2\drill.qcow2",
    [int]$TimeoutSec = 600,
    [switch]$SavedOutput,
    [switch]$Shutdown,
    [switch]$PadShutdown,
    [switch]$Audio,
    [string]$Key = (Join-Path $env:USERPROFILE ".ssh\ruyaos_dev")
)
$ErrorActionPreference = "Continue"
if ($Shutdown -and $PadShutdown) { throw "-Shutdown and -PadShutdown each need their own reboot: run them one after the other" }
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
# The two halves around the reboot: `shutdown` before it, `shutdown-verify` after it, of this script, which
# needs these files in /root.
$halves = $null
if ($Shutdown) { $halves = @{ script = "vm-session-check.sh"; files = @("vm-session-check.sh") } }
if ($PadShutdown) {
    $halves = @{ script = "vm-input-check.sh"; files = @("vm-input-check.sh", "vm-input-probe.py", "vm_dbus.py", "vm_uinput_trust.py", "vm-inject-key.py") }
}
$shutdownFailed = $false
if ($halves) {
    $scp = @($o[0..($o.Count - 3)] + @("-P", "2222"))
    $files = @($halves.files | ForEach-Object { Join-Path $PSScriptRoot $_ })
    scp @scp @files root@127.0.0.1:/root/ 2>$null | Out-Null
    $before = ssh @o root@127.0.0.1 "bash /root/$($halves.script) shutdown" 2>$null
    $before
    if (($before | Out-String) -match "(?m)^FAIL:") { $shutdownFailed = $true }
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
if ($halves) {
    $after = ssh @o root@127.0.0.1 "bash /root/$($halves.script) shutdown-verify" 2>$null
    $after
    if ($shutdownFailed -or (($after | Out-String) -match "(?m)^FAIL:") -or (($after | Out-String) -notmatch "PASS:")) { $code = 1 }
}
exit $code
