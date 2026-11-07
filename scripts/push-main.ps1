# Pushes main to origin only when the tree is clean, `dev.ps1 test` ends ALL GREEN and the secret
# scan passes (lead sessions, docs/LEAD.md step 7). A push chained after a red test reached origin
# on 2026-11-04; this script makes the order impossible to get wrong. Never forces.
#   .\scripts\push-main.ps1
# Continue: every step checks its exit code; under Stop, PowerShell 5.1 turns git's normal stderr
# progress lines into a terminating error.
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
# Git for Windows: the `git` on PATH here can be devkitPro's MSYS2 build.
$git = Join-Path $env:ProgramFiles "Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }

function Stop-Push([string]$Why) {
    Write-Host "NOT PUSHED: $Why" -ForegroundColor Red
    exit 1
}

if ((& $git rev-parse --abbrev-ref HEAD) -ne "main") { Stop-Push "not on main" }
if (& $git status --porcelain) { Stop-Push "the working tree is not clean" }

$test = & (Join-Path $PSScriptRoot "dev.ps1") test *>&1 | Out-String
if ($test -notmatch "ALL GREEN \(test\)") {
    ($test -split "`n") | Select-String -Pattern "FAIL" | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
    Stop-Push "dev.ps1 test is not ALL GREEN"
}
& (Join-Path $PSScriptRoot "scan-secrets.ps1")
if ($LASTEXITCODE -ne 0) { Stop-Push "scan-secrets.ps1 failed" }

& $git push origin main
if ($LASTEXITCODE -ne 0) { Stop-Push "git push was rejected (someone else pushed, or history diverged): don't force; tell the owner" }
Write-Host "pushed: $(& $git log --oneline -1 origin/main)" -ForegroundColor Green
# What dev.ps1 test cannot see (red CI on 2026-11-07: clippy 1.92 casts, Fedora qmllint property-override).
Write-Host "CI is NOT verified here: it runs Rust 1.92 clippy on Linux and Fedora's Qt (qmllint --max-warnings 0, the .qsb shaders). Ask the owner for the Actions result; gh is not installed on this host." -ForegroundColor Yellow
