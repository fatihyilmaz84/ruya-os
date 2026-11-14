# QML lint (RUY-41): button hints and glyphs name actions or button positions, never letters.
#
# ADR-027 / 06-input 11.1: the hint bar and every ButtonGlyph name an action (accept, back, options, ...)
# and ButtonGlyph draws the active input's glyph for it (Glyphs.qml): a PlayStation pad gets its
# shapes, a keyboard its key caps. A letter ("A", "B", "Start", "LB") in a hint would draw an Xbox
# letter on every pad again. This check fails on:
#   - `button: "..."` or `buttons: [...]` (the letter keys before RUY-41);
#   - a hint `{ action: "<x>", text: ... }` or `actions: ["<x>", ...]` whose name is not an action;
#   - `position: "<x>"` that is not one of Input1's button positions.
# A line that needs a word that looks like these ends in `// glyph-ok: <reason>`.
#
#   .\scripts\lint-glyph-actions.ps1 [-QmlDir <dir>]     (default: shell\qml)
param([string]$QmlDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell\qml"))
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$actions = @('up', 'down', 'left', 'right', 'accept', 'back', 'options', 'view', 'guide', 'tabPrev', 'tabNext',
             'pagePrev', 'pageNext', 'done', 'dpad')
$positions = @('south', 'east', 'west', 'north', 'l1', 'r1', 'left_trigger', 'right_trigger', 'l3', 'r3',
               'dpad_up', 'dpad_down', 'dpad_left', 'dpad_right', 'select', 'start', 'guide', 'none')
$letterRe = [regex]'\bbuttons?\s*:\s*[\["]'
$hintRe = [regex]'\baction\s*:\s*"([^"]*)"'
$listRe = [regex]'\bactions\s*:\s*\[\s*("[^\]]*)\]'
$positionRe = [regex]'\bposition\s*:\s*"([^"]+)"'
$problems = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path $QmlDir)) { Write-Host "    no such folder: $QmlDir" -ForegroundColor Yellow; exit 1 }
foreach ($f in Get-ChildItem $QmlDir -Recurse -Filter *.qml) {
    $n = 0
    $rel = $f.FullName.Substring($QmlDir.Length).TrimStart('\', '/')
    foreach ($line in [IO.File]::ReadAllLines($f.FullName, $Utf8)) {
        $n++
        if ($line -match 'glyph-ok') { continue }
        if ($letterRe.IsMatch($line)) {
            $problems.Add("${rel}:${n}: a button letter in a hint or glyph; name the action (action: `"accept`") or the position (position: `"south`"), 06-input 11.1")
        }
        # A hint object (it has a verb) names one action.
        if ($line -match '\btext\s*:') {
            foreach ($m in $hintRe.Matches($line)) {
                if ($actions -cnotcontains $m.Groups[1].Value) {
                    $problems.Add("${rel}:${n}: '$($m.Groups[1].Value)' is not an action of 06-input 11.1 ($($actions -join ' '))")
                }
            }
        }
        foreach ($m in $listRe.Matches($line)) {
            foreach ($item in [regex]::Matches($m.Groups[1].Value, '"([^"]*)"')) {
                if ($actions -cnotcontains $item.Groups[1].Value) {
                    $problems.Add("${rel}:${n}: '$($item.Groups[1].Value)' is not an action of 06-input 11.1 ($($actions -join ' '))")
                }
            }
        }
        foreach ($m in $positionRe.Matches($line)) {
            if ($positions -cnotcontains $m.Groups[1].Value) {
                $problems.Add("${rel}:${n}: '$($m.Groups[1].Value)' is not a button position ($($positions -join ' '))")
            }
        }
    }
}
foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
if ($problems.Count -gt 0) { exit 1 }
Write-Host "    ok: hints and glyphs name actions and positions, no letters"
exit 0
