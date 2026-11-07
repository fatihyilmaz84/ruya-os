# Icon lint: the table in shell/qml/Icon.qml and shell/fonts/icons.txt list the same names with the
# same code points (T-157). icons.txt feeds scripts/subset-icons.sh; the table is what the shell
# draws, so a name missing from the font would draw an empty box.
#
# Used by dev.ps1 (shell, test) and by the CI workflow. Works on Windows PowerShell 5.1 and
# on pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-icons.ps1 [-IconQml <file>] [-IconList <file>]
param(
    [string]$IconQml = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/qml/Icon.qml"),
    [string]$IconList = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/fonts/icons.txt")
)

$fromList = @{}
foreach ($line in Get-Content -LiteralPath $IconList -Encoding UTF8) {
    # A line may end in the word "ruya": our own glyph, drawn by scripts/add-pad-glyphs.py (T-199).
    if ($line -match '^\s*([a-z0-9_]+)\s+([0-9a-fA-F]{4,6})(\s+ruya)?\s*$') {
        $fromList[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
    }
}

$fromQml = @{}
$inTable = $false
foreach ($line in Get-Content -LiteralPath $IconQml -Encoding UTF8) {
    if ($line -match 'readonly property var codePoints') { $inTable = $true; continue }
    if ($inTable -and $line -match '^\s*\}\)') { break }
    if ($inTable -and $line -match '"([a-z0-9_]+)"\s*:\s*0x([0-9a-fA-F]+)') {
        $fromQml[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
    }
}

$findings = 0
foreach ($name in ($fromList.Keys + $fromQml.Keys | Sort-Object -Unique)) {
    if (-not $fromList.ContainsKey($name)) {
        Write-Host "    ${name}: in Icon.qml but not in icons.txt (the font has no glyph for it)"; $findings++
    } elseif (-not $fromQml.ContainsKey($name)) {
        Write-Host "    ${name}: in icons.txt but not in the Icon.qml table"; $findings++
    } elseif ($fromList[$name] -ne $fromQml[$name]) {
        Write-Host ("    {0}: icons.txt says {1:x}, Icon.qml says {2:x}" -f $name, $fromList[$name], $fromQml[$name]); $findings++
    }
}
if ($fromList.Count -eq 0 -or $fromQml.Count -eq 0) {
    Write-Host "    found no icons in $IconList or $IconQml (format changed?)"; $findings++
}
if ($findings -gt 0) {
    Write-Host "    Keep shell/fonts/icons.txt and the table in Icon.qml in step, then run scripts/subset-icons.sh in WSL."
    exit 1
}
exit 0
