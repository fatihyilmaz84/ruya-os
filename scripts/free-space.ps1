# Gives the disk space of an image session back (owner rule, 2026-11-03): run it after every
# image build, whether the build passed or failed, once the VM checks are done.
#   .\scripts\free-space.ps1 [-Distro FedoraLinux-44] [-KeepWork]
# In WSL it removes untagged images, drill/registry tags (localhost:5000/*) and stopped
# containers, keeps localhost/ruyaos:dev and the base images, and trims the file system. Then it
# shuts WSL down and compacts its disk file on C: (it never shrinks by itself: 7 -> 29 GB in one
# failed build, 2026-11-03). output\qcow2\work.qcow2 is deleted unless -KeepWork.
# Refuses while an image build or a disk build is still running in WSL.
param(
    [string]$Distro = "FedoraLinux-44",
    [switch]$KeepWork
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot

function Show-Free([string]$when) {
    $drives = Get-PSDrive C, D | ForEach-Object { "{0}: {1:N1} GB free" -f $_.Name, ($_.Free / 1GB) }
    Write-Host "$when $($drives -join ', ')"
}

Show-Free "Before:"

# The WSL half is scripts/free-space-wsl.sh (exit 3 while a build runs).
wsl -d $Distro -u root --cd $Repo -- bash scripts/free-space-wsl.sh
if ($LASTEXITCODE -eq 3) { exit 1 }
if ($LASTEXITCODE -ne 0) { Write-Host "WSL cleanup failed (exit $LASTEXITCODE)"; exit 1 }

if (-not $KeepWork) {
    $workDisk = Join-Path $Repo "output\qcow2\work.qcow2"
    if (Test-Path $workDisk) { Remove-Item $workDisk -Force; Write-Host "  deleted output\qcow2\work.qcow2" }
}

wsl --shutdown
Start-Sleep -Seconds 5
wsl --manage $Distro --compact | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "wsl --manage --compact failed (exit $LASTEXITCODE)"; exit 1 }
$vhdx = Join-Path $env:LOCALAPPDATA "wsl\$Distro\ext4.vhdx"
if (Test-Path $vhdx) { Write-Host ("  WSL disk file: {0:N1} GB" -f ((Get-Item $vhdx).Length / 1GB)) }

Show-Free "After:"
