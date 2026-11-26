# Revert check (lead, 2026-11-07, retrospective): proves that a new test fails without the change it covers,
# without the mistakes seen in T-247 round 1 (a mutated source that was never rebuilt, so "still green" meant
# nothing) and T-198/T-202 (a mutation that was not restored):
#   1. replaces the text -Old (must occur exactly once) with -New in -File,
#   2. runs `dev.ps1 shell` (it rebuilds the changed file, then lints and runs the Qt Quick tests),
#   3. prints the tests that failed, and ALWAYS restores the file (and touches it so the next build recompiles),
#   4. runs `dev.ps1 build` again so the build directory matches the restored source.
# A run that is killed (an outer `timeout`) cannot restore: step 1 first writes output\revert-check-pending.json
# (the file and its original bytes) and the next run of this script applies it before doing anything else (RUY-752).
# Exit code 0 = the mutation was caught (at least one test failed, or the child exited non-zero or died on a terminating
# error: "child aborted"), 1 = the child finished and nothing failed (the test cannot fail),
# 2 = the mutation could not be applied (or a -Test name is not a test file). Run it from the checkout (worktree) that holds the change.
#
#   .\scripts\revert-check.ps1 -File shell\src\usage\Usage.cpp -Old 'if (profile != activeProfile())' -New 'if (false)'
# -Test tst_usage[,tst_x]: step 2 runs only those test files (`dev.ps1 qml`) instead of `dev.ps1 shell`,
# much faster; name the file that holds the new test, since nothing else runs.
# -Mode docs: step 2 is `dev.ps1 docs` (text and dev-docs lints, api-changelog, script self-checks incl. the translation and bus-policy lints), for a mutation of
# a lint or a scripts\*.ps1 file; -Mode vmchecks: step 2 is `bash scripts/test-vm-checks.sh`, for a scripts\vm-*.sh
# mutation; -Mode vmlint: step 2 is `scripts\lint-vm-checks.ps1` alone (about 4 minutes), for a mutation of that lint
# or of vm-queue-lib.ps1. None of them builds or rebuilds anything; the verdict is the child's exit code (nonzero = CAUGHT).
#   .\scripts\revert-check.ps1 -Mode docs -File scripts\lint-dev-docs.ps1 -Old '<a rule>' -New '<nothing>'
#   .\scripts\revert-check.ps1 -Mode docs -File scripts\lint-translations.ps1 -Old '<a Get-PadNameFindings rule>' -New '<nothing>'
#   .\scripts\revert-check.ps1 -Mode docs -File scripts\lint-bus-policies.ps1 -Old '<a rule>' -New '<nothing>'
#   .\scripts\revert-check.ps1 -Mode vmlint -File scripts\vm-queue-lib.ps1 -Old '<a Get-VmNeedsProblems rule>' -New '<nothing>'
# A -File under services\<crate>\ is Rust: step 2 is `cargo test -p <crate> --all-features -- <-Test name filters>`
# (every feature, so code behind one, like ruya-platform's dev-mock, is tested too), e.g.
#   .\scripts\revert-check.ps1 -File services\ruya-session\src\spawner.rs -Old '...' -New '...' -Test scope_names
param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New,
    [string[]]$Test = @(),
    [ValidateSet("default", "docs", "vmchecks", "vmlint")][string]$Mode = "default",
    # Self-check only (dev.ps1): a script block that stands in for the build and test run and returns its
    # console text, with "FAIL!  : name" lines for failed tests. Nothing is rebuilt afterwards.
    [scriptblock]$Runner,
    [string]$LogDir   # self-check only: where the ruya-qmltest-<name>.txt logs live (default shell\build-win)
)
# The verdict is the exit code of this script (0 CAUGHT, 1 NOT CAUGHT, 2 unusable) and the CAUGHT / NOT CAUGHT
# line; both come from the test logs and the child's own exit code read inside this script, never from console
# text a caller's pipe (`| Select-Object -Last 3`) could cut (RUY-654).

$Repo = Split-Path -Parent $PSScriptRoot
# RUY-765: a relative -File is the caller's, so it resolves against the current location (never against this
# script's checkout: the main checkout's script run from a worktree once wrote an empty file into main). The
# file must exist (nothing is ever created) and belong to the checkout this script and its dev.ps1 build.
$here = (Get-Location -PSProvider FileSystem).ProviderPath
$Path = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $here $File }))

