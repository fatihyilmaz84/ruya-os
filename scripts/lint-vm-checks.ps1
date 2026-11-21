# VM check lint (T-296): the lead-run VM checks (scripts\vm-*-check.sh, vm-*.ps1) are checked on the
# host as far as a host can:
#   - every scripts\vm-*.sh passes `bash -n` and is tracked with the exec bit (100755);
#   - every scripts\vm-*.ps1 parses;
#   - scripts\test-vm-checks.sh runs the parts that work on canned data (volume records by key, a
#     refusal is pkcheck exit 1, an error reply from ListVolumes is not an empty list, cleanup on an
#     early failure);
#   - vm-iso-check.ps1 refuses the development disks as -Disk (Windows only: the script is Windows-only).
# Used by dev.ps1 (test) and by the CI workflow. Works on Windows PowerShell 5.1 and on pwsh.
#   - every scripts\vm-*.sh has the `# modes:` line vm-queue.ps1 reads, and it lists exactly the modes the
#     script dispatches (RUY-860); the queue's skip rules (a mode not listed, the .play files missing) are
#     tested on temporary folders.
# Exit code 0 = fine, 1 = findings.
#
#   .\scripts\lint-vm-checks.ps1
$Repo = Split-Path -Parent $PSScriptRoot
$Scripts = Join-Path $Repo "scripts"
$problems = New-Object System.Collections.Generic.List[string]
. (Join-Path $Scripts "vm-queue-lib.ps1")

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
$bashScripts = @(Get-ChildItem $Scripts -Filter "vm-*.sh") + @(Get-Item (Join-Path $Scripts "test-vm-checks.sh"), (Join-Path $Scripts "play-vm-files.sh"), (Join-Path $Scripts "lib-samples.sh"))

