# Quick-switch lint (RUY-1217): `lint-vm-checks.ps1 -Quick` skips the minutes-long test-vm-checks.sh run. It is for the
# loop that edits the lint (revert-check.ps1 -Mode vmlint passes it), never for a gate: dev.ps1 (test, docs), CI and the
# git hooks run the full lint. The real guard is dev.ps1's Test-VmChecks, which fails when the lint it ran did not run
# test-vm-checks.sh (whatever the call looked like); this is the second guard, a scan of the places that run scripts
# (scripts\, .github\, .githooks\) that names the file the lint is called from.
#
# PowerShell takes any unambiguous prefix of a parameter (-Q, -Qu ...), and a call can use a variable
# (`& $lint -Quick`) or a splat (@{ Quick = $true }), so the scan is per file, not per line: a file that names
# lint-vm-checks.ps1 on a line that is not a comment may not have, on any line that is not a comment, a token that
# is a prefix of -Quick or a hashtable key `Q...=`. Exempt by exact path: the lint, revert-check.ps1 (the one caller)
# and this file (its fixtures).
# -SelfTest plants each call shape in a temporary tree and proves the scan finds it (and leaves the exempt files and
# a plain full call alone).
#
#   .\scripts\lint-quick-callers.ps1 [-SelfTest]
# Exit code 0 = fine, 1 = findings.
param([switch]$SelfTest, [string]$Root = "")
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = $Repo }
$lintName = "lint-vm-checks.ps1"
$exempt = @("scripts\lint-vm-checks.ps1", "scripts\revert-check.ps1", "scripts\lint-quick-callers.ps1")
# The prefixes of Quick PowerShell accepts: -Q, -Qu, -Qui, -Quic, -Quick (a bare lower-case -q is cargo's and grep's flag
# all over dev.ps1, so only the capital Q is taken for the one-letter prefix), and the same names as a hashtable key.
$quickToken = '(?-i)(^|[\s''",@;=])(-(?i:Qu(?:i(?:c(?:k)?)?)?)|-Q)\b|(?<![\$\w-])((?i:Qu(?:i(?:c(?:k)?)?)?)|Q)\s*=(?!=)'

function Find-QuickCallers([string]$root) {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($dir in "scripts", ".github", ".githooks") {
        $path = Join-Path $root $dir
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue) {
            if ($f.Length -gt 2MB -or $f.FullName -match '[\\/](target|build|build-win|node_modules|\.git)[\\/]') { continue }
            $rel = $f.FullName.Substring($root.TrimEnd('\').Length).TrimStart('\')
            if ($exempt -contains $rel) { continue }
            $lines = @([IO.File]::ReadAllLines($f.FullName) | Where-Object { $_ -notmatch '^\s*#' })
            if (-not ($lines | Where-Object { $_.Contains($lintName) })) { continue }
            $n = 0
            foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
                $n++
                if ($l -match '^\s*#') { continue }
                if ($l -match $quickToken) { $hits.Add(("{0}:{1}: {2}" -f $rel, $n, $l.Trim())) }
            }
        }
    }
    return $hits
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-quick-" + [guid]::NewGuid().ToString("N"))
    $ok = $true
    try {
        New-Item -ItemType Directory -Force (Join-Path $tmp "scripts"), (Join-Path $tmp ".github\workflows"), (Join-Path $tmp ".githooks") | Out-Null
        $w = { param($rel, $text) [IO.File]::WriteAllText((Join-Path $tmp $rel), $text) }
        # each shape must be found, one fixture file each
        $bad = [ordered]@{
            "scripts\full-name.ps1"         = "& (Join-Path `$PSScriptRoot `"$lintName`") -Quick`n"
            "scripts\prefix-q.ps1"          = "& (Join-Path `$PSScriptRoot `"$lintName`") -Q`n"
            "scripts\prefix-qui.ps1"        = "& .\scripts\$lintName -Qui`n"
            "scripts\variable.ps1"          = "`$lint = Join-Path `$PSScriptRoot `"$lintName`"`n& `$lint -Quick`n"
            "scripts\splat.ps1"             = "`$lint = `"$lintName`"`n`$a = @{ Quick = `$true }`n& `$lint @a`n"
            "scripts\splat-prefix.ps1"      = "`$lint = `"$lintName`"`n`$a = @{ Q = `$true }`n& `$lint @a`n"
            "scripts\array-arg.ps1"         = "`$lint = `"$lintName`"`n& `$lint @(`"-Quick`")`n"
            ".github\workflows\ci.yml"      = "      - run: pwsh -NoProfile -File scripts/$lintName -Quick`n"
            ".githooks\pre-commit"          = "pwsh -NoProfile -File scripts/$lintName -Qu`n"
        }
        foreach ($k in $bad.Keys) { & $w $k $bad[$k] }
        # these must not be found
        & $w "scripts\revert-check.ps1" "Run = { & (Join-Path `$PSScriptRoot `"$lintName`") -Quick }`n"
        & $w "scripts\lint-vm-checks.ps1" "param([switch]`$Quick)`n"
        & $w "scripts\lint-quick-callers.ps1" "& `$lint -Quick # $lintName`n"
        & $w "scripts\full-call.ps1" "& (Join-Path `$PSScriptRoot `"$lintName`")`n# -Quick is for the revert loop: $lintName -Quick`n"
        & $w "scripts\other-q-switch.sh" "grep -q x file`n"
        & $w "scripts\mentions-only.ps1" "`$q = 1`n# $lintName`n"
        $found = @(Find-QuickCallers $tmp | ForEach-Object { ($_ -split ':')[0] } | Sort-Object -Unique)
        $want = @($bad.Keys | Sort-Object)
        if (($found -join "|") -ne ($want -join "|")) {
            $ok = $false
            Write-Host "    lint-quick-callers self-test: found '$($found -join ' ')', want '$($want -join ' ')'" -ForegroundColor Yellow
        }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    if ($ok) { Write-Host "    lint-quick-callers self-test: ok (each way to pass the switch is found; the exempt files and a full call are not)"; exit 0 }
    exit 1
}

$hits = @(Find-QuickCallers $Root)
if ($hits.Count -gt 0) {
    Write-Host "    -Quick of $lintName is for revert-check.ps1 alone (the gates run the full lint):" -ForegroundColor Yellow
    foreach ($h in $hits) { Write-Host "    $h" -ForegroundColor Yellow }
    exit 1
}
Write-Host "    lint-quick-callers: ok (only revert-check.ps1 passes -Quick to $lintName)"
exit 0
