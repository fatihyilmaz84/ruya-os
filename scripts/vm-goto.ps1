# Takes a running VM (smoke-test.ps1 -Work -Keep, monitor on 127.0.0.1:4444, SSH on 2222) past the
# first-boot wizard to a named page and saves a screenshot of it (T-141).
#   .\scripts\vm-goto.ps1 settings-network       # -> output\vm-shots\settings-network.png
# Targets: home, settings-profiles, settings-network, settings-audio, store.
#
# Fixed wizard answers: English, profile "Player One" (admin), PIN 1234. With a profile already
# on the disk the wizard is skipped: the shell is locked and restarted (systemctl restart
# ruya-compositor@tty1), so it always starts at the profile picker, which is then signed in with
# the same PIN (the first profile listed).
#
# Why not "wait until the screen stops changing": the backdrop drifts all the time (about 7 %
# of the pixels change per second), so a screen is never still. Instead each key is followed by
# -SettleMs (the software-rendered shell lags the keys), and the steps that matter are checked
# in the guest over SSH: the Profiles service must list a profile after the wizard, and its
# ActiveProfile must be set after the sign-in. A step that does not show its evidence in time
# fails with its name.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [int]$Port = 4444,
    [int]$SshPort = 2222,
    [int]$SettleMs = 2500,
    [int]$StepTimeoutSec = 90
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "vm-lib.ps1")

$Pin = "1234"
$AdminName = "Player One"
$Key = Join-Path $env:USERPROFILE ".ssh\ruyaos_dev"
$Svc = "org.ruyaos.Profiles1"
$Path = "/org/ruyaos/Profiles1"

# Target -> keys from the home shelf (tiles: games media store settings power; Settings
# categories: profiles network bluetooth display audio storage ...).
$targets = @{
    "home"              = @()
    "store"             = @("right", "right", "ret")
    "settings-profiles" = @("right", "right", "right", "ret")
    "settings-network"  = @("right", "right", "right", "ret", "down")
    "settings-audio"    = @("right", "right", "right", "ret", "down", "down", "down", "down")
}
if (-not $targets.ContainsKey($Target)) {
    throw "vm-goto: unknown target '$Target'. Known: $(($targets.Keys | Sort-Object) -join ', ')"
}

function Invoke-Guest {
    param([Parameter(Mandatory)][string]$Command)
    $out = & ssh -i $Key -p $SshPort -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no `
        -o LogLevel=ERROR root@127.0.0.1 $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "vm-goto: SSH to the VM failed ($Command): $out" }
    return ($out | Out-String)
}

function Get-ProfileCount {
    $o = Invoke-Guest "busctl --system call $Svc $Path $Svc ListProfiles"
    return ([regex]::Matches($o, '"p\d+"')).Count
}

function Get-ActiveProfile {
    $o = Invoke-Guest "busctl --system get-property $Svc $Path $Svc ActiveProfile"
    if ($o -match '"(p\d+)"') { return $Matches[1] }
    return ""
}

function Wait-Until {
    param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][scriptblock]$Done)
    $deadline = (Get-Date).AddSeconds($StepTimeoutSec)
    while (-not (& $Done)) {
        if ((Get-Date) -gt $deadline) { throw "vm-goto: step '$Step' did not show its result within $StepTimeoutSec s" }
        Start-Sleep -Seconds 2
    }
}

# Share of the screen that is not black: a shell that has drawn is well above zero.
function Get-Lit {
    $ppm = Join-Path $env:TEMP "ruya-vm-goto.ppm"
    Remove-Item $ppm -ErrorAction SilentlyContinue
    [void](Send-VmMonitor -Port $Port -Command ("screendump " + ($ppm -replace '\\', '/')))
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path $ppm) -or (Get-Item $ppm).Length -lt 100) {
        if ((Get-Date) -gt $deadline) { throw "vm-goto: QEMU did not write a screendump" }
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 300
    $bytes = [System.IO.File]::ReadAllBytes($ppm)
    Remove-Item $ppm -ErrorAction SilentlyContinue
    $lit = 0; $n = 0
    for ($i = 20; $i -lt $bytes.Length; $i += 97) { $n++; if ($bytes[$i] -gt 24) { $lit++ } }
    return $lit / $n
}

function Send-Keys {
    param([string[]]$Keys, [string]$Text)
    $keyScript = Join-Path $PSScriptRoot "vm-keys.ps1"
    if ($Text) {
        & $keyScript -Text $Text -DelayMs 400 -Port $Port | Out-Null
        Start-Sleep -Milliseconds $SettleMs
    }
    foreach ($k in $Keys) {
        & $keyScript $k -DelayMs 400 -Port $Port | Out-Null
        Start-Sleep -Milliseconds $SettleMs
    }
}

# Fails within seconds when the VM is not there.
try { [void](Send-VmMonitor -Port $Port -Command "info status" -TimeoutSec 5) }
catch { throw "vm-goto: no VM on the QEMU monitor 127.0.0.1:${Port}. Start it with .\scripts\smoke-test.ps1 -Work -Keep. ($_)" }
if (-not (Test-Path $Key)) { throw "vm-goto: SSH key $Key not found" }

$count = Get-ProfileCount
if ($count -eq 0) {
    Write-Host "vm-goto: no profile yet, running the wizard"
    Wait-Until "wizard shown" { (Get-Lit) -gt 0.02 }
    Start-Sleep -Milliseconds $SettleMs
    Send-Keys -Keys @("ret")                                  # welcome
    Send-Keys -Keys @("ret")                                  # language: English
    Send-Keys -Keys @("ret")                                  # network
    Send-Keys -Keys @("ret")                                  # name row: opens the keyboard
    Send-Keys -Text $AdminName -Keys @("ret")                 # type, accept
    Send-Keys -Keys @("ret")                                  # "Choose a PIN and finish"
    Send-Keys -Text $Pin -Keys @("kp_enter")
    Send-Keys -Text $Pin -Keys @("kp_enter")                  # confirm
    Wait-Until "create profile" { (Get-ProfileCount) -gt 0 }
    Start-Sleep -Milliseconds $SettleMs
    Send-Keys -Keys @("ret")                                  # "You're all set" -> picker
} else {
    Write-Host "vm-goto: $count profile(s) found, restarting the shell to start from the picker"
    [void](Invoke-Guest "busctl --system call $Svc $Path $Svc Lock")
    [void](Invoke-Guest "systemctl restart ruya-compositor@tty1")
    Start-Sleep -Seconds 5
    Wait-Until "shell restart" { (Get-Lit) -gt 0.02 }
    Start-Sleep -Milliseconds $SettleMs
}

# Picker -> PIN pad -> home.
Send-Keys -Keys @("ret")
Send-Keys -Text $Pin -Keys @("kp_enter")
Wait-Until "sign in" { (Get-ActiveProfile) -ne "" }
Start-Sleep -Milliseconds $SettleMs

Send-Keys -Keys $targets[$Target]
& (Join-Path $PSScriptRoot "vm-screenshot.ps1") $Target -Port $Port
