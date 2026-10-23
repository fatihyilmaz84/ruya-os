# Translation lint: every .ts file in shell/i18n is complete (no type="unfinished" entries), so a
# shipped language never falls back to English for a string it should have (shell/CLAUDE.md,
# "Translations"). Refresh the files with the update_translations target, translate the new
# entries, then re-run this.
#
# Used by dev.ps1 (shell, test) and by the CI workflow. Works on Windows PowerShell 5.1 and on
# pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-translations.ps1 [-I18nDir <dir>]     # default: shell/i18n of this repo
param(
    [string]$I18nDir
)

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $I18nDir) { $I18nDir = Join-Path (Join-Path $Repo "shell") "i18n" }
$I18nDir = (Resolve-Path $I18nDir).Path

$hits = @(Get-ChildItem $I18nDir -Filter *.ts |
    Select-String -Pattern 'type="unfinished"')
foreach ($h in $hits) {
    $rel = $h.Path
    if ($rel.StartsWith($Repo)) { $rel = $rel.Substring($Repo.Length).TrimStart('\', '/') }
    Write-Host "    ${rel}:$($h.LineNumber): unfinished translation" -ForegroundColor Yellow
}
if ($hits.Count -gt 0) {
    Write-Host "    Translate the entries above (a source string that stays English still needs its own copy as the translation)."
    exit 1
}
exit 0
