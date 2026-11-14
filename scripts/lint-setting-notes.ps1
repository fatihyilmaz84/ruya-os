# Settings note lint (RUY-590): a note under a setting row in a Settings pane is a `SettingNote`
# (shell/qml/controls/SettingNote.qml, 04 section 5), never a raw `Text` that repeats its look.
# A raw `Text { ... }` block in qml\*Pane.qml that sets both `Theme.typeCaption` and `Text.Wrap` is
# that note written out again (one copy drifting to `textDim` broke the contrast rule once, 04 3.1).
# Notes with inline glyphs (a Row of Text without Text.Wrap) are not flagged.
#
#   .\scripts\lint-setting-notes.ps1 [-QmlDir <dir>]
param([string]$QmlDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell\qml"))
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$problems = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem $QmlDir -Filter *Pane.qml) {
    $lines = [IO.File]::ReadAllLines($f.FullName, $Utf8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(\s*)Text \{\s*$') { continue }
        $indent = $Matches[1]
        $caption = $false; $wrap = $false
        for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -ne "$indent}"; $j++) {
            if ($lines[$j] -match 'Theme\.typeCaption') { $caption = $true }
            if ($lines[$j] -match 'Text\.Wrap') { $wrap = $true }
        }
        if ($caption -and $wrap) {
            $problems.Add("$($f.Name):$($i + 1): a raw Text note under a row; use SettingNote (shell/qml/controls/SettingNote.qml, 04 section 5)")
        }
    }
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
    exit 1
}
Write-Host "    setting notes: ok"
exit 0
