# Translation lint: every .ts file in shell/i18n is complete (no type="unfinished" entries), so a
# shipped language never falls back to English for a string it should have (shell/CLAUDE.md,
# "Translations"). Refresh the files with the update_translations target, translate the new
# entries, then re-run this.
#
# With -LUpdateProject (dev.ps1 passes the build's lupdate project), the .ts files are first
# refreshed from the current sources into temporary copies, so a new or changed qsTr string whose
# .ts files were never refreshed fails too, as do entries left "vanished"/"obsolete" (lead review
# after T-109). The tracked files are not touched. Without it (CI's lint job has no build) only
# the committed files are checked.
#
# Used by dev.ps1 (shell, test) and by the CI workflow. Works on Windows PowerShell 5.1 and on
# pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
# RUY-1165: a pad button's name is the word printed on the pad, the same in every language
# (04 section 6). The names below must keep their source as the translation in the contexts that
# name a button; Nintendo's + and - are symbols read as words and stay translated.
#
# -SelfCheck plants a translated name in a temporary file and expects the lint to reject it.
#
#   .\scripts\lint-translations.ps1 [-I18nDir <dir>] [-LUpdateProject <lupdate_project.json>] [-SelfCheck]
param(
    [string]$I18nDir,
    [string]$LUpdateProject,
    [switch]$SelfCheck
)

# The printed pad names, once, and the contexts whose entries for them are button names.
$PrintedPadNames = @("Create", "Menu", "View", "Options")
$PadNameContexts = @("Glyphs", "ButtonTestPage", "GameControls", "PadDiagram")

# Findings (strings) for every translated printed pad name under $Dir.
function Get-PadNameFindings([string]$Dir) {
    foreach ($f in Get-ChildItem $Dir -Filter *.ts) {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($f.FullName)
        foreach ($ctx in $doc.TS.context) {
            if ($PadNameContexts -notcontains $ctx.name) { continue }
            foreach ($m in $ctx.message) {
                if ($PrintedPadNames -notcontains $m.source) { continue }
                $t = if ($m.translation -is [string]) { $m.translation } else { $m.translation.InnerText }
                if ($t -and $t -ne $m.source) {
                    "$($f.Name) $($ctx.name): pad button name '$($m.source)' is translated as '$t' (it stays as printed)"
                }
            }
        }
    }
}

if ($SelfCheck) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ruya-padnames-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $ts = '<?xml version="1.0" encoding="utf-8"?><TS version="2.1" language="tr_TR"><context><name>PadDiagram</name><message><source>Options</source><translation>{0}</translation></message><message><source>Home</source><translation>Ana ekran</translation></message></context></TS>'
    Set-Content -Path (Join-Path $tmp "a.ts") -Value ($ts -f "Se&#231;enekler") -Encoding UTF8
    $planted = @(Get-PadNameFindings $tmp).Count
    Set-Content -Path (Join-Path $tmp "a.ts") -Value ($ts -f "Options") -Encoding UTF8
    $clean = @(Get-PadNameFindings $tmp).Count
    Remove-Item -Recurse -Force $tmp
    if ($planted -eq 1 -and $clean -eq 0) { exit 0 }
    Write-Host "    pad-name self-check failed (planted $planted findings, clean $clean)" -ForegroundColor Red
    exit 1
}

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $I18nDir) { $I18nDir = Join-Path (Join-Path $Repo "shell") "i18n" }
$I18nDir = (Resolve-Path $I18nDir).Path
$CheckDir = $I18nDir
$Pattern = 'type="unfinished"'

if ($LUpdateProject) {
    if (-not (Test-Path $LUpdateProject)) {
        Write-Host "    lupdate project not found: $LUpdateProject (build the shell first)" -ForegroundColor Red
        exit 1
    }
    $CheckDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ruya-i18n-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $CheckDir | Out-Null
    Copy-Item (Join-Path $I18nDir "*.ts") $CheckDir
    $copies = @(Get-ChildItem $CheckDir -Filter *.ts | ForEach-Object { $_.FullName })
    # lupdate prints progress (and harmless parser noise) on stderr; only its exit code matters.
    $out = & lupdate -project $LUpdateProject -ts $copies -locations none 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "    $_" }
        Write-Host "    lupdate failed" -ForegroundColor Red
        Remove-Item -Recurse -Force $CheckDir
        exit 1
    }
    $Pattern = 'type="(unfinished|vanished|obsolete)"'
}

$hits = @(Get-ChildItem $CheckDir -Filter *.ts | Select-String -Pattern $Pattern)
foreach ($h in $hits) {
    $what = if ($h.Line -match 'unfinished') { "unfinished translation" } else { "vanished/obsolete entry (delete it)" }
    $source = ""
    if ($h.LineNumber -ge 2) {
        $prev = (Get-Content $h.Path)[$h.LineNumber - 2]
        if ($prev -match '<source>(.*)</source>') { $source = " `"$($Matches[1])`"" }
    }
    Write-Host "    $($h.Filename)$source : $what" -ForegroundColor Yellow
}
$padFindings = @(Get-PadNameFindings $CheckDir)
foreach ($p in $padFindings) { Write-Host "    $p" -ForegroundColor Yellow }
if ($CheckDir -ne $I18nDir) { Remove-Item -Recurse -Force $CheckDir }
if ($padFindings.Count -gt 0) {
    Write-Host "    Set the translation of a printed pad button name equal to its source (04 section 6)."
    exit 1
}
if ($hits.Count -gt 0) {
    if ($LUpdateProject) {
        Write-Host "    Refresh the .ts files: cmake --build shell\build-win --config Release --target update_translations"
    }
    Write-Host "    Translate the entries above (a source string that stays English still needs its own copy as the translation)."
    exit 1
}
exit 0