# RUY-752: the restore in the `finally` below cannot run when this process is killed (an outer `timeout`, a closed
# terminal), which left a mutation in the file. So the mutation is announced in a pending record first (the file's
# path and its original bytes, base64) and the record is deleted after the restore. The next run starts by applying
# a record it finds: a file that still differs from the saved bytes is restored, one that already equals them just
# loses the record. The record lives in the checkout's git-ignored output\ (every worktree has its own); a stand-in
# -Runner (self-checks) keeps it beside its fixture file, so a nested self-check never touches the record of the
# real run that is executing `dev.ps1 docs`.
$recordDir = if ($Runner) { Split-Path -Parent $Path } else { Join-Path $Repo "output" }
$recordPath = Join-Path $recordDir "revert-check-pending.json"
if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
    $left = $null
    try {
        $left = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
        $leftBytes = [Convert]::FromBase64String([string]$left.bytes)
        if (-not [string]$left.path) { throw "the record names no file" }
    } catch {
        Write-Host "dropping an unreadable $recordPath ($($_.Exception.Message))"
        $left = $null
    }
    if ($left) {
        $leftPath = [string]$left.path
        try {
            if (-not (Test-Path -LiteralPath $leftPath -PathType Leaf) -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($leftPath)) -ne [string]$left.bytes) {
                [IO.File]::WriteAllBytes($leftPath, $leftBytes)
                (Get-Item -LiteralPath $leftPath).LastWriteTime = Get-Date
                Write-Host "restored a mutation left by a killed revert-check run: $leftPath"
            }
        } catch {
            # The record stays, so the next start retries.
            Write-Host "could not restore ${leftPath}: $($_.Exception.Message)"; exit 2
        }
    }
    Remove-Item -LiteralPath $recordPath -Force
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Host "no such file: $Path"; exit 2 }
$owner = Split-Path -Parent $Path
while ($owner -and -not (Test-Path -LiteralPath (Join-Path $owner ".git"))) { $owner = Split-Path -Parent $owner }
if ($owner) {
    if ([IO.Path]::GetFullPath($owner).TrimEnd('\') -ne [IO.Path]::GetFullPath($Repo).TrimEnd('\')) {
        Write-Host "$Path is in the checkout $owner, but this script is ${Repo}'s: run $owner\scripts\revert-check.ps1"; exit 2
    }
} elseif (-not $Runner) { Write-Host "$Path is in no checkout"; exit 2 }

$bytes = [IO.File]::ReadAllBytes($Path)
$text = [Text.Encoding]::UTF8.GetString($bytes)
$at = $text.IndexOf($Old, [StringComparison]::Ordinal)
if ($at -lt 0) { Write-Host "-Old does not occur in ${File}"; exit 2 }
if ($text.IndexOf($Old, $at + 1, [StringComparison]::Ordinal) -ge 0) { Write-Host "-Old occurs more than once in ${File}: make it unique"; exit 2 }

$caught = $false
$badName = $false
# A file under services\<crate>\ is Rust (lead-18: three builders reported NOT CAUGHT for a Rust test that
# does fail, RUY-540, RUY-546, RUY-573): step 2 then runs `cargo test -p <crate>` (with -Test as name filters)
# and reads cargo's "test <name> ... FAILED" lines; nothing needs rebuilding afterwards.
$rel = [IO.Path]::GetFullPath($Path).Substring([IO.Path]::GetFullPath($Repo).TrimEnd('\').Length).TrimStart('\')
$crate = if ($rel -match '^services\\([^\\]+)\\') { $Matches[1] } else { $null }
$cmdMode = $Mode -ne "default"
# The modes whose step 2 is one command run from the checkout root (RUY-1216: vmlint joins vmchecks here, so a
# mode is one table row and not a second copy of the exit-code plumbing).
$repoCommands = @{
    vmchecks = @{ Label = "bash scripts/test-vm-checks.sh"; Run = { & bash scripts/test-vm-checks.sh } }
    vmlint   = @{ Label = "scripts\lint-vm-checks.ps1"; Run = { & (Join-Path $PSScriptRoot "lint-vm-checks.ps1") } }
}
$rust = [bool]$crate -and -not $cmdMode
# The record goes down before the first byte of the file changes.
New-Item -ItemType Directory -Path $recordDir -Force | Out-Null
[IO.File]::WriteAllText($recordPath, (@{ path = $Path; bytes = [Convert]::ToBase64String($bytes) } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
try {
    $mutated = $text.Substring(0, $at) + $New + $text.Substring($at + $Old.Length)
    [IO.File]::WriteAllText($Path, $mutated, (New-Object Text.UTF8Encoding($false)))
    $childExit = $null
    # Only the logs of the -Test names, and only ones this run wrote: the old ones are deleted first (a stale
    # failing log from an earlier run made a test that cannot fail look caught).
    if (-not $LogDir) { $LogDir = Join-Path $Repo "shell\build-win" }
    $qmlLogs = @($Test | ForEach-Object { Join-Path $LogDir ("ruya-qmltest-" + [IO.Path]::GetFileNameWithoutExtension($_) + ".txt") })
    if (-not $rust) { $qmlLogs | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue } }
    # RUY-1203: a child that dies on a terminating error (a `throw`, or an error under `$ErrorActionPreference =
    # 'Stop'` in dev.ps1: the RUY-994 case, Start-Process on a missing exe) does not return; the error would climb
    # out of this script past the verdict below (exit 1, no CAUGHT line, which reads as "not caught"). It is caught
    # here and becomes a failed run, with the error text in $out and the reason in $aborted.
    $aborted = $null
    $logs = @()
    try {
        if ($Runner) {
            Write-Host "== mutated ${File}; running the stand-in runner =="
            # A stand-in reports its own exit code by setting $global:LASTEXITCODE (like a child dev.ps1 would).
            $global:LASTEXITCODE = 0
            $out = (& $Runner *>&1 | Out-String -Width 4096)
            $childExit = $global:LASTEXITCODE
            $logs = $qmlLogs
            # A stand-in for docs / vmchecks mode reports failure the way dev.ps1 does ("FAILED: ...").
            if ($cmdMode) { $childExit = if ($out -match '(?m)^\s*FAILED:') { 1 } else { 0 } }
        } elseif ($Mode -eq "docs") {
            Write-Host "== mutated ${File}; dev.ps1 docs =="
            $out = & (Join-Path $PSScriptRoot "dev.ps1") docs *>&1 | Out-String -Width 4096
            $childExit = $LASTEXITCODE
            $logs = @()
        } elseif ($repoCommands.ContainsKey($Mode)) {
            Write-Host "== mutated ${File}; $($repoCommands[$Mode].Label) =="
            Push-Location $Repo
            try { $out = & $repoCommands[$Mode].Run *>&1 | Out-String -Width 4096; $childExit = $LASTEXITCODE } finally { Pop-Location }
            $logs = @()
        } elseif ($rust) {
            Write-Host "== mutated ${File}; cargo test -p $crate $($Test -join ' ') =="
            Push-Location (Join-Path $Repo "services")
            try {
                # libtest takes several name filters (a test runs when its name contains any of them).
                $out = (& cargo test --locked -q -p $crate --all-features -- @Test 2>&1 | Out-String -Width 4096)
            } finally { Pop-Location }
            $logs = @()
        } elseif ($Test.Count -gt 0) {
            Write-Host "== mutated ${File}; building and testing only $($Test -join ', ') (dev.ps1 qml) =="
            # *>&1: dev.ps1 reports with Write-Host (the information stream), which 2>&1 does not capture.
            $out = & (Join-Path $PSScriptRoot "dev.ps1") qml @Test *>&1 | Out-String -Width 4096
            $childExit = $LASTEXITCODE
            $logs = $qmlLogs
        } else {
            Write-Host "== mutated ${File}; building and testing (dev.ps1 shell) =="
            $out = & (Join-Path $PSScriptRoot "dev.ps1") shell *>&1 | Out-String -Width 4096
            $childExit = $LASTEXITCODE
            $logs = @(Join-Path $Repo "shell\build-win\ruya-qmltest.txt")
        }
    } catch {
        $aborted = ($_.Exception.Message -split "`r?`n")[0]
        $out = "$($_ | Out-String -Width 4096)"
        $childExit = 1
        Write-Host "child aborted: $aborted"
    }
    $failed = @()
    foreach ($log in $logs) {
        if (Test-Path -LiteralPath $log) {
            $failed += @(Select-String -LiteralPath $log -Pattern '^FAIL!\s*:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        }
    }
    if ($Runner) {
        $failed += @([regex]::Matches($out, '(?m)^FAIL!\s*:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
    }
    if ($rust) {
        # `cargo test -q` prints "<name> --- FAILED"; without -q it is "test <name> ... FAILED".
        $failed += @([regex]::Matches($out, '(?m)^\s*(?:test )?(\S+) (?:---|\.\.\.) FAILED') | ForEach-Object { $_.Groups[1].Value })
        $ran = [regex]::Matches($out, '(?m)^test result: \S+\. (\d+) passed; (\d+) failed') | ForEach-Object { [int]$_.Groups[1].Value + [int]$_.Groups[2].Value }
        if (-not $aborted -and -not $failed -and (($ran | Measure-Object -Sum).Sum -eq 0) -and $out -notmatch 'error(\[E\d+\])?:') {
            Write-Host "no test matched -Test $($Test -join ', ') in ${crate}: nothing was tested"; $badName = $true
        }
    }
    $failed = @($failed | Sort-Object -Unique)
    if ($cmdMode -and $childExit -ne 0) { $failed = @("($Mode mode: exit code $childExit)") }
    # The child dev.ps1 exits non-zero when anything failed, also a Record-style self-check that leaves no
    # test log line (RUY-659): a failure whose log line was lost is still a failure. A build break or a bad
    # -Test name is judged below, before the failures.
    if (-not $cmdMode -and -not $rust -and $failed.Count -eq 0 -and $null -ne $childExit -and $childExit -ne 0) { $failed = @("(dev.ps1 exit code $childExit)") }
    # The invariant (RUY-1203): a child that did not finish is a failure, whatever mode and whatever it printed; NOT
    # CAUGHT is only a child that ran to the end with every test passing. Also the Rust mode, which reads no exit code.
    if ($aborted) { $failed = @("child aborted: $aborted (exit code $childExit)") }
    ($out -split "`n") | Where-Object { $_ -match 'FAIL|no such test file|PARTIAL|ok: cmake|could not compile' } | ForEach-Object { Write-Host "    $($_.TrimEnd())" }
    # An aborted child is judged before these heuristics: its output is only the error text, which says nothing
    # about test names or builds.
    $buildBroke = (-not $cmdMode) -and -not $aborted -and (($out -match 'FAILED: cmake') -or ($rust -and $out -match 'could not compile'))
    if (-not $rust -and -not $cmdMode) { $badName = (-not $aborted) -and ($out -match 'no such test file') }
    if ($badName) {
        if (-not $rust) { Write-Host "a -Test name is not a file in shell\tests: nothing was tested" }
    } elseif ($buildBroke) {
        # Checked before the failures: `dev.ps1 shell` still runs the previous binary after a failed build.
        Write-Host "the mutated source did not build: that proves nothing about the tests. Choose a mutation that compiles."
    } elseif ($failed.Count -gt 0) {
        $caught = $true
        Write-Host "CAUGHT: $($failed.Count) failing test(s):"; $failed | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "NOT CAUGHT: every test still passed with the change undone. The test cannot fail (or the file is not part of this build)."
    }
} finally {
    [IO.File]::WriteAllBytes($Path, $bytes)
    (Get-Item -LiteralPath $Path).LastWriteTime = Get-Date
    Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
    if ($Runner) {
        Write-Host "== restored ${File} =="
    } elseif ($cmdMode) {
        Write-Host "== restored ${File} =="
    } elseif ($rust) {
        Write-Host "== restored ${File} (cargo rebuilds it on the next run) =="
    } else {
        Write-Host "== restored ${File}; rebuilding =="
        & (Join-Path $PSScriptRoot "dev.ps1") build 2>&1 | Out-Null
    }
}
if ($badName) { exit 2 }
if ($caught) { exit 0 } else { exit 1 }
