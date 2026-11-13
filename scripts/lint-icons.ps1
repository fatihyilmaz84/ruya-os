# Icon lint: the table in shell/qml/Icon.qml and shell/fonts/icons.txt list the same names with the
# same code points (T-157). icons.txt feeds scripts/subset-icons.sh; the table is what the shell
# draws, so a name missing from the font would draw an empty box.
#
# Used by dev.ps1 (shell, test) and by the CI workflow. Works on Windows PowerShell 5.1 and
# on pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
# The controller silhouettes (RUY-491) are checked three ways: every shell/art/pads/<model>.svg has a
# `pad_<model> <code point> ruya` line in icons.txt (and the other way round), and the list of models in
# shell/qml/DeviceIcons.qml (`padModels`) is exactly the folder's.
#
#   .\scripts\lint-icons.ps1 [-IconQml <file>] [-IconList <file>] [-PadsDir <dir>] [-DeviceIcons <file>]
param(
    [string]$IconQml = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/qml/Icon.qml"),
    [string]$IconList = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/fonts/icons.txt"),
    [string]$PadsDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/art/pads"),
    [string]$DeviceIcons = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/qml/DeviceIcons.qml")
)

$fromList = @{}
$ownGlyphs = @{}
foreach ($line in Get-Content -LiteralPath $IconList -Encoding UTF8) {
    # A line may end in the word "ruya": our own glyph, added by scripts/add-pad-glyphs.py (T-199).
    if ($line -match '^\s*([a-z0-9_]+)\s+([0-9a-fA-F]{4,6})(\s+ruya)?\s*$') {
        $fromList[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
        if ($Matches[3]) { $ownGlyphs[$Matches[1]] = $true }
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
# The silhouettes: the folder, the font's own glyphs and DeviceIcons.padModels list the same models.
if (Test-Path -LiteralPath $PadsDir) {
    $stems = @(Get-ChildItem -LiteralPath $PadsDir -Filter *.svg | ForEach-Object { $_.BaseName } | Sort-Object)
    $inModels = @()
    $inList = $false
    foreach ($line in Get-Content -LiteralPath $DeviceIcons -Encoding UTF8) {
        if ($line -match 'readonly property var padModels') { $inList = $true; continue }
        if ($inList -and $line -match '^\s*\]') { break }
        if ($inList -and $line -match '"([a-z0-9_]+)"') { $inModels += $Matches[1] }
    }
    $inModels = @($inModels | Sort-Object)
    foreach ($stem in $stems) {
        if (-not $ownGlyphs.ContainsKey("pad_$stem")) {
            Write-Host "    ${stem}.svg: no 'pad_$stem ... ruya' line in icons.txt"; $findings++
        }
        if ($inModels -notcontains $stem) {
            Write-Host "    ${stem}.svg: not in DeviceIcons.padModels"; $findings++
        }
    }
    foreach ($name in $ownGlyphs.Keys) {
        if (($name -notmatch '^pad_(.+)$') -or ($stems -notcontains $Matches[1])) {
            Write-Host "    ${name}: an own glyph in icons.txt without an SVG in shell/art/pads"; $findings++
        }
    }
    foreach ($model in $inModels) {
        if ($stems -notcontains $model) {
            Write-Host "    ${model}: in DeviceIcons.padModels without an SVG in shell/art/pads"; $findings++
        }
    }
    if ($stems.Count -eq 0 -or $inModels.Count -eq 0) {
        Write-Host "    found no models in $PadsDir or $DeviceIcons (format changed?)"; $findings++
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
