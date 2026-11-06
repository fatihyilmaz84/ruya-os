# Test member lint (T-189): qmllint over shell/tests/*.qml in the shell's module context.
#
# A QML test can read a member QML cannot see (a C++ constant that is not a Q_PROPERTY, a
# misspelled property): the read is `undefined`, `wait(undefined + 200)` waits nothing and the
# assertion after it passes for the wrong reason (T-184 `Storage.groupWindowMs`, T-167, T-176).
# qmllint knows every member of the singletons and of the `Shell` item, so it reports
# [missing-property] for such a read; this script fails on any qmllint warning in the tests.
# `--unqualified disable` only because qmllint cannot see the two context properties that
# tst_main.cpp installs (`windowGuard`, `shotsDir`); a misspelling of those fails at run time.
#
# qmllint can also go blind without a word: a local (`const`, `let`, `for (const ..)`) declared
# inside a function that is itself inside a test function (`function run() {}` or a block-bodied
# arrow function) silently switches off the member checks for the whole file (found in
# tst_storage.qml, where `Storage.groupWindowMs` was never reported). So a second run
# adds a canary read of a member that does not exist to a copy of every test and requires
# qmllint to report it in every file; a file where it does not is blind, and fails.
#
# When it fails: the test reads a member that does not exist for QML. Expose it in C++
# (Q_PROPERTY / Q_INVOKABLE) or fix the name; do not silence the finding. Type a test's
# `property Shell shell` so reads on it are checked; a `var` is not checked. For a blind
# file, lift the nested function with the local to a top-level function of the TestCase.
#
# Used by dev.ps1 (shell, test); CI runs the same two qmllint calls (ci.yml). Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-test-members.ps1 -RspFile <ruyashell.rsp> [-TestDir <dir>] [-Qmllint <exe>]
param(
    [Parameter(Mandatory = $true)][string]$RspFile,
    [string]$TestDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/tests"),
    [string]$Qmllint = "qmllint"
)

$canary = "ruyaCanaryNoSuchMember"
$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-members-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failed = $false
try {
    # The module context of the shell build: every option line of the response file, but not
    # its list of shell sources; then the files to check.
    $opts = @(Get-Content -LiteralPath $RspFile -Encoding UTF8 | Where-Object { $_ -notmatch '\.qml$' })
    $tests = @(Get-ChildItem -Path $TestDir -Filter *.qml)
    if ($tests.Count -eq 0) { Write-Host "    no test files in $TestDir"; $failed = $true }

    function Invoke-Lint([string[]]$Files, [string]$Name) {
        $rsp = Join-Path $tmp "$Name.rsp"
        [IO.File]::WriteAllLines($rsp, [string[]]($opts + $Files), $utf8)
        # --max-warnings 0: without it qmllint exits 0 even when it reports warnings.
        $out = & $Qmllint --max-warnings 0 --unqualified disable "@$rsp" 2>&1
        return @{ Code = $LASTEXITCODE; Lines = @($out | ForEach-Object { "$_" }) }
    }

    if (-not $failed) {
        # 1. The tests as they are.
        $real = Invoke-Lint @($tests | ForEach-Object { $_.FullName -replace '\\', '/' }) "tests"
        if ($real.Code -ne 0) {
            $real.Lines | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" }
            Write-Host "    A test reads something QML cannot see: it is 'undefined' at run time and the assertion proves nothing."
            Write-Host "    Expose the member (Q_PROPERTY / Q_INVOKABLE) or fix its name; type 'property Shell shell'. See shell/CLAUDE.md, Tests."
            $failed = $true
        }

        # 2. Canary: a read of a missing member, planted after the first `name:` line (the
        # TestCase's) of a copy of every test, must be reported in every one.
        $copyDir = Join-Path $tmp "canary"
        New-Item -ItemType Directory -Path $copyDir | Out-Null
        $copies = @()
        foreach ($t in $tests) {
            $lines = New-Object System.Collections.Generic.List[string]
            $planted = $false
            foreach ($line in (Get-Content -LiteralPath $t.FullName -Encoding UTF8)) {
                $lines.Add($line)
                if (-not $planted -and $line -match '^\s+name:\s*"') {
                    $lines.Add("        function ruya_canary() { return Storage.$canary }")
                    $planted = $true
                }
            }
            if (-not $planted) { Write-Host "    $($t.Name): no TestCase name: line to plant the canary after"; $failed = $true; continue }
            $copy = Join-Path $copyDir $t.Name
            [IO.File]::WriteAllLines($copy, [string[]]$lines, $utf8)
            $copies += ($copy -replace '\\', '/')
        }
        $probe = Invoke-Lint $copies "canary"
        foreach ($t in $tests) {
            $hit = $probe.Lines | Where-Object { $_ -like "*/$($t.Name):*" -and $_ -like "*$canary*" }
            if (-not $hit) {
                Write-Host "    $($t.Name): qmllint does not check member reads in this file (a canary read of a missing member was not reported)."
                Write-Host "      Usual cause: a local (const, let, for-of) declared inside a nested function or block-bodied arrow; lift it to a top-level function of the TestCase."
                $failed = $true
            }
        }
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($failed) { exit 1 }
exit 0
