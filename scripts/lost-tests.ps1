# Lists every test that exists at BASE but no longer at HEAD (a deleted or renamed test), so a
# review sees it without counting by hand (T-147 round 1 lost nine Home tests silently, lead-9).
# Qt Quick tests: `function test_*` in shell/tests/*.qml, keyed by file. Rust: the name of each
# function after a #[test] or #[tokio::test] line in services/**/*.rs, keyed by file.
# Replaces lost-tests.sh (RUY-592): that one started a `git show` per file per ref and could loop forever
# on `sig_send` in Git Bash. This one makes two `git grep` calls per ref (plus one merge-base), each under a
# timeout; a hang is reported and ends with exit 2.
# Usage: .\scripts\lost-tests.ps1 [BASE] [HEAD]   (default: the merge base with main, and HEAD)
# Exit 0: nothing lost. Exit 1: the lost tests are printed; a rename or a deliberate removal must
# then be named in the task's Outcome (root CLAUDE.md: no test is deleted to get green).
# Exit 2: a git call failed or timed out.
param(
    [string]$Base = "",
    [string]$Head = "HEAD",
    [int]$TimeoutSec = 120
)

$Repo = Split-Path -Parent $PSScriptRoot
$script:deadline = (Get-Date).AddSeconds($TimeoutSec)

# Runs git with the remaining time budget; returns @{ Code; Out }. Exit 2 on a timeout.
function Invoke-Git([string[]]$GitArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.WorkingDirectory = $Repo
    $psi.Arguments = (($GitArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $left = [int][Math]::Max(1000, ($script:deadline - (Get-Date)).TotalMilliseconds)
    if (-not $p.WaitForExit($left)) {
        try { $p.Kill() } catch {}
        Write-Host "lost-tests: git $($GitArgs -join ' ') did not finish within $TimeoutSec s (hang); no result"
        exit 2
    }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

function Get-Tests([string]$Ref) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $prefix = "$Ref`:"
    # Qt Quick: one line per `function test_x`, "ref:file:line:text".
    $r = Invoke-Git @("grep", "-I", "--no-color", "-n", "-E", "function test_[A-Za-z0-9_]+", $Ref, "--", "shell/tests/*.qml")
    if ($r.Code -gt 1) { Write-Host "lost-tests: git grep failed for ${Ref}: $($r.Err.Trim())"; exit 2 }
    foreach ($line in ($r.Out -split "`n")) {
        if (-not $line.StartsWith($prefix)) { continue }
        $rest = $line.Substring($prefix.Length)
        if ($rest -match '^(.+?\.qml):\d+:(.*)$') {
            $file = $Matches[1]
            foreach ($m in [regex]::Matches($Matches[2], 'function (test_[A-Za-z0-9_]+)')) { [void]$set.Add("${file}:$($m.Groups[1].Value)") }
        }
    }
    # Rust: the first `fn name` in the three lines after a #[test] / #[tokio::test] line.
    $r = Invoke-Git @("grep", "-I", "--no-color", "-n", "-A3", "-E", "#\[(tokio::)?test", $Ref, "--", "services/*.rs")
    if ($r.Code -gt 1) { Write-Host "lost-tests: git grep failed for ${Ref}: $($r.Err.Trim())"; exit 2 }
    $want = $false
    $curFile = ""
    foreach ($line in ($r.Out -split "`n")) {
        if ($line.StartsWith('--')) { $want = $false; continue }
        if (-not $line.StartsWith($prefix)) { continue }
        $rest = $line.TrimEnd("`r").Substring($prefix.Length)
        if ($rest -notmatch '^(.+?\.rs)([:-])\d+[:-](.*)$') { continue }
        $file = $Matches[1]; $isMatch = ($Matches[2] -eq ':'); $text = $Matches[3]
        if ($file -ne $curFile) { $want = $false; $curFile = $file }
        if ($isMatch -and $text -match '#\[(tokio::)?test') { $want = $true; continue }
        if ($want -and $text -match '\bfn ([A-Za-z0-9_]+)') {
            [void]$set.Add("${file}:$($Matches[1])"); $want = $false
        }
    }
    return $set
}

if (-not $Base) {
    $r = Invoke-Git @("merge-base", "main", $Head)
    if ($r.Code -ne 0) { Write-Host "lost-tests: no merge base of main and ${Head}: $($r.Err.Trim())"; exit 2 }
    $Base = $r.Out.Trim()
}

$before = Get-Tests $Base
$after = Get-Tests $Head
$lost = @($before | Where-Object { -not $after.Contains($_) } | Sort-Object -Unique)
if ($lost.Count -eq 0) {
    Write-Host "lost-tests: none ($Base..$Head)"
    exit 0
}
Write-Host "lost-tests: $($lost.Count) test(s) at $Base are gone at ${Head}:"
$lost | ForEach-Object { Write-Host "  $_" }
exit 1
