# Types keys into the VM through QEMU's monitor (sendkey); the guest sees a USB keyboard, so
# the shell receives the same keys a controller produces (shell/CLAUDE.md): arrows, ret (Accept),
# esc (Back), plus digits and letters. The VM must run with the monitor port (smoke-test.ps1,
# run-vm.ps1: 127.0.0.1:4444).
#   .\scripts\vm-keys.ps1 right right ret            # QEMU key names, one per argument
#   .\scripts\vm-keys.ps1 -Text "Owner"              # letters and digits; capitals use shift
#   .\scripts\vm-keys.ps1 -Text 2468 ret
# -DelayMs is the pause after each key (the shell is software-rendered in the VM and focus
# moves are animated, so keys sent too fast get lost).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments)][string[]]$Keys,
    [string]$Text,
    [int]$DelayMs = 250,
    [int]$Port = 4444
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "vm-lib.ps1")

$sequence = @()
foreach ($k in $Keys) { if ($k) { $sequence += $k } }
if ($Text) {
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -cmatch '[A-Z]') { $sequence += "shift-" + $ch.ToString().ToLower() }
        elseif ($ch -match '[a-z0-9]') { $sequence += $ch.ToString() }
        elseif ($ch -eq ' ') { $sequence += "spc" }
        else { throw "vm-keys: no key mapping for '$ch'; send it by QEMU key name instead" }
    }
}
if ($sequence.Count -eq 0) { throw "no keys given" }

foreach ($key in $sequence) {
    [void](Send-VmMonitor -Port $Port -Command "sendkey $key")
    Start-Sleep -Milliseconds $DelayMs
}
Write-Host "sent: $($sequence -join ' ')"
