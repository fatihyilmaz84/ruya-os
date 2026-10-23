# Saves what the VM's screen shows as output\vm-shots\<name>.png, through QEMU's monitor
# (screendump, converted from PPM). The VM must run with the monitor port, which
# smoke-test.ps1 and run-vm.ps1 open on 127.0.0.1:4444. Wait for RUYA_BOOT_OK first: before the
# shell has drawn there is nothing to see.
#   .\scripts\vm-screenshot.ps1 wizard-welcome
param(
    [Parameter(Mandatory, Position = 0)][string]$Name,
    [int]$Port = 4444
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "vm-lib.ps1")

$Repo = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $Repo "output\vm-shots"
New-Item -ItemType Directory -Force $dir | Out-Null
$png = Join-Path $dir "$Name.png"
$ppm = Join-Path $env:TEMP "ruya-vm-$Name.ppm"
Remove-Item $ppm -ErrorAction SilentlyContinue

# QEMU wants forward slashes in the path.
[void](Send-VmMonitor -Port $Port -Command ("screendump " + ($ppm -replace '\\', '/')))
$deadline = (Get-Date).AddSeconds(10)
while (-not (Test-Path $ppm) -or (Get-Item $ppm).Length -lt 100) {
    if ((Get-Date) -gt $deadline) { throw "QEMU did not write $ppm" }
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 300                       # let QEMU finish writing
Convert-PpmToPng -Ppm $ppm -Png $png
Remove-Item $ppm -ErrorAction SilentlyContinue
Write-Host $png
