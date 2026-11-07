# Revert check (lead, 2026-11-07, retrospective): proves that a new test fails without the change it covers,
# without the mistakes seen in T-247 round 1 (a mutated source that was never rebuilt, so "still green" meant
# nothing) and T-198/T-202 (a mutation that was not restored):
#   1. replaces the text -Old (must occur exactly once) with -New in -File,
#   2. runs `dev.ps1 shell` (it rebuilds the changed file, then lints and runs the Qt Quick tests),
#   3. prints the tests that failed, and ALWAYS restores the file (and touches it so the next build recompiles),
#   4. runs `dev.ps1 build` again so the build directory matches the restored source.
# Exit code 0 = the mutation was caught (at least one test failed), 1 = nothing failed (the test cannot fail),
# 2 = the mutation could not be applied. Run it from the checkout (worktree) that holds the change.
#
#   .\scripts\revert-check.ps1 -File shell\src\usage\Usage.cpp -Old 'if (profile != activeProfile())' -New 'if (false)'
param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New
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
try {
    $mutated = $text.Substring(0, $at) + $New + $text.Substring($at + $Old.Length)
    [IO.File]::WriteAllText($Path, $mutated, (New-Object Text.UTF8Encoding($false)))
    Write-Host "== mutated ${File}; building and testing (dev.ps1 shell) =="
    $out = & (Join-Path $PSScriptRoot "dev.ps1") shell 2>&1 | Out-String
    $log = Join-Path $Repo "shell\build-win\ruya-qmltest.txt"
    $failed = @()
    if (Test-Path -LiteralPath $log) {
        $failed = Select-String -LiteralPath $log -Pattern '^FAIL!\s*:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
    }
    $buildBroke = ($out -match 'FAILED: cmake')
    if ($failed.Count -gt 0) {
        $caught = $true
        Write-Host "CAUGHT: $($failed.Count) failing test(s):"; $failed | ForEach-Object { Write-Host "    $_" }
    } elseif ($buildBroke) {
        Write-Host "the mutated source did not build: that proves nothing about the tests. Choose a mutation that compiles."
    } else {
        Write-Host "NOT CAUGHT: every test still passed with the change undone. The test cannot fail (or the file is not part of this build)."
    }
} finally {
    [IO.File]::WriteAllBytes($Path, $bytes)
    (Get-Item -LiteralPath $Path).LastWriteTime = Get-Date
    Write-Host "== restored ${File}; rebuilding =="
    & (Join-Path $PSScriptRoot "dev.ps1") build 2>&1 | Out-Null
}
if ($caught) { exit 0 } else { exit 1 }
