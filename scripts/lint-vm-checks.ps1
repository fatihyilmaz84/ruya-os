# VM check lint (T-296): the lead-run VM checks (scripts\vm-*-check.sh, vm-*.ps1) are checked on the
# host as far as a host can:
#   - every scripts\vm-*.sh passes `bash -n` and is tracked with the exec bit (100755);
#   - every scripts\vm-*.ps1 parses;
#   - scripts\test-vm-checks.sh runs the parts that work on canned data (volume records by key, a
#     refusal is pkcheck exit 1, an error reply from ListVolumes is not an empty list, cleanup on an
#     early failure);
#   - vm-iso-check.ps1 refuses the development disks as -Disk (Windows only: the script is Windows-only).
# Used by dev.ps1 (test) and by the CI workflow. Works on Windows PowerShell 5.1 and on pwsh.
# Exit code 0 = fine, 1 = findings.
#
#   .\scripts\lint-vm-checks.ps1
$Repo = Split-Path -Parent $PSScriptRoot
$Scripts = Join-Path $Repo "scripts"
$problems = New-Object System.Collections.Generic.List[string]

function Find-Bash {
    foreach ($p in "$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") {
        if ($p -and (Test-Path $p)) { return $p }
    }
    # Not the WSL launcher in System32: it would run the script in another distribution.
    $c = Get-Command bash -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch 'System32|WindowsApps' } | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

# A native tool's complaint on stderr must not end the script (Windows PowerShell 5.1 turns it into an
# error record).
function Run-Native([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
        return @{ code = $LASTEXITCODE; out = ($out -join "`n") }
    } finally { $ErrorActionPreference = $old }
}

$bash = Find-Bash
if (-not $bash) { Write-Host "    bash was not found: the VM check scripts cannot be checked" -ForegroundColor Yellow; exit 1 }
$bashScripts = @(Get-ChildItem $Scripts -Filter "vm-*.sh") + @(Get-Item (Join-Path $Scripts "test-vm-checks.sh"))

# 1. syntax and exec bit
$modes = @{}
foreach ($line in @(git -C $Repo ls-files -s -- "scripts/vm-*.sh" "scripts/test-vm-checks.sh")) {
    if ($line -match '^(\d+) [0-9a-f]+ \d+\t(.+)$') { $modes[$Matches[2]] = $Matches[1] }
}
foreach ($f in $bashScripts) {
    $rel = "scripts/$($f.Name)"
    $r = Run-Native $bash @("-n", ($f.FullName -replace '\\', '/'))
    if ($r.code -ne 0) { $problems.Add("${rel}: fails bash -n: $(($r.out -split "`n" | Select-Object -First 1))") }
    if (-not $modes.ContainsKey($rel)) { $problems.Add("${rel}: not tracked by git (git add it, then the exec bit can be checked)") }
    elseif ($modes[$rel] -ne "100755") { $problems.Add("${rel}: mode $($modes[$rel]), want 100755 (git update-index --chmod=+x $rel)") }
}
# 1b. A check that passes without checking (lead-6 T-322, lead-7 T-376): the image has no jq, so a
# step that needs it must fail, not skip; parse JSON with python3 (PLANNING.md, Lessons).
foreach ($f in $bashScripts) {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        if ($l -match '^\s*#') { continue }
        if ($l -match '(^|[\s|;(&`$])jq(\s|$)') { $problems.Add("scripts/$($f.Name):${n}: uses jq, which the image does not have (parse with python3 -I -c)") }
    }
}
foreach ($f in Get-ChildItem $Scripts -Filter "vm-*.ps1") {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { $problems.Add("scripts/$($f.Name): does not parse: $($errors[0].Message)") }
}

# 2. the host tests on canned data
$r = Run-Native $bash @((Join-Path $Scripts "test-vm-checks.sh") -replace '\\', '/')
$r.out -split "`n" | ForEach-Object { Write-Host "    $_" }
if ($r.code -ne 0) { $problems.Add("scripts/test-vm-checks.sh failed (see above)") }

# 3. vm-iso-check.ps1 refuses the development disks (it erases its -Disk). The throw happens before
# anything else, so no QEMU is started; the control runs use a QemuDir that does not exist, so a disk
# that is NOT refused stops at "missing:" before it creates or deletes anything.
if ($PSVersionTable.PSEdition -eq "Desktop" -or $IsWindows) {
    $ps = (Get-Process -Id $PID).Path
    $iso = Join-Path $Scripts "vm-iso-check.ps1"
    $none = Join-Path ([IO.Path]::GetTempPath()) "ruya-no-qemu-here"
    $cases = @(
        @{ disk = "output\qcow2\disk.qcow2"; refused = $true },
        @{ disk = "output\qcow2\work.qcow2"; refused = $true },
        @{ disk = "OUTPUT\QCOW2\Disk.qcow2"; refused = $true },
        @{ disk = "output\x\..\qcow2\work.qcow2"; refused = $true },
        @{ disk = (Join-Path $Repo "output\qcow2\disk.qcow2"); refused = $true },
        @{ disk = "output\iso-test.qcow2"; refused = $false },
        @{ disk = "output\qcow2\drill.qcow2"; refused = $false }
    )
    foreach ($c in $cases) {
        $r = Run-Native $ps @("-NoProfile", "-File", $iso, "-Disk", $c.disk, "-QemuDir", $none)
        $r.out = $r.out -replace '\s+', ' '   # PowerShell wraps a long error message at the console width
        $refused = ($r.out -match "refusing -Disk") -and ($r.out -match "development disk")
        if ($c.refused -and -not ($refused -and $r.code -ne 0)) { $problems.Add("vm-iso-check.ps1 -Disk $($c.disk) was not refused (exit $($r.code)): $($r.out)") }
        if (-not $c.refused -and ($r.out -match "refusing" -or $r.out -notmatch "missing:")) { $problems.Add("vm-iso-check.ps1 -Disk $($c.disk) should reach the tool check, got: $($r.out)") }
    }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
    Write-Host "    VM check lint: $($problems.Count) finding(s)" -ForegroundColor Red
    exit 1
}
Write-Host "    VM check lint: ok ($($bashScripts.Count) shell scripts, VM check host tests, ISO check refusals)"
exit 0