# 1. syntax and exec bit
$modes = @{}
foreach ($line in @(git -C $Repo ls-files -s -- "scripts/vm-*.sh" "scripts/test-vm-checks.sh" "scripts/play-vm-files.sh" "scripts/lib-samples.sh")) {
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

# 1c. The modes line (RUY-860): the queue reads it, so it must say what the script dispatches.
foreach ($f in Get-ChildItem $Scripts -Filter "vm-*.sh") {
    $listed = Get-VmModes $f.FullName
    if ($null -eq $listed) { $problems.Add("scripts/$($f.Name): no '# modes: <mode> ...' line ('# modes: none' when it takes no mode)"); continue }
    $dispatch = Get-VmDispatchedModes $f.FullName
    foreach ($u in $dispatch.unreadable) {
        $problems.Add("scripts/$($f.Name): cannot read the mode dispatch ($u); use mode=`"`${1:-...}`" + case `"`$mode`" (see Get-VmDispatchedModes), or '# modes: none' and no `$1`/`$@`/`$*` outside functions")
    }
    $dispatched = @($dispatch.modes)
    $missing = @($dispatched | Where-Object { $_ -notin $listed })
    $extra = @($listed | Where-Object { $_ -notin $dispatched })
    if ($missing) { $problems.Add("scripts/$($f.Name): dispatches but does not list in '# modes:': $($missing -join ' ')") }
    if ($extra) { $problems.Add("scripts/$($f.Name): lists in '# modes:' but does not dispatch: $($extra -join ' ')") }
}

# 1d. The queue's skip rules on a temporary tree: a mode not listed, no modes line, a missing script,
# the .play checks without the package and ruya-pack (and with them).
$qt = Join-Path ([IO.Path]::GetTempPath()) ("ruya-queue-lint-" + [guid]::NewGuid().ToString("N"))
try {
    $qs = Join-Path $qt "scripts"
    New-Item -ItemType Directory -Force $qs | Out-Null
    [IO.File]::WriteAllText((Join-Path $qs "vm-a-check.sh"), "#!/usr/bin/env bash`n# modes: check other`n")
    [IO.File]::WriteAllText((Join-Path $qs "vm-b-check.sh"), "#!/usr/bin/env bash`n")
    [IO.File]::WriteAllText((Join-Path $qs "vm-play-check.sh"), "#!/usr/bin/env bash`n# modes: check helper verify perms remove launch launch-windows parse`n")
    [IO.File]::WriteAllText((Join-Path $qs "vm-library-check.sh"), "#!/usr/bin/env bash`n# modes: check play`n")
    # The dispatch reader on one fixture per shape (RUY-890): the canonical forms are read, every other
    # top-level mention of $1 (or of a name assigned from it) fails, never counts as single-mode.
    # Lines are single-quoted PowerShell strings, so the shell text needs no escaping.
    $shapes = @(
        # PASS: the canonical forms, and function bodies
        @{ name = "canonical-assigned"; modes = "check extra"; unreadable = 0; lines = @('mode="${1:-check}"', 'case "$mode" in', '    check) ;;', '    extra) ;;', 'esac') },
        @{ name = "canonical-assigned-no-colon"; modes = "check extra"; unreadable = 0; lines = @('mode="${1-check}"', 'case "$mode" in', '    check) ;;', '    extra) ;;', 'esac') },
        @{ name = "canonical-case"; modes = "check other"; unreadable = 0; lines = @('case "${1:-check}" in', '    check) ;;', '    other) ;;', 'esac') },
        @{ name = "canonical-test"; modes = "check extra"; unreadable = 0; lines = @('if [ "${1:-check}" = extra ]; then :; fi') },
        @{ name = "canonical-assigned-test"; modes = "check extra"; unreadable = 0; lines = @('mode="${1:-check}"', 'if [ "$mode" == extra ]; then :; fi', 'run_it "$mode"', 'echo "the mode is $mode"') },
        @{ name = "function-bodies"; modes = ""; unreadable = 0; lines = @('f() { echo "$1" "$@"; }', 'g() {', '    local x="$1"', '    case "$x" in a) ;; esac', '    set -- "$@" more', '}', 'h() { for a in "$@"; do :; done', '}') },
        @{ name = "heredoc-and-python"; modes = ""; unreadable = 0; lines = @('f() {', '    python3 -c ''', 'print("$1")', ''' "$1"', '}', 'cat <<EOF', '[ "$1" = x ]', 'EOF') },
        @{ name = "none-with-function"; modes = ""; unreadable = 0; lines = @('# modes: none', 'f() { echo "$1"; }', 'f a') },
        # FAIL: the reviewer's shapes (round 1 a-f, round 2 g-l) and the rest
        @{ name = "unquoted-case"; unreadable = 1; lines = @('case ${1:-check} in', '    check) ;;', 'esac') },
        @{ name = "case-on-positional"; unreadable = 1; lines = @('case "$1$2" in', '    extra) ;;', 'esac') },
        @{ name = "assigned-unquoted-case"; unreadable = 1; lines = @('mode="${1:-check}"', 'case $mode in', '    extra) ;;', 'esac') },
        @{ name = "assigned-braced-case"; unreadable = 1; lines = @('mode="${1:-check}"', 'case "${mode}" in', '    extra) ;;', 'esac') },
        @{ name = "assigned-not-equal"; unreadable = 1; lines = @('mode="${1:-check}"', 'if [ "$mode" != extra ]; then :; fi') },
        @{ name = "assigned-via-unquoted-no-colon"; unreadable = 1; lines = @('mode=${1-check}', 'case "$mode" in', '    extra) ;;', 'esac') },
        @{ name = "toplevel-not-equal"; unreadable = 1; lines = @('[ "$1" != extra ] && exit 2') },
        @{ name = "toplevel-double-bracket"; unreadable = 1; lines = @('[[ $1 == extra ]] && exit 2') },
        @{ name = "toplevel-plain-positional"; unreadable = 1; lines = @('if [ "$1" = extra ]; then :; fi') },
        @{ name = "toplevel-echo"; unreadable = 1; lines = @('echo "mode: ${1:-check}"') },
        @{ name = "toplevel-multiline-string-tail"; unreadable = 1; lines = @('python3 -c ''import sys', 'print(1)'' "$1"') },
        @{ name = "multiline-single-quote-then-case"; unreadable = 2; lines = @('python3 -c ''import sys', 'print(1)'' "$1"', 'case "$1" in', '  extra) ;;', 'esac') },
        @{ name = "indented-block"; unreadable = 1; lines = @('if true; then', '    case "$1" in', '      check) ;;', '      extra) ;;', '    esac', 'fi') },
        @{ name = "main-function-and-all-args"; unreadable = 1; lines = @('main() {', '    case "$1" in', '      check) ;;', '    esac', '}', 'main "$@"') },
        @{ name = "case-on-all-args"; unreadable = 1; lines = @('case "$*" in', '  check) ;;', '  extra) ;;', 'esac') },
        @{ name = "set-rebinds"; unreadable = 2; lines = @('set -- "${1:-check}"', 'case "$1" in', '  check) ;;', 'esac') },
        @{ name = "set-with-positionals"; unreadable = 1; lines = @('set -- $other', 'echo done') },
        @{ name = "function-uses-selector"; unreadable = 1; lines = @('mode="${1:-check}"', 'run() { case "$mode" in', '  extra) echo ;;', '  esac; }', 'run') },
        @{ name = "for-all-args"; unreadable = 1; lines = @('for m in "$@"; do', '  case "$m" in', '    extra) ;;', '  esac', 'done') },
        @{ name = "none-uses-positional"; unreadable = 1; lines = @('# modes: none', 'echo "$1"') },
        @{ name = "none-with-canonical-dispatch"; unreadable = 1; lines = @('# modes: none', 'mode="${1:-check}"', 'case "$mode" in', '  check) ;;', 'esac') },
        @{ name = "selector-into-own-function"; unreadable = 1; lines = @('mode="${1:-check}"', 'run() { case "$1" in check) ;; extra) ;; esac; }', 'run "$mode"') },
        @{ name = "selector-into-eval"; unreadable = 1; lines = @('mode="${1:-check}"', 'do_check() { :; }', 'do_extra() { :; }', 'eval "do_$mode"') }
    )
    foreach ($s in $shapes) {
        $sp = Join-Path $qs "shape-$($s.name).sh"
        [IO.File]::WriteAllText($sp, "#!/usr/bin/env bash`n" + ($s.lines -join "`n") + "`n")
        $d = Get-VmDispatchedModes $sp
        if ($s.unreadable -eq 0 -and ($d.modes -join " ") -ne $s.modes) { $problems.Add("mode dispatch fixture '$($s.name)': read modes '$($d.modes -join ' ')', want '$($s.modes)'") }
        if ($d.unreadable.Count -ne $s.unreadable) { $problems.Add("mode dispatch fixture '$($s.name)': $($d.unreadable.Count) unreadable lines, want $($s.unreadable)") }
    }
    $rules = @(
        @{ check = "vm-a-check.sh"; skip = $false },
        @{ check = "vm-a-check.sh other"; skip = $false },
        @{ check = "vm-a-check.sh nope"; skip = $true; why = "mode 'nope' not in vm-a-check.sh" },
        @{ check = "vm-b-check.sh check"; skip = $true; why = "no '# modes:' line" },
        @{ check = "vm-missing-check.sh"; skip = $true; why = "does not exist" },
        @{ check = "vm-play-check.sh parse"; skip = $false },
        @{ check = "vm-library-check.sh check"; skip = $false }
    )
    foreach ($c in @("vm-play-check.sh", "vm-play-check.sh check", "vm-play-check.sh helper", "vm-play-check.sh verify", "vm-play-check.sh perms", "vm-play-check.sh remove", "vm-play-check.sh launch", "vm-play-check.sh launch-windows", "vm-library-check.sh play")) {
        $rules += @{ check = $c; skip = $true; why = "scripts/play-vm-files.sh" }
    }
    foreach ($r in $rules) {
        $got = Get-CheckSkip $r.check $qs $qt
        if ($r.skip -and (-not $got -or $got -notlike "*$($r.why)*")) { $problems.Add("vm-queue rules: '$($r.check)' should be SKIPPED ($($r.why)), got: $got") }
        if (-not $r.skip -and $got) { $problems.Add("vm-queue rules: '$($r.check)' should run, got: $got") }
    }
    # one of the two files is not enough; both are
    $pd = Join-Path $qt "output\play-vm"
    New-Item -ItemType Directory -Force $pd | Out-Null
    [IO.File]::WriteAllText((Join-Path $pd "ruya-pack"), "x")
    if (-not (Get-CheckSkip "vm-play-check.sh verify" $qs $qt)) { $problems.Add("vm-queue rules: ruya-pack alone must not be enough for the .play checks") }
    [IO.File]::WriteAllText((Join-Path $pd "hello-play-native.play.zip"), "x")
    foreach ($c in @("vm-play-check.sh", "vm-play-check.sh helper", "vm-play-check.sh launch", "vm-library-check.sh play")) {
        $got = Get-CheckSkip $c $qs $qt
        if ($got) { $problems.Add("vm-queue rules: '$c' should run with both files, got: $got") }
    }
    if ((Get-PlayVmFiles $qt).files.Count -ne 2) { $problems.Add("vm-queue rules: Get-PlayVmFiles does not list both files") }
    # launch-windows also needs the Windows sample (RUY-902), and only it: the other checks run without it
    $got = Get-CheckSkip "vm-play-check.sh launch-windows" $qs $qt
    if (-not $got -or $got -notlike "*hello-play-wine.play.zip*") { $problems.Add("vm-queue rules: 'vm-play-check.sh launch-windows' should be SKIPPED without the Windows sample, got: $got") }
    [IO.File]::WriteAllText((Join-Path $pd "hello-play-wine.play.zip"), "x")
    $got = Get-CheckSkip "vm-play-check.sh launch-windows" $qs $qt
    if ($got) { $problems.Add("vm-queue rules: 'vm-play-check.sh launch-windows' should run with the Windows sample, got: $got") }
    if ((Get-PlayVmFiles $qt).files.Count -ne 3) { $problems.Add("vm-queue rules: Get-PlayVmFiles does not list the Windows sample") }
} finally { Remove-Item -Recurse -Force $qt -ErrorAction SilentlyContinue }

# 1e. One WSL command builds the .play files (RUY-890): dev-setup.md quotes the very string the queue's
# SKIP text prints.
$devSetup = [IO.File]::ReadAllText((Join-Path $Repo "docs\dev-setup.md"))
if (-not $devSetup.Contains($script:PlayCommand)) { $problems.Add("docs/dev-setup.md does not quote the queue's play-vm-files command: $($script:PlayCommand)") }
if (@([regex]::Matches($devSetup, 'wsl -d FedoraLinux-44[^\r\n`]*play-vm-files\.sh') | ForEach-Object { $_.Value } | Sort-Object -Unique).Count -gt 1) { $problems.Add("docs/dev-setup.md gives more than one WSL command for play-vm-files.sh") }

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
