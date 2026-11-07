# QML lint: no `property <type> <name>` that redeclares a member of QQuickItem.
#
# Fedora's qmllint (CI, --max-warnings 0) reports `Property "state" already exists in base type
# "QQuickItem" [property-override]`; the Windows Qt 6.10 qmllint did not (BatteryChip.qml, 2026-11-07,
# red CI after T-223). This cheap text check catches the common names locally.
#
# A declaration in a file whose root is not an Item (a QtObject singleton) is legal in QML: add
# `// lint-ok: not an Item` on that line.
#
#   .\scripts\lint-qml-members.ps1 [-QmlDir <dir>]
param([string]$QmlDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell"))
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$names = 'state|states|data|children|resources|parent|enabled|visible|focus|clip|opacity|scale|rotation|x|y|z|width|height|antialiasing|smooth|transform|transformOrigin|layer|baseline|implicitWidth|implicitHeight|activeFocus|containmentMask|anchors|transitions|childrenRect|visibleChildren|objectName|activeFocusOnTab'
$re = [regex]('^\s*(?:readonly\s+|required\s+|default\s+)*property\s+(?:alias\s+)?(?:[A-Za-z0-9_.<>]+\s+)?(' + $names + ')\b')
$problems = New-Object System.Collections.Generic.List[string]
foreach ($sub in 'qml', 'tests') {
    $dir = Join-Path $QmlDir $sub
    if (-not (Test-Path $dir)) { continue }
    foreach ($f in Get-ChildItem $dir -Recurse -Filter *.qml) {
        $n = 0
        foreach ($line in [IO.File]::ReadAllLines($f.FullName, $Utf8)) {
            $n++
            if ($line -match 'lint-ok') { continue }
            $m = $re.Match($line)
            if ($m.Success) {
                $rel = $f.FullName.Substring($QmlDir.Length).TrimStart('\', '/')
                $problems.Add("${rel}:${n}: property '$($m.Groups[1].Value)' already exists in QQuickItem (rename it, or '// lint-ok: not an Item')")
            }
        }
    }
}
foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
if ($problems.Count -gt 0) { exit 1 }
Write-Host "    ok: no QML property shadows a QQuickItem member"
exit 0
