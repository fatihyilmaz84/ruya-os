# Token lint: components take durations and colours from Theme tokens (shell/CLAUDE.md).
# Flags, in shell/qml outside Theme.qml: a literal "duration: <non-zero number>", a quoted
# hex colour, Qt.rgba(...), a literal "font.pixelSize: <digit>" (use Theme.type*). A line opts out with a trailing "// token-ok: <reason>".
#
# Used by dev.ps1 (shell, test) and by the CI workflow. Works on Windows PowerShell 5.1 and
# on pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-tokens.ps1 [-QmlDir <dir>]     # default: shell/qml of this repo
param(
    [string]$QmlDir
)

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $QmlDir) { $QmlDir = Join-Path (Join-Path $Repo "shell") "qml" }
$QmlDir = (Resolve-Path $QmlDir).Path

$patterns = 'duration\s*:\s*\d*[1-9]', '["'']#[0-9a-fA-F]{3,8}["'']', 'Qt\.rgba\(', 'font\.pixelSize\s*:\s*\(?\s*\d'
$hits = @(Get-ChildItem $QmlDir -Recurse -Filter *.qml |
    Where-Object { $_.Name -ne "Theme.qml" } |
    Select-String -Pattern $patterns |
    Where-Object { $_.Line -notmatch 'token-ok:' })
foreach ($h in $hits) {
    $rel = $h.Path
    if ($rel.StartsWith($Repo)) { $rel = $rel.Substring($Repo.Length).TrimStart('\', '/') }
    Write-Host "    ${rel}:$($h.LineNumber): $($h.Line.Trim())" -ForegroundColor Yellow
}
# Weight rule (04 section 3.2): the innermost { } block that sizes text with Theme.typeHero,
# typeDisplay, typeTitle, typeHeadline or typeMicro needs a font.weight.
$weightHits = @()
foreach ($f in (Get-ChildItem $QmlDir -Recurse -Filter *.qml | Where-Object { $_.Name -ne "Theme.qml" })) {
    $text = [IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($text, 'font\.pixelSize\s*:[^\r\n;}]*Theme\.type(Hero|Display|Title|Headline|Micro)\b')) {
        $a = 0; $depth = 0
        for ($k = $m.Index - 1; $k -ge 0; $k--) {
            $c = $text[$k]
            if ($c -eq '}') { $depth++ } elseif ($c -eq '{') { if ($depth -eq 0) { $a = $k; break }; $depth-- }
        }
        $b = $text.Length; $depth = 0
        for ($k = $m.Index; $k -lt $text.Length; $k++) {
            $c = $text[$k]
            if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { if ($depth -eq 0) { $b = $k; break }; $depth-- }
        }
        $block = $text.Substring($a, $b - $a)
        $lineStart = $text.LastIndexOf("`n", $m.Index) + 1
        $lineEnd = $text.IndexOf("`n", $m.Index); if ($lineEnd -lt 0) { $lineEnd = $text.Length }
        if ($block -notmatch 'font\.weight\s*:' -and $text.Substring($lineStart, $lineEnd - $lineStart) -notmatch 'token-ok:') {
            $ln = ($text.Substring(0, $m.Index) -split "`n").Count
            $rel = $f.FullName
            if ($rel.StartsWith($Repo)) { $rel = $rel.Substring($Repo.Length).TrimStart('\', '/') }
            $weightHits += "${rel}:${ln}: Theme.type* step without font.weight"
        }
    }
}
foreach ($w in $weightHits) { Write-Host "    $w" -ForegroundColor Yellow }
if ($weightHits.Count -gt 0) { Write-Host "    Add font.weight: Theme.weightLight (Hero, Display) or Theme.weightDemiBold (Title, Headline, Micro)." }
if ($hits.Count -gt 0) {
    Write-Host "    Move these into Theme.qml tokens, or add '// token-ok: <reason>'."
}
if ($hits.Count -gt 0 -or $weightHits.Count -gt 0) {
    exit 1
}
exit 0
