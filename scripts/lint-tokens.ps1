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
if ($hits.Count -gt 0) {
    Write-Host "    Move these into Theme.qml tokens, or add '// token-ok: <reason>'."
    exit 1
}
exit 0
