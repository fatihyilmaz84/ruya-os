# Spec lint (lead, 2026-11-07): every QML file under shell/qml is named in docs/specs/04-design-system.md
# ("A new component gets a row here before it is built", 04 section 5 and section 8), or is on the baseline
# scripts/lint-spec-components.baseline.txt (the files that already lacked a mention when this lint was
# added). The design reviewer blocked three branches for a missing row (ModePicker, ModeConfirm, ScreenSaver):
# a script finds that for free.
#
# A page, a non-visual helper or an internal piece may go on the baseline, one file name per line with a
# short reason after a #, but a visible reusable component needs its row in 04 instead.
#
#   .\scripts\lint-spec-components.ps1 [-WriteBaseline]
# Exit code 0 = clean, 1 = findings. Works on Windows PowerShell 5.1 and pwsh (Linux); used by dev.ps1 (test) and CI.
param(
    [string]$QmlDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/qml"),
    [string]$Spec = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs/specs/04-design-system.md"),
    [string]$Baseline = (Join-Path $PSScriptRoot "lint-spec-components.baseline.txt"),
    [switch]$WriteBaseline
)

$specText = [IO.File]::ReadAllText($Spec, [Text.Encoding]::UTF8)
$files = Get-ChildItem -LiteralPath $QmlDir -Recurse -Filter *.qml | Where-Object { $_.FullName -notmatch '[\\/]themes[\\/]' }

$unlisted = @()
foreach ($f in $files) {
    $name = $f.BaseName
    if ($specText -notmatch ('(?<![A-Za-z0-9_])' + [regex]::Escape($name) + '(?![A-Za-z0-9_])')) {
        $unlisted += $f.Name
    }
}
$unlisted = $unlisted | Sort-Object -Unique

if ($WriteBaseline) {
    $lines = @("# Files under shell/qml that 04-design-system.md did not mention when lint-spec-components.ps1 was added (2026-11-07).",
               "# Do not add to this list to get a new component through: give it a row in 04 section 5.") + $unlisted
    [IO.File]::WriteAllLines($Baseline, $lines, (New-Object Text.UTF8Encoding($false)))
    Write-Host "wrote $($unlisted.Count) baseline entries to $Baseline"
    exit 0
}

$known = @{}
if (Test-Path -LiteralPath $Baseline) {
    foreach ($line in Get-Content -LiteralPath $Baseline -Encoding UTF8) {
        $t = ($line -replace '#.*$', '').Trim()
        if ($t.Length -gt 0) { $known[$t] = $true }
    }
}

$findings = 0
foreach ($n in $unlisted) {
    if (-not $known.ContainsKey($n)) {
        Write-Host "    ${n}: not named in docs/specs/04-design-system.md (add a row to section 5, 04 section 8) and not on the baseline"
        $findings++
    }
}
if ($findings -gt 0) { exit 1 }
exit 0
