# Pushes main to origin only when the tree is clean, `dev.ps1 test` is ALL GREEN for this content
# and the secret scan passes (lead sessions, docs/LEAD.md step 7). A push chained after a red test
# reached origin on 2026-11-04; this script makes the order impossible to get wrong. Never forces.
#   .\scripts\push-main.ps1           # check, then push
#   .\scripts\push-main.ps1 -DryRun   # say what would be skipped, run, pushed; push nothing
#
# Re-use of an earlier green run: `dev.ps1 test` writes output\last-green-test.txt (commit, time)
# only when it ended ALL GREEN on a clean tree whose HEAD did not move during the run. The marker is
# accepted when it is younger than 24 hours, its commit exists, and `git diff` from that commit to
# HEAD is empty (same content: the full test is skipped) or touches only docs\*.md (only
# `dev.ps1 docs` runs, the group of every check that reads docs\). Anything else runs `dev.ps1 test`.
param([switch]$DryRun)

# Continue: every step checks its exit code; under Stop, PowerShell 5.1 turns git's normal stderr
# progress lines into a terminating error.
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
# Git for Windows: the `git` on PATH here can be devkitPro's MSYS2 build.
$git = Join-Path $env:ProgramFiles "Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }
$dev = Join-Path $PSScriptRoot "dev.ps1"
$marker = Join-Path $Repo "output\last-green-test.txt"
$maxAgeHours = 24

function Stop-Push([string]$Why) {
    Write-Host "NOT PUSHED: $Why" -ForegroundColor Red
    exit 1
}
function Say([string]$Text) { Write-Host "push-main: $Text" }

$branch = "$(& $git rev-parse --abbrev-ref HEAD)".Trim()
if ($branch -ne "main") {
    if ($DryRun) { Say "(dry run) on '$branch', not main: a real run stops here" } else { Stop-Push "not on main" }
}
if (& $git status --porcelain) { Stop-Push "the working tree is not clean" }
$head = "$(& $git rev-parse HEAD)".Trim()

# What the marker proves, if anything (green-marker.ps1): Mode "same", "docs" or $null, and Why.
. (Join-Path $PSScriptRoot "green-marker.ps1")
$proof = Read-GreenMarker -Marker $marker -Head $head -Git $git -MaxAgeHours $maxAgeHours
$mode = $proof.Mode
Say $proof.Why
if ($mode -eq "same") {
    Say "SKIPPED dev.ps1 test (all of it): this content already passed it"
} elseif ($mode -eq "docs") {
    Say "SKIPPED the Rust, build, shell lint and Qt Quick steps of dev.ps1 test; running dev.ps1 docs (every check that reads docs\)"
    $docs = & $dev docs *>&1 | Out-String
    if ($docs -notmatch "ALL GREEN \(docs\)") {
        ($docs -split "`n") | Select-String -Pattern "FAIL" | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        Stop-Push "dev.ps1 docs is not ALL GREEN"
    }
    Say "dev.ps1 docs: ALL GREEN"
} elseif ($DryRun) {
    Say "(dry run) would run the full dev.ps1 test (not run in a dry run)"
} else {
    Say "running the full dev.ps1 test"
    $test = & $dev test *>&1 | Out-String
    if ($test -notmatch "ALL GREEN \(test\)") {
        ($test -split "`n") | Select-String -Pattern "FAIL" | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        Stop-Push "dev.ps1 test is not ALL GREEN"
    }
}

& (Join-Path $PSScriptRoot "scan-secrets.ps1")
if ($LASTEXITCODE -ne 0) { Stop-Push "scan-secrets.ps1 failed" }

if ($DryRun) {
    Say "(dry run) would push $(& $git log --oneline -1 $head) as main to origin; pushed nothing"
    exit 0
}
& $git push origin main
if ($LASTEXITCODE -ne 0) { Stop-Push "git push was rejected (someone else pushed, or history diverged): don't force; tell the owner" }
Write-Host "pushed: $(& $git log --oneline -1 origin/main)" -ForegroundColor Green
# What dev.ps1 test cannot see (red CI on 2026-11-07: clippy 1.92 casts, Fedora qmllint property-override).
Write-Host "CI is NOT verified here: it runs Rust 1.92 clippy on Linux and Fedora's Qt (qmllint --max-warnings 0, the .qsb shaders). Watch it: gh run list -L 3, then gh run watch <id> (gh is signed in on this host since 2026-11-10)." -ForegroundColor Yellow
