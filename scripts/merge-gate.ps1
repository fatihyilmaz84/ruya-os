# The lead's test gate after merging a builder branch into main (docs/LEAD.md 4b step 6), without
# re-running a full `dev.ps1 test` that already passed on the same code. Run it on main, after the
# merge and the `docs: T-nnn done` commit, BEFORE removing the builder's worktree:
#   .\scripts\merge-gate.ps1 -Worktree D:\dev\RuyaOS-worktrees\T-nnn
# The builder's `dev.ps1 test` wrote <worktree>\output\last-green-test.txt for its commit. When main's
# HEAD differs from that commit only in docs\*.md (main moved only in docs since the branch began),
# that run proves this code: only `dev.ps1 docs` runs, and the marker is copied to main's output\
# so push-main.ps1 can use it too. Otherwise (no marker, older than 24 h, code on main moved, or a
# fix committed after the green run) the full `dev.ps1 test` runs, as before. Exit 0 = green.
param([Parameter(Mandatory = $true)][string]$Worktree)

$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
$git = Join-Path $env:ProgramFiles "Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }
$dev = Join-Path $PSScriptRoot "dev.ps1"
. (Join-Path $PSScriptRoot "green-marker.ps1")

function Say([string]$Text) { Write-Host "merge-gate: $Text" }

if ("$(& $git rev-parse --abbrev-ref HEAD)".Trim() -ne "main") { Say "FAIL: not on main"; exit 1 }
if (& $git status --porcelain) { Say "FAIL: the working tree is not clean"; exit 1 }
$head = "$(& $git rev-parse HEAD)".Trim()

$proof = Read-GreenMarker -Marker (Join-Path $Worktree "output\last-green-test.txt") -Head $head -Git $git
Say "builder's run: $($proof.Why)"
if ($proof.Mode -and $proof.Commit) {
    & $git merge-base --is-ancestor $proof.Commit $head
    if ($LASTEXITCODE -ne 0) { $proof = $null; Say "its commit is not merged into main: the proof does not apply" }
}

if ($proof -and $proof.Mode) {
    if ($proof.Mode -eq "docs") {
        $docs = & $dev docs *>&1 | Out-String
        if ($docs -notmatch "ALL GREEN \(docs\)") {
            ($docs -split "`n") | Select-String -Pattern "FAIL" | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
            Say "RED: dev.ps1 docs"
            exit 1
        }
        Say "dev.ps1 docs ALL GREEN"
    }
    Copy-Item -LiteralPath (Join-Path $Worktree "output\last-green-test.txt") -Destination (Join-Path $Repo "output\last-green-test.txt") -Force
    Say "GREEN: the full test was skipped (the builder's green run covers this code)"
    exit 0
}

Say "running the full dev.ps1 test"
$test = & $dev test *>&1 | Out-String
$totals = ($test -split "`n") | Select-String -Pattern "Totals:" | Select-Object -Last 1
if ($totals) { Say "$($totals.Line.Trim())" }
if ($test -notmatch "ALL GREEN \(test\)") {
    ($test -split "`n") | Select-String -Pattern "FAIL" | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
    Say "RED: dev.ps1 test (revert the merge and the docs commit, reopen the task)"
    exit 1
}
Say "GREEN: dev.ps1 test ALL GREEN"
exit 0
