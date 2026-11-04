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
    $raw = [IO.File]::ReadAllText($f.FullName)
    # Comments become spaces (same offsets, newlines kept), so a commented-out font.weight can't count.
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $raw.Length
    while ($i -lt $n) {
        $c = $raw[$i]; $d = if ($i + 1 -lt $n) { $raw[$i + 1] } else { [char]0 }
        if ($c -eq '/' -and $d -eq '/') {
            while ($i -lt $n -and $raw[$i] -ne "`n" -and $raw[$i] -ne "`r") { [void]$sb.Append(' '); $i++ }
        } elseif ($c -eq '/' -and $d -eq '*') {
            while ($i -lt $n -and -not ($raw[$i] -eq '*' -and $i + 1 -lt $n -and $raw[$i + 1] -eq '/')) {
                [void]$sb.Append($(if ($raw[$i] -eq "`n" -or $raw[$i] -eq "`r") { $raw[$i] } else { ' ' })); $i++
            }
            if ($i -lt $n) { [void]$sb.Append('  '); $i += 2 }
        } elseif ($c -eq '"' -or $c -eq "'") {
            [void]$sb.Append($c); $i++
            while ($i -lt $n -and $raw[$i] -ne $c -and $raw[$i] -ne "`n") {
                if ($raw[$i] -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($raw[$i]); $i++ }
                [void]$sb.Append($raw[$i]); $i++
            }
            if ($i -lt $n) { [void]$sb.Append($raw[$i]); $i++ }
        } else { [void]$sb.Append($c); $i++ }
    }
    $text = $sb.ToString()
    # The value may continue on the next line (Theme.type* on line two is still checked).
    foreach ($m in [regex]::Matches($text, 'font\.pixelSize\s*:[^\r\n;}]*(?:\r?\n[^\r\n;}]*)?Theme\.type(Hero|Display|Title|Headline|Micro)\b')) {
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
        # Only this item's own properties count: drop nested { } child blocks, innermost first.
        $block = $text.Substring($a, $b - $a).Substring(1)
        do { $prev = $block; $block = [regex]::Replace($block, '\{[^{}]*\}', ' ') } while ($block -ne $prev)
        # token-ok is a comment, so look for it in the raw line (same offsets as $text).
        $lineStart = $raw.LastIndexOf("`n", $m.Index) + 1
        $lineEnd = $raw.IndexOf("`n", $m.Index); if ($lineEnd -lt 0) { $lineEnd = $raw.Length }
        if ($block -notmatch 'font\.weight\s*:' -and $raw.Substring($lineStart, $lineEnd - $lineStart) -notmatch 'token-ok:') {
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
