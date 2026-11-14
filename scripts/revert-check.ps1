# Revert check (lead, 2026-11-07, retrospective): proves that a new test fails without the change it covers,
# without the mistakes seen in T-247 round 1 (a mutated source that was never rebuilt, so "still green" meant
# nothing) and T-198/T-202 (a mutation that was not restored):
#   1. replaces the text -Old (must occur exactly once) with -New in -File,
#   2. runs `dev.ps1 shell` (it rebuilds the changed file, then lints and runs the Qt Quick tests),
#   3. prints the tests that failed, and ALWAYS restores the file (and touches it so the next build recompiles),
#   4. runs `dev.ps1 build` again so the build directory matches the restored source.
# Exit code 0 = the mutation was caught (at least one test failed), 1 = nothing failed (the test cannot fail),
# 2 = the mutation could not be applied (or a -Test name is not a test file). Run it from the checkout (worktree) that holds the change.
#
#   .\scripts\revert-check.ps1 -File shell\src\usage\Usage.cpp -Old 'if (profile != activeProfile())' -New 'if (false)'
# -Test tst_usage[,tst_x]: step 2 runs only those test files (`dev.ps1 qml`) instead of `dev.ps1 shell`,
# much faster; name the file that holds the new test, since nothing else runs.
# A -File under services\<crate>\ is Rust: step 2 is `cargo test -p <crate> -- <-Test name filters>`, e.g.
#   .\scripts\revert-check.ps1 -File services\ruya-session\src\spawner.rs -Old '...' -New '...' -Test scope_names
param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New,
    [string[]]$Test = @()
)

$Repo = Split-Path -Parent $PSScriptRoot
$Path = if ([IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $Repo $File }
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "no such file: $Path"; exit 2 }

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
$rust = [bool]$crate
try {
    $mutated = $text.Substring(0, $at) + $New + $text.Substring($at + $Old.Length)
    [IO.File]::WriteAllText($Path, $mutated, (New-Object Text.UTF8Encoding($false)))
    if ($rust) {
        Write-Host "== mutated ${File}; cargo test -p $crate $($Test -join ' ') =="
        Push-Location (Join-Path $Repo "services")
        try {
            # libtest takes several name filters (a test runs when its name contains any of them).
            $out = (& cargo test --locked -q -p $crate -- @Test 2>&1 | Out-String -Width 4096)
        } finally { Pop-Location }
        $logs = @()
    } elseif ($Test.Count -gt 0) {
        Write-Host "== mutated ${File}; building and testing only $($Test -join ', ') (dev.ps1 qml) =="
        # *>&1: dev.ps1 reports with Write-Host (the information stream), which 2>&1 does not capture.
        $out = & (Join-Path $PSScriptRoot "dev.ps1") qml @Test *>&1 | Out-String -Width 4096
        $logs = @(Get-ChildItem (Join-Path $Repo "shell\build-win") -Filter "ruya-qmltest-*.txt" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    } else {
        Write-Host "== mutated ${File}; building and testing (dev.ps1 shell) =="
        $out = & (Join-Path $PSScriptRoot "dev.ps1") shell *>&1 | Out-String -Width 4096
        $logs = @(Join-Path $Repo "shell\build-win\ruya-qmltest.txt")
    }
    $failed = @()
    foreach ($log in $logs) {
        if (Test-Path -LiteralPath $log) {
            $failed += @(Select-String -LiteralPath $log -Pattern '^FAIL!\s*:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        }
    }
    if ($rust) {
        # `cargo test -q` prints "<name> --- FAILED"; without -q it is "test <name> ... FAILED".
        $failed += @([regex]::Matches($out, '(?m)^\s*(?:test )?(\S+) (?:---|\.\.\.) FAILED') | ForEach-Object { $_.Groups[1].Value })
        $ran = [regex]::Matches($out, '(?m)^test result: \S+\. (\d+) passed; (\d+) failed') | ForEach-Object { [int]$_.Groups[1].Value + [int]$_.Groups[2].Value }
        if (-not $failed -and (($ran | Measure-Object -Sum).Sum -eq 0) -and $out -notmatch 'error(\[E\d+\])?:') {
            Write-Host "no test matched -Test $($Test -join ', ') in ${crate}: nothing was tested"; $badName = $true
        }
    }
    $failed = @($failed | Sort-Object -Unique)
    ($out -split "`n") | Where-Object { $_ -match 'FAIL|no such test file|PARTIAL|ok: cmake|could not compile' } | ForEach-Object { Write-Host "    $($_.TrimEnd())" }
    $buildBroke = ($out -match 'FAILED: cmake') -or ($rust -and $out -match 'could not compile')
    if (-not $rust) { $badName = ($out -match 'no such test file') }
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
    if ($rust) {
        Write-Host "== restored ${File} (cargo rebuilds it on the next run) =="
    } else {
        Write-Host "== restored ${File}; rebuilding =="
        & (Join-Path $PSScriptRoot "dev.ps1") build 2>&1 | Out-Null
    }
}
if ($badName) { exit 2 }
if ($caught) { exit 0 } else { exit 1 }
