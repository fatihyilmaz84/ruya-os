# Owner clock for lead sessions (owner, 2026-11-17; LEAD.md "Autonomous after an hour").
#
#   .\scripts\lead-clock.ps1 -Seen   the owner just wrote: stamp the time
#   .\scripts\lead-clock.ps1         how long since the owner's last message
#
# Prints one line: "owner seen N min ago" plus " -> AUTONOMOUS" at 60 minutes or more, or
# "owner never stamped -> AUTONOMOUS" without a stamp. In autonomous mode the lead asks the owner
# nothing and works on to its handoff, because the prompt cache (1-hour TTL) has expired by then
# and every turn that waits on an answer pays for writing the whole context again.
# The stamp lives in output\ (git-ignored), one per checkout.
param(
    [switch]$Seen,
    [int]$Minutes = 60
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'output'
$file = Join-Path $dir 'lead-owner-seen.txt'

if ($Seen) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    Set-Content -Path $file -Value $now -Encoding ascii
    Write-Output "owner seen now ($now)"
    exit 0
}

if (-not (Test-Path $file)) {
    Write-Output 'owner never stamped -> AUTONOMOUS'
    exit 0
}
$text = (Get-Content -Path $file -TotalCount 1).Trim()
$stamp = [DateTime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind)
$ago = [int][Math]::Floor(((Get-Date).ToUniversalTime() - $stamp.ToUniversalTime()).TotalMinutes)
$line = "owner seen $ago min ago"
if ($ago -ge $Minutes) { $line += ' -> AUTONOMOUS' }
Write-Output $line
