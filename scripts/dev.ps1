# RuyaOS development loop on the Windows host. One entry point for building, testing and
# running, so every contributor (human or AI) runs the exact same checks.
#
#   .\scripts\dev.ps1 check     # prerequisites present?
#   .\scripts\dev.ps1 build     # configure (first time) + build the shell
#   .\scripts\dev.ps1 test      # EVERYTHING that must pass before a commit (text lint, rust, shell)
#   .\scripts\dev.ps1 run       # start the shell in a window with mock services
#   .\scripts\dev.ps1 shots     # run the screenshot tests on real windows, save to output\shell-shots
#   .\scripts\dev.ps1 rust      # Rust checks only (fmt, clippy for Windows + Linux, tests)
#   .\scripts\dev.ps1 shell     # shell checks only (build, token lint, qmllint, Qt Quick tests)
#   .\scripts\dev.ps1 test -Shards 4    # the offscreen Qt Quick tests in 4 processes at a time (default 3)
#   .\scripts\dev.ps1 qml tst_themes tst_glass   # PARTIAL: builds the test runner, runs only these files
#   .\scripts\dev.ps1 docs      # the checks that read docs\ (text, board, developer guide, spec lint)
#
# Qt location: $env:RUYA_QT_DIR, default D:\dev\Qt\6.10.3\msvc2022_64.
param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "build", "test", "run", "shots", "rust", "shell", "qml", "docs")]
    [string]$Command = "test",
    # qml only: test files of shell\tests by name (tst_themes, tst_themes.qml; several, or comma-separated).
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    # [object[]], not [string[]]: binding to strings would join an in-process `a,b` array with a space (RUY-725).
    [object[]]$Tests = @(),
    # shots only, for the self-test of the sleeping-display stop: the probe window is never shown, as on
    # a display that is asleep, so the probe must see no frames and `shots` must stop with exit 1.
    [switch]$NoFramesProbe,
    # test/shell only (T-463): how many Qt Quick test processes run at the same time (each runs one
    # test file); 1 = one after the other. About 3 is the sweet spot: more only adds timing noise.
    [ValidateRange(1, 16)]
    [int]$Shards = 3
)

# Native tools write progress to stderr; never let PowerShell turn that into errors.
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
$QtDir = if ($env:RUYA_QT_DIR) { $env:RUYA_QT_DIR } else { "D:\dev\Qt\6.10.3\msvc2022_64" }
$ShellBuild = Join-Path $Repo "shell\build-win"
$Services = Join-Path $Repo "services"
$script:Failures = @()
# Git for Windows: the `git` on PATH can be devkitPro's MSYS2 build, which cannot read worktree links.
$Git = Join-Path $env:ProgramFiles "Git\cmd\git.exe"
if (-not (Test-Path $Git)) { $Git = "git" }
# Written by `test` only when it ends ALL GREEN on a clean tree whose HEAD did not move during the
# run; scripts\push-main.ps1 reads it to skip re-running `test` on content that already passed.
$GreenMarker = Join-Path $Repo "output\last-green-test.txt"

# Per-step wall time, printed at the end (LEAD.md 6b: time the gates).
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:StepTimes = @()
$script:StepName = $null
$script:StepStart = 0.0
function Close-Step {
    if ($script:StepName) {
        $script:StepTimes += [pscustomobject]@{ Name = $script:StepName; Sec = $script:Clock.Elapsed.TotalSeconds - $script:StepStart }
        $script:StepName = $null
    }
}
function Step([string]$Name) {
    Close-Step
    Write-Host ""; Write-Host "==> $Name" -ForegroundColor Cyan
    $script:StepName = $Name
    $script:StepStart = $script:Clock.Elapsed.TotalSeconds
}

function Record([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "    ok: $Name" -ForegroundColor Green }
    else { Write-Host "    FAILED: $Name" -ForegroundColor Red; $script:Failures += $Name }
}

# A locked Windows session (LogonUI running) renders nothing and stalls timers. RUYA_ASSUME_LOCKED=1
# simulates it (only this script reads it) so the behaviour can be checked on an unlocked desktop.
function Test-SessionLocked {
    return ($env:RUYA_ASSUME_LOCKED -eq "1") -or [bool](Get-Process LogonUI -ErrorAction SilentlyContinue)
}
function Stop-SessionLocked {
    Write-Host "    The Windows session is locked: real windows can't render. Unlock it and re-run shots." -ForegroundColor Red
    Record "shots (session locked)" $false
}

# A sleeping display presents no frames (T-460/T-462): `frameSwapped` never fires and the tests that wait
# on a frame fail for no code reason. The test runner shows one small window and waits 2 s for a frame
# (RUYA_PROBE_FRAMES, tst_main.cpp). True when the window presented one.
function Test-DisplayPresentsFrames([switch]$NoFrames, [switch]$Offscreen) {
    $exe = Join-Path $ShellBuild "Release\tst_ruyashell.exe"
    $env:RUYA_PROBE_FRAMES = "1"
    if ($NoFrames) { $env:RUYA_PROBE_NO_FRAMES = "1" }
    if ($Offscreen) { $env:QT_QPA_PLATFORM = "offscreen" } else { $env:QSG_RENDER_LOOP = "basic" }
    try {
        & $exe | Out-Null
        return $LASTEXITCODE   # 0 frames presented, 3 none (asleep), anything else: the probe failed

    } finally {
        Remove-Item Env:\RUYA_PROBE_FRAMES, Env:\RUYA_PROBE_NO_FRAMES, Env:\QSG_RENDER_LOOP, Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    }
}
function Stop-DisplayAsleep {
    Write-Host "    The display is asleep: wake it and run shots again." -ForegroundColor Red
    Record "shots (display asleep)" $false
}

function Invoke-Native([string]$Name, [scriptblock]$Block) {
    & $Block
    Record $Name ($LASTEXITCODE -eq 0)
}

# The real CMake. devkitPro (MSYS2) puts its own cmake first on PATH, and that one can't drive the
# Visual Studio generator, so never trust PATH: %ProgramFiles%\CMake, then the copy Visual Studio
# ships, then whatever PATH has.
function Find-CMake {
    $candidates = @(Join-Path $env:ProgramFiles "CMake\bin\cmake.exe")
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $candidates += @(Get-ChildItem (Join-Path $root "Microsoft Visual Studio\*\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe") -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $onPath = Get-Command cmake -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    Write-Host "cmake not found (install CMake or Visual Studio's C++ workload). See docs/dev-setup.md." -ForegroundColor Red
    exit 2
}

function Use-Qt {
    if (-not (Test-Path (Join-Path $QtDir "bin\Qt6Core.dll"))) {
        Write-Host "Qt not found at $QtDir (set RUYA_QT_DIR). See docs/dev-setup.md." -ForegroundColor Red
        exit 2
    }
    if (-not ($env:PATH -like "*$QtDir\bin*")) { $env:PATH = "$QtDir\bin;$env:PATH" }
    # MSBuild and CMake's own sub-calls look cmake up on PATH too: put the real one first.
    $script:CMake = Find-CMake
    $cmakeBin = Split-Path -Parent $script:CMake
    if (-not ($env:PATH -like "$cmakeBin;*")) { $env:PATH = "$cmakeBin;$env:PATH" }
}

function Do-Check {
    Step "Prerequisites"
    $ok = $true
    foreach ($tool in "git", "cmake", "cargo", "rustup") {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if ($tool -eq "cmake") { Write-Host "    cmake : $(Find-CMake) (used by dev.ps1)"; continue }
        if ($found) { Write-Host "    $tool : $($found.Source)" } else { Write-Host "    $tool : MISSING" -ForegroundColor Red; $ok = $false }
    }
    if (Test-Path (Join-Path $QtDir "bin\Qt6Core.dll")) { Write-Host "    Qt   : $QtDir" } else { Write-Host "    Qt   : MISSING at $QtDir" -ForegroundColor Red; $ok = $false }
    $targets = rustup target list --installed
    if ($targets -contains "x86_64-unknown-linux-gnu") { Write-Host "    rust linux target: installed" }
    else { Write-Host "    rust linux target: MISSING (rustup target add x86_64-unknown-linux-gnu)" -ForegroundColor Red; $ok = $false }
    Record "prerequisites" $ok
}

# -Target: one CMake target and what it needs (the `qml` fast mode builds only tst_ruyashell).
function Do-Build([string]$Target) {
    Use-Qt
    Step "Build shell (Release$(if ($Target) { ", target $Target" }))"
    if (-not (Test-Path (Join-Path $ShellBuild "CMakeCache.txt"))) {
        Invoke-Native "cmake configure" { & $script:CMake -S (Join-Path $Repo "shell") -B $ShellBuild -G "Visual Studio 18 2026" -A x64 "-DCMAKE_PREFIX_PATH=$($QtDir -replace '\\','/')" }
    }
    $targetArgs = @()
    if ($Target) { $targetArgs = @("--target", $Target) }
    Invoke-Native "cmake build$(if ($Target) { " ($Target)" })" { & $script:CMake --build $ShellBuild --config Release @targetArgs -- -m '-v:minimal' -nologo }   # quoted: PS 5.1 splits -v:x
}

function Do-Rust {
    Step "Rust: fmt"
    Push-Location $Services
    Invoke-Native "cargo fmt --check" { cargo fmt --check }
    Step "Rust: clippy (Windows)"
    Invoke-Native "clippy windows" { cargo clippy --all-targets --features ruya-platform/dev-mock --locked -q -- -D warnings }
    Step "Rust: clippy (Linux target, type-checks Linux-only code)"
    Invoke-Native "clippy linux" { cargo clippy --all-targets --features ruya-platform/dev-mock --locked -q --target x86_64-unknown-linux-gnu -- -D warnings }
    Step "Rust: tests"
    Invoke-Native "cargo test" { cargo test --features ruya-platform/dev-mock --locked -q }
    Pop-Location
}

# "Name::test_x" for every test function in shell\tests that saves a screenshot
# (`shotsDir + "/...`; Name = the file's TestCase name), so `shots` runs only those.
function Get-ScreenshotFunctions([string]$Dir = (Join-Path $Repo "shell\tests"), [string[]]$Only = @()) {
    $fns = @()
    foreach ($file in Get-ChildItem $Dir -Filter *.qml) {
        if ($Only.Count -gt 0 -and $Only -notcontains $file.BaseName) { continue }
        $case = $null; $fn = $null
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
            if (-not $case -and $line -match '^\s+name:\s*"(\w+)"') { $case = $Matches[1] }
            if ($line -match '\bfunction (test_\w+)\s*\(') { $fn = $Matches[1] }
            if ($fn -and $case -and $line -match 'shotsDir \+ "/' -and $fns -notcontains "${case}::$fn") { $fns += "${case}::$fn" }
        }
    }
    return $fns
}

# RUY-511: `shots tst_a tst_b.qml,tst_c` -> the file base names that exist in <Dir>; the rest is Unknown.
function Resolve-ShotsFilter([string[]]$Names, [string]$Dir) {
    $files = @(); $unknown = @()
    foreach ($n in $Names) {
        $base = [IO.Path]::GetFileNameWithoutExtension("$n".Trim())
        if ($base -and (Test-Path -LiteralPath (Join-Path $Dir "$base.qml"))) { if ($files -notcontains $base) { $files += $base } }
        else { $unknown += "$n" }
    }
    return [pscustomobject]@{ Files = $files; Unknown = $unknown }
}

# RUY-511: the functions to re-run once: only those whose own FAIL line carries the lost-activation text
# (tst_main.cpp's qFail). The QWARN line of other functions, or any other failure, never selects one.
function Get-LostActivationFailures([string[]]$LogLines) {
    $fns = @()
    foreach ($line in $LogLines) {
        if ($line -match '^FAIL!\s*:\s*(?:\w+::)*(\w+::\w+)\(.*TEST WINDOW LOST ACTIVATION' -and $fns -notcontains $Matches[1]) { $fns += $Matches[1] }
    }
    return $fns
}

function Test-ShotsFilterAndRetry {
    $dir = Join-Path $Repo "output\shots-filter-fixture"
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($x in @("a", "b")) {
        [IO.File]::WriteAllText((Join-Path $dir "tst_$x.qml"), "TestCase {`n    name: `"T$x`"`n    function test_$x() {`n        grab(shotsDir + `"/$x.png`")`n    }`n}`n")
    }
    $one = Resolve-ShotsFilter @("tst_a") $dir
    $ext = Resolve-ShotsFilter @("tst_a.qml") $dir
    $many = Resolve-ShotsFilter @("tst_a", "tst_b.qml") $dir
    $unk = Resolve-ShotsFilter @("tst_a", "tst_zz") $dir
    $fnA = @(Get-ScreenshotFunctions $dir @("tst_a"))
    $fnAll = @(Get-ScreenshotFunctions $dir)
    $ok = ($one.Files -join ",") -eq "tst_a" -and $one.Unknown.Count -eq 0 -and
        ($ext.Files -join ",") -eq "tst_a" -and ($many.Files -join ",") -eq "tst_a,tst_b" -and
        ($unk.Unknown -join ",") -eq "tst_zz" -and
        ($fnA -join ",") -eq "Ta::test_a" -and $fnAll.Count -eq 2
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    Record "shots filter self-check (with and without .qml, several names, an unknown name; only the named file's functions)" $ok
    $lost = @("QWARN  : ruyashell::WindowLostFixture::test_the_window_loses_activation_mid_test() ruya-shell test: TEST WINDOW LOST ACTIVATION (the desktop took focus); a focus failure", "FAIL!  : ruyashell::WindowLostFixture::test_the_window_loses_activation_mid_test() TEST WINDOW LOST ACTIVATION: the desktop took focus", "   Loc: [x.cpp(49)]", "Totals: 1 passed, 1 failed")
    $plain = @("QWARN  : ruyashell::WindowLostFixture::test_the_window_loses_activation_mid_test() ruya-shell test: TEST WINDOW LOST ACTIVATION (the desktop took focus); a focus failure", "FAIL!  : ruyashell::Ty::test_plain() Compared values are not the same", "Totals: 1 passed, 1 failed")
    $selLost = @(Get-LostActivationFailures $lost)
    $selPlain = @(Get-LostActivationFailures $plain)
    Record "shots retry selection self-check (a lost-activation failure is selected; an ordinary failure, even beside a lost-activation warning, is not)" ($selLost.Count -eq 1 -and $selLost[0] -eq "WindowLostFixture::test_the_window_loses_activation_mid_test" -and $selPlain.Count -eq 0)
}

# T-463: the offscreen Qt Quick tests, one process per test file (the runner takes one -input), $Shards of
# them at a time, biggest file first (a size heuristic: the long ones start early, so the last one does not
# run alone), each with its own log in <LogDir>. A file whose process exits non-zero, crashes (no "Totals"
# line) or runs longer than $TimeoutSec fails the run and its log is named. Returns the sums and the failures.
# -MakeCommand { param($file, $log) } returns @{ Exe; Args } and exists for the self-check below.
function Invoke-QmlShards([string[]]$Files, [string]$LogDir, [int]$Shards, [int]$TimeoutSec = 600, [scriptblock]$MakeCommand) {
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    Get-ChildItem $LogDir -Filter "*.txt" -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    if (-not $MakeCommand) {
        $exe = Join-Path $ShellBuild "Release\tst_ruyashell.exe"
        $MakeCommand = { param($file, $log) @{ Exe = $exe; Args = @("-o", "`"$log,txt`"", "-input", "`"$file`"") } }.GetNewClosure()
    }
    $queue = New-Object System.Collections.Queue
    foreach ($f in ($Files | Sort-Object { (Get-Item -LiteralPath $_).Length } -Descending)) { $queue.Enqueue($f) }
    $running = @()
    $missing = @()
    $res = [pscustomobject]@{ Passed = 0; Failed = 0; Skipped = 0; Files = 0; Bad = @(); Lines = @() }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Shards) {
            $f = $queue.Dequeue()
            $base = [IO.Path]::GetFileNameWithoutExtension($f)
            $log = Join-Path $LogDir "$base.txt"
            $cmd = & $MakeCommand $f $log
            # RUY-994: a failed build leaves no program. Start-Process would only write an error and leave no process
            # to wait for, so the file would sit until $TimeoutSec: fail it at once, naming the program (once).
            if (-not (Test-Path -LiteralPath $cmd.Exe)) {
                $res.Files++
                if ($missing -notcontains $cmd.Exe) { $missing += $cmd.Exe; $res.Bad += "$($cmd.Exe) not found: the build failed" }
                continue
            }
            $p = Start-Process -FilePath $cmd.Exe -ArgumentList $cmd.Args -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
            $null = $p.Handle    # keeps the exit code readable after the process ended (Windows PowerShell 5.1)
            $running += [pscustomobject]@{ Proc = $p; Base = $base; Log = $log; Start = $clock.Elapsed.TotalSeconds }
        }
        Start-Sleep -Milliseconds 100
        $still = @()
        foreach ($r in $running) {
            $timedOut = (-not $r.Proc.HasExited) -and (($clock.Elapsed.TotalSeconds - $r.Start) -gt $TimeoutSec)
            if (-not $r.Proc.HasExited -and -not $timedOut) { $still += $r; continue }
            if ($timedOut) { try { $r.Proc.Kill() } catch { } ; $r.Proc.WaitForExit(5000) | Out-Null }
            $res.Files++
            $totals = $null
            if (Test-Path -LiteralPath $r.Log) {
                $totals = Select-String -LiteralPath $r.Log -Pattern '^Totals: (\d+) passed, (\d+) failed, (\d+) skipped' | Select-Object -Last 1
            }
            $code = if ($timedOut) { -1 } else { $r.Proc.ExitCode }
            if ($totals) {
                $res.Passed += [int]$totals.Matches[0].Groups[1].Value
                $res.Failed += [int]$totals.Matches[0].Groups[2].Value
                $res.Skipped += [int]$totals.Matches[0].Groups[3].Value
            }
            if ($timedOut -or $code -ne 0 -or -not $totals) {
                $why = if ($timedOut) { "hung (killed after $TimeoutSec s)" } elseif (-not $totals) { "crashed (exit code $code, no Totals line)" } else { "failed (exit code $code)" }
                $res.Bad += "$($r.Base): $why - log $($r.Log)"
                if (Test-Path -LiteralPath $r.Log) {
                    $res.Lines += Get-Content -LiteralPath $r.Log | Where-Object { $_ -match '^(FAIL|XPASS|Totals)|failure location' } | ForEach-Object { "$($r.Base): $_" }
                }
            }
            if (Test-Path -LiteralPath $r.Log) {
                # QWARN lines (font directory, expected rejections) stay in the log; a QCRITICAL is shown.
                $res.Lines += Get-Content -LiteralPath $r.Log | Where-Object { $_ -match '^QCRITICAL' } | ForEach-Object { "$($r.Base): $_" }
            }
        }
        $running = $still
    }
    $res | Add-Member -NotePropertyName Seconds -NotePropertyValue $clock.Elapsed.TotalSeconds
    return $res
}

# The gate: every shell\tests\tst_*.qml offscreen, $Shards processes at a time, one combined verdict.
function Run-QmlShards {
    $files = @(Get-ChildItem (Join-Path $Repo "shell\tests") -Filter "tst_*.qml" | ForEach-Object { $_.FullName })
    $logDir = Join-Path $ShellBuild "qmltest"
    # The gate runs offscreen: immune to a locked screen, OS focus changes and other windows, same as CI.
    $env:QT_QPA_PLATFORM = "offscreen"
    $res = Invoke-QmlShards $files $logDir $Shards
    Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    $res.Lines | ForEach-Object { Write-Host "    $_" }
    foreach ($b in $res.Bad) { Write-Host "    SHARD FAILED: $b" -ForegroundColor Red }
    Write-Host ("    Totals: {0} passed, {1} failed, {2} skipped in {3} files, {4} at a time, {5:N0} s (logs: {6})" -f $res.Passed, $res.Failed, $res.Skipped, $res.Files, $Shards, $res.Seconds, $logDir)
    Record "Qt Quick tests" ($res.Bad.Count -eq 0 -and $res.Failed -eq 0 -and $res.Files -eq $files.Count)
}

# T-463: the shard runner's failure paths, on stand-in programs (a test file is a name here): a run with a
# failed file, a crash (no Totals line), a hang and a pass must give the right verdict, name the log of each
# bad file and add up the totals of the good ones.
function Test-QmlShardRunner {
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-shards-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fx | Out-Null
    $names = "tst_ok1", "tst_ok2", "tst_fail", "tst_crash", "tst_hang"
    foreach ($n in $names) { Set-Content -LiteralPath (Join-Path $fx "$n.qml") -Value "x" }
    $ps = (Get-Command powershell.exe).Source
    # RUY-928: the hang limit is derived from how long one powershell.exe takes to start and exit right now (a
    # stand-in file needs about that long), so a loaded machine gets a longer limit: 10x the measurement, never
    # under 4 s. The hang stand-in sleeps three times the limit, so it is always still running when killed.
    $probe = [Diagnostics.Stopwatch]::StartNew()
    & $ps -NoProfile -Command exit | Out-Null
    $startupSec = $probe.Elapsed.TotalSeconds
    $hangLimit = [int][Math]::Max(4, [Math]::Ceiling(10 * $startupSec))
    $hangSleep = 3 * $hangLimit
    Write-Host ("    shard runner self-check: powershell.exe start-up {0:N2} s, hang limit {1} s" -f $startupSec, $hangLimit)
    $make = {
        param($file, $log)
        $base = [IO.Path]::GetFileNameWithoutExtension($file)
        $line = "Totals: 3 passed, 0 failed, 1 skipped, 0 blacklisted, 5ms"
        $body = switch ($base) {
            "tst_fail"  { "Set-Content -LiteralPath '$log' 'FAIL!  : x::test_y() boom'; Add-Content -LiteralPath '$log' 'Totals: 2 passed, 1 failed, 0 skipped, 0 blacklisted, 5ms'; exit 1" }
            "tst_crash" { "Set-Content -LiteralPath '$log' 'Start testing of x'; exit 3" }
            "tst_hang"  { "Start-Sleep -Seconds $hangSleep" }
            default     { "Set-Content -LiteralPath '$log' '$line'; exit 0" }
        }
        @{ Exe = $ps; Args = @("-NoProfile", "-Command", "`"$body`"") }
    }.GetNewClosure()
    $all = @($names | ForEach-Object { Join-Path $fx "$_.qml" })
    $r = Invoke-QmlShards $all (Join-Path $fx "logs") 2 $hangLimit $make
    $bad = $r.Bad -join "`n"
    $ok = ($r.Files -eq 5) -and ($r.Bad.Count -eq 3) -and ($r.Passed -eq 8) -and ($r.Failed -eq 1) -and ($r.Skipped -eq 2) `
        -and ($bad -match 'tst_fail: failed .*tst_fail\.txt') -and ($bad -match 'tst_crash: crashed .*tst_crash\.txt') -and ($bad -match "tst_hang: hung \(killed after $hangLimit s\) .*tst_hang\.txt") `
        -and ($bad -notmatch 'tst_ok')
    if (-not $ok) { Write-Host "    got: files $($r.Files), passed $($r.Passed), failed $($r.Failed), skipped $($r.Skipped), bad:`n$bad" -ForegroundColor Yellow }
    Record "shard runner self-check (a failed, a crashed and a hung file are named by log; the totals add up)" $ok

    # RUY-994: a program that is not there (the build failed) is a named failure at once, not a wait for the limit.
    $gone = Join-Path $fx "build\tst_gone.exe"
    $makeGone = { param($file, $log) @{ Exe = $gone; Args = @("-input", "`"$file`"") } }.GetNewClosure()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $g = Invoke-QmlShards $all (Join-Path $fx "logs-gone") 2 30 $makeGone
    $goneSec = $clock.Elapsed.TotalSeconds
    $goneOk = ($g.Files -eq 5) -and ($g.Bad.Count -eq 1) -and ($g.Bad[0] -eq "$gone not found: the build failed") -and ($g.Passed -eq 0) -and ($goneSec -lt 10)
    if (-not $goneOk) { Write-Host ("    got: files $($g.Files), bad $($g.Bad.Count): $($g.Bad -join ' | '), {0:N1} s" -f $goneSec) -ForegroundColor Yellow }
    Record "shard runner self-check (a missing test program is one FAILED naming the file, in seconds, not a wait for the limit)" $goneOk

    # The same for CI's twin, scripts/run-qml-tests.sh (Git's bash), with a stand-in test program.
    $bash = "$env:ProgramFiles\Git\bin\bash.exe"
    if (-not (Test-Path $bash)) {
        Record "shard runner (sh) self-check: Git's bash.exe not found" $false
    } else {
        $fake = "#!/bin/bash`nlog=`"`${2%,txt}`"; base=`$(basename `"`$4`" .qml)`ncase `$base in`n" +
            "  tst_fail) echo 'FAIL!  : x::test_y() boom' > `"`$log`"; echo 'Totals: 2 passed, 1 failed, 0 skipped, 0 blacklisted, 5ms' >> `"`$log`"; exit 1;;`n" +
            "  tst_crash) echo Start > `"`$log`"; exit 3;;`n  tst_hang) sleep 30;;`n" +
            "  *) echo 'Totals: 3 passed, 0 failed, 1 skipped, 0 blacklisted, 5ms' > `"`$log`";;`nesac`n"
        $fakePath = Join-Path $fx "fake-tst.sh"
        [IO.File]::WriteAllText($fakePath, $fake, (New-Object System.Text.UTF8Encoding($false)))
        $env:RUYA_QML_TIMEOUT = "2"
        $logsSh = (Join-Path $fx "logs-sh") -replace '\\', '/'
        $out = (& $bash (Join-Path $PSScriptRoot "run-qml-tests.sh") ($fakePath -replace '\\', '/') 2 $logsSh ($fx -replace '\\', '/') 2>&1 | Out-String)
        $shExit = $LASTEXITCODE
        Remove-Item Env:\RUYA_QML_TIMEOUT -ErrorAction SilentlyContinue
        $shOk = ($shExit -eq 1) -and ($out -match 'tst_fail: failed .*logs-sh/tst_fail\.txt') -and ($out -match 'tst_crash: crashed or hung .*logs-sh/tst_crash\.txt') `
            -and ($out -match 'tst_hang: crashed or hung .*logs-sh/tst_hang\.txt') -and ($out -notmatch 'tst_ok\d: ') `
            -and ($out -match 'Totals: 8 passed, 1 failed, 2 skipped in 4 files')
        if (-not $shOk) { Write-Host "    exit $shExit, output:`n$out" -ForegroundColor Yellow }
        Record "shard runner (sh) self-check (CI's script names a failed, a crashed and a hung file by log; the totals add up)" $shOk

        # RUY-1202: the same script with a program that is not there: one named line, exit 1, at once, no per-file lines.
        $goneSh = ((Join-Path $fx "build\tst_gone") -replace '\\', '/')
        $clockSh = [Diagnostics.Stopwatch]::StartNew()
        $outGone = (& $bash (Join-Path $PSScriptRoot "run-qml-tests.sh") $goneSh 2 ((Join-Path $fx "logs-sh-gone") -replace '\\', '/') ($fx -replace '\\', '/') 2>&1 | Out-String)
        $goneShExit = $LASTEXITCODE
        $goneShSec = $clockSh.Elapsed.TotalSeconds
        $goneShLines = @($outGone -split "`r?`n" | Where-Object { $_ -ne '' })
        $goneShOk = ($goneShExit -eq 1) -and ($goneShLines.Count -eq 1) -and ($goneShLines[0] -eq "SHARD FAILED: $goneSh not found: the build failed") -and ($goneShSec -lt 10)
        if (-not $goneShOk) { Write-Host ("    exit $goneShExit, {0:N1} s, output:`n$outGone" -f $goneShSec) -ForegroundColor Yellow }
        Record "shard runner (sh) self-check (CI's script names a missing test program once and exits 1 at once, no line per file)" $goneShOk
    }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
}

# RUY-654: revert-check.ps1 gives the same verdict (exit code and CAUGHT line) whether its output is piped
# through Select-Object -Last 3 or not, on a stand-in runner: a mutation the "test" notices is CAUGHT, one
# that changes nothing is NOT CAUGHT.
function Test-RevertCheckPiping {
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-revert-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fx | Out-Null
    $target = Join-Path $fx "target.txt"
    [IO.File]::WriteAllText($target, "value=good`n")
    $runner = { if ((Get-Content -Raw -LiteralPath $target) -match 'value=bad') { "FAIL!  : tst_fixture::test_value()"; "Totals: 0 passed, 1 failed" } else { "Totals: 1 passed, 0 failed" } }.GetNewClosure()
    $script = Join-Path $PSScriptRoot "revert-check.ps1"
    $ok = $true
    # One case: run revert-check (output plain or piped through Select-Object -Last 3) with -File/-Old/-New and
    # $Extra's parameters; the verdict is CAUGHT (exit 0, a CAUGHT line, plus $AlsoCaught when given) or NOT CAUGHT
    # (exit 1), and the file is back to its original text. Returns $true when it holds; says what it saw when not.
    function Test-RevertCase($Label, $Run, $File, $New, $Piped, $Caught, $Extra, $AlsoCaught = $null) {
        $params = @{ File = $File; Old = "value=good"; New = $New } + $Extra
        if ($Piped) { $lines = @(& $Run @params *>&1 | Select-Object -Last 3 | Out-String -Stream) }
        else { $lines = @(& $Run @params *>&1 | Out-String -Stream) }
        $code = $LASTEXITCODE
        $text = $lines -join "`n"
        $said = if ($Caught) { ($text -match '(?m)^CAUGHT') -and (-not $AlsoCaught -or $text -match $AlsoCaught) } else { $text -match 'NOT CAUGHT' }
        $good = ($code -eq $(if ($Caught) { 0 } else { 1 })) -and $said -and ((Get-Content -Raw -LiteralPath $File) -eq "value=good`n")
        if (-not $good) { Write-Host "    ${Label}: exit $code, output:`n$text" -ForegroundColor Yellow }
        return [bool]$good
    }
    $staleLog = Join-Path $fx "ruya-qmltest-tst_fixture.txt"
    # The third case: a failing log left by an earlier run must not make a no-op mutation look caught.
    foreach ($case in @(@{ New = "value=bad"; Caught = $true }, @{ New = "value=good"; Caught = $false }, @{ New = "value=good"; Caught = $false; Stale = $true })) {
        foreach ($piped in @($false, $true)) {
            if ($case.Stale) { Set-Content -LiteralPath $staleLog -Value "FAIL!  : tst_fixture::test_old()" }
            if (-not (Test-RevertCase "piped=$piped caught=$($case.Caught)" $script $target $case.New $piped $case.Caught @{ Runner = $runner; Test = "tst_fixture"; LogDir = $fx })) { $ok = $false }
        }
    }
    # RUY-659: default mode also takes the child's exit code: a stand-in that exits non-zero with no failing
    # log line is CAUGHT (a Record-style self-check failure), one that exits 0 with none is NOT CAUGHT.
    $exitRunner = { if ((Get-Content -Raw -LiteralPath $target) -match 'value=bad') { $global:LASTEXITCODE = 3; "FAILED: fixture self-check" } else { $global:LASTEXITCODE = 0; "ALL GREEN" } }.GetNewClosure()
    foreach ($case in @(@{ New = "value=bad"; Caught = $true }, @{ New = "value=good"; Caught = $false })) {
        foreach ($piped in @($false, $true)) {
            if (-not (Test-RevertCase "exit-code piped=$piped caught=$($case.Caught)" $script $target $case.New $piped $case.Caught @{ Runner = $exitRunner; Test = "tst_fixture"; LogDir = $fx })) { $ok = $false }
        }
    }
    # RUY-657: -Mode docs / vmchecks / vmlint take the verdict from the child's failure ("FAILED: ..." from the stand-in).
    $docsRunner = { if ((Get-Content -Raw -LiteralPath $target) -match 'value=bad') { "    FAILED: fixture lint"; "FAILED: fixture lint" } else { "ALL GREEN (docs)" } }.GetNewClosure()
    foreach ($mode in @("docs", "vmchecks", "vmlint")) {
        foreach ($case in @(@{ New = "value=bad"; Caught = $true }, @{ New = "value=good"; Caught = $false })) {
            foreach ($piped in @($false, $true)) {
                if (-not (Test-RevertCase "mode=$mode piped=$piped caught=$($case.Caught)" $script $target $case.New $piped $case.Caught @{ Mode = $mode; Runner = $docsRunner })) { $ok = $false }
            }
        }
    }
    # RUY-1203: a child that dies on a terminating error (the RUY-994 case) leaves no Totals or FAILED line and does
    # not return; it is CAUGHT, says "child aborted" and exits 0, in every mode; the same child with nothing to
    # throw about is NOT CAUGHT.
    $throwRunner = { if ((Get-Content -Raw -LiteralPath $target) -match 'value=bad') { throw "fixture child died (FAILED: cmake)" } else { "ALL GREEN" } }.GetNewClosure()
    foreach ($mode in @("default", "docs", "vmchecks", "vmlint")) {
        foreach ($case in @(@{ New = "value=bad"; Caught = $true }, @{ New = "value=good"; Caught = $false })) {
            foreach ($piped in @($false, $true)) {
                if (-not (Test-RevertCase "aborted child mode=$mode piped=$piped caught=$($case.Caught)" $script $target $case.New $piped $case.Caught @{ Mode = $mode; Runner = $throwRunner; Test = "tst_fixture"; LogDir = $fx } 'child aborted: fixture child died')) { $ok = $false }
            }
        }
    }
    # The Rust mode also judges an aborted child before its "no test matched" heuristic (no result lines, no
    # "error:" in the text, which was exit 2): a copy of the script in a fixture checkout (its own .git and
    # services\<crate>\) takes the stand-in runner through the Rust verdict path.
    $rustRepo = Join-Path $fx "rust-checkout"
    New-Item -ItemType Directory -Path (Join-Path $rustRepo "scripts"), (Join-Path $rustRepo "services\fixturecrate") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $rustRepo ".git") -Value "gitdir: elsewhere"
    Copy-Item -LiteralPath $script -Destination (Join-Path $rustRepo "scripts\revert-check.ps1")
    $rustTarget = Join-Path $rustRepo "services\fixturecrate\lib.rs"
    [IO.File]::WriteAllText($rustTarget, "value=good`n")
    $rustThrow = { if ((Get-Content -Raw -LiteralPath $rustTarget) -match 'value=bad') { throw "fixture cargo died" } else { "test result: ok. 1 passed; 0 failed" } }.GetNewClosure()
    foreach ($case in @(@{ New = "value=bad"; Caught = $true }, @{ New = "value=good"; Caught = $false })) {
        if (-not (Test-RevertCase "aborted child, rust mode caught=$($case.Caught)" (Join-Path $rustRepo "scripts\revert-check.ps1") $rustTarget $case.New $false $case.Caught @{ Runner = $rustThrow; Test = "fixture_test" } 'child aborted: fixture cargo died')) { $ok = $false }
    }
    # RUY-765: a relative -File resolves against the current location; one that is not there is refused and
    # never created in this checkout; a file in another checkout (a worktree) is refused, unchanged.
    Push-Location $fx
    try {
        $lines = @(& $script -File "target.txt" -Old "value=good" -New "value=bad" -Runner $runner -Test tst_fixture -LogDir $fx *>&1 | Out-String -Stream)
        if ($LASTEXITCODE -ne 0 -or (Get-Content -Raw -LiteralPath $target) -ne "value=good`n") { $ok = $false; Write-Host "    relative -File: exit $LASTEXITCODE, output:`n$($lines -join "`n")" -ForegroundColor Yellow }
        $ghost = "ruya-revert-ghost-" + [guid]::NewGuid().ToString("N") + ".qml"
        $null = & $script -File $ghost -Old "a" -New "b" -Runner $runner *>&1 | Out-String
        $code = $LASTEXITCODE
        if ($code -ne 2 -or (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $ghost)) -or (Test-Path -LiteralPath (Join-Path $fx $ghost))) { $ok = $false; Write-Host "    missing relative -File: exit $code (want 2) or a file was created" -ForegroundColor Yellow }
    } finally { Pop-Location }
    $other = Join-Path $fx "other-checkout"
    New-Item -ItemType Directory -Path $other | Out-Null
    Set-Content -LiteralPath (Join-Path $other ".git") -Value "gitdir: elsewhere"
    $otherFile = Join-Path $other "target.txt"
    [IO.File]::WriteAllText($otherFile, "value=good`n")
    $null = & $script -File $otherFile -Old "value=good" -New "value=bad" -Runner $runner *>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 2 -or (Get-Content -Raw -LiteralPath $otherFile) -ne "value=good`n") { $ok = $false; Write-Host "    file in another checkout: exit $code (want 2) or it was changed" -ForegroundColor Yellow }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Record "revert-check self-check (CAUGHT / NOT CAUGHT is the same plain and piped through Select-Object -Last 3; paths resolve against the caller, RUY-765)" $ok
}

# RUY-752: a revert-check run that is killed cannot restore its mutation in a `finally`, so the next run applies
# the pending record it left. With a stand-in -Runner the record lives beside the fixture file.
function Test-RevertCheckRestore {
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-revert-restore-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fx | Out-Null
    $target = Join-Path $fx "target.txt"
    $record = Join-Path $fx "revert-check-pending.json"
    $original = "value=good`n"
    $script = Join-Path $PSScriptRoot "revert-check.ps1"
    $ok = $true
    $writeRecord = { [IO.File]::WriteAllText($record, (@{ path = $target; bytes = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($original)) } | ConvertTo-Json -Compress)) }.GetNewClosure()
    $plain = { "Totals: 1 passed, 0 failed" }
    # A normal run leaves no record behind, whatever the verdict; the record is there while the file is mutated
    # (the stand-in "fails" a test named after what it saw, which the verdict lists).
    $seen = { if (Test-Path -LiteralPath $record) { "FAIL!  : record_present_while_mutated" } else { "FAIL!  : no_record_while_mutated" } }.GetNewClosure()
    [IO.File]::WriteAllText($target, $original)
    $lines = @(& $script -File $target -Old "value=good" -New "value=good" -Runner $seen *>&1 | Out-String -Stream)
    if (($lines -join "`n") -notmatch 'record_present_while_mutated') { $ok = $false; Write-Host "    no pending record while the file was mutated" -ForegroundColor Yellow }
    $bad = { "FAIL!  : tst_fixture::test_value()" }
    foreach ($case in @(@{ Name = "CAUGHT"; Runner = $bad; Old = "value=good" }, @{ Name = "NOT CAUGHT"; Runner = $plain; Old = "value=good" }, @{ Name = "exit 2"; Runner = $plain; Old = "value=absent" })) {
        $null = & $script -File $target -Old $case.Old -New "value=bad" -Runner $case.Runner *>&1 | Out-String
        if ((Test-Path -LiteralPath $record) -or [IO.File]::ReadAllText($target) -ne $original) { $ok = $false; Write-Host "    $($case.Name) run left a record or a changed file" -ForegroundColor Yellow }
    }
    Record "revert-check record self-check (a record is written before the mutation; CAUGHT, NOT CAUGHT and exit 2 runs leave none, RUY-752)" $ok
    # A killed run: a record, and the file still mutated. The next run restores it (also before it looks for -Old)
    # and says so.
    $ok = $true
    [IO.File]::WriteAllText($target, "value=bad`n")
    & $writeRecord
    $lines = @(& $script -File $target -Old "value=good" -New "value=bad" -Runner $bad *>&1 | Out-String -Stream)
    $text = $lines -join "`n"
    if ([IO.File]::ReadAllText($target) -ne $original -or (Test-Path -LiteralPath $record) -or $text -notmatch 'restored a mutation left by a killed revert-check run' -or $text -notmatch '(?m)^CAUGHT') {
        $ok = $false; Write-Host "    killed run: the file or the record was not restored (output:`n$text)" -ForegroundColor Yellow
    }
    Record "revert-check restore self-check (the pending record of a killed run restores the mutated file at the next start, RUY-752)" $ok
    # A record whose file is already original is only removed.
    $ok = $true
    & $writeRecord
    $lines = @(& $script -File $target -Old "value=good" -New "value=good" -Runner $plain *>&1 | Out-String -Stream)
    if ([IO.File]::ReadAllText($target) -ne $original -or (Test-Path -LiteralPath $record) -or ($lines -join "`n") -match 'restored a mutation left') {
        $ok = $false; Write-Host "    stale record: not just removed (output:`n$($lines -join "`n"))" -ForegroundColor Yellow
    }
    Record "revert-check stale record self-check (a record whose file is already original is only removed, RUY-752)" $ok
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
}

# -InputFile: one test file (the `qml` fast mode), through the runner's -input, offscreen, with its own log.
function Run-QmlTests([string]$ShotsDir, [string]$InputFile, [string[]]$ShotFiles = @()) {
    if (-not $ShotsDir -and -not $InputFile) { Run-QmlShards; return }
    # Per checkout: worktree lanes run `test` at the same time (a shared %TEMP% log collided, 2026-11-04).
    $log = Join-Path $ShellBuild "ruya-qmltest.txt"
    $only = @()
    $label = "Qt Quick tests"
    if ($InputFile) {
        $base = [IO.Path]::GetFileNameWithoutExtension($InputFile)
        $log = Join-Path $ShellBuild "ruya-qmltest-$base.txt"
        $only = @("-input", $InputFile)
        $label = "Qt Quick tests ($base only)"
    }
    if ($ShotsDir) {
        # Screenshots need a real GPU window (offscreen = software renderer, no MultiEffect).
        # Real windows depend on the desktop: keep it unlocked and don't click other windows.
        # A locked session (LogonUI running) renders nothing and stalls timers: stop at once.
        if (Test-SessionLocked) { Stop-SessionLocked; return }
        # Behaviour is gated offscreen by `test`; here only the screenshot functions run.
        $only = @(Get-ScreenshotFunctions -Only $ShotFiles)
        if ($ShotFiles.Count -gt 0) { $label = "Qt Quick tests with screenshots ($($ShotFiles -join ', ') only)" }
        New-Item -ItemType Directory -Force $ShotsDir | Out-Null
        $env:RUYA_SHOTS_DIR = $ShotsDir
        # The threaded render loop stalls animations and layout in these test windows on the dev
        # desktop (7-9 timing failures, stale frames; builders T-194/T-199/T-213, 2026-11-07): the
        # basic loop renders on the GUI thread and gave a full green run.
        $env:QSG_RENDER_LOOP = "basic"
    } else {
        # The gate runs offscreen: immune to a locked screen, OS focus changes and other
        # windows, same as CI. Logic and focus are tested; visuals are checked by `shots`.
        $env:QT_QPA_PLATFORM = "offscreen"
    }
    # -o <file>,txt: the runner's stdout is unreliable under PowerShell.
    & (Join-Path $ShellBuild "Release\tst_ruyashell.exe") -o "$log,txt" @only | Out-Null
    $code = $LASTEXITCODE
    Get-Content $log | Where-Object { $_ -match '^(FAIL|XPASS|SKIP|Totals)|failure location|QWARN|QCRITICAL' } | ForEach-Object { Write-Host "    $_" }
    # RUY-511: a screenshot function that failed with TEST WINDOW LOST ACTIVATION runs once more, alone (the
    # caller still holds the shots mutex). Any other failure is never retried and keeps the run red.
    $retryNote = $null
    if ($ShotsDir -and $code -ne 0) {
        $logLines = @(Get-Content $log)
        $lostFns = @(Get-LostActivationFailures $logLines)
        $otherFails = @($logLines | Where-Object { $_ -match '^(FAIL!|XPASS)' -and $_ -notmatch '^FAIL!.*TEST WINDOW LOST ACTIVATION' })
        if ($lostFns.Count -gt 0 -and -not (Test-SessionLocked)) {
            $notes = @(); $allPassed = $true
            foreach ($fn in $lostFns) {
                $retryLog = Join-Path $ShellBuild "ruya-qmltest-retry.txt"
                & (Join-Path $ShellBuild "Release\tst_ruyashell.exe") -o "$retryLog,txt" $fn | Out-Null
                $passed = ($LASTEXITCODE -eq 0)
                if (-not $passed) {
                    $allPassed = $false
                    $keepR = Join-Path $Repo "output\shots-logs"
                    New-Item -ItemType Directory -Force $keepR | Out-Null
                    Copy-Item -LiteralPath $retryLog -Destination (Join-Path $keepR ("ruya-qmltest-{0}-retry.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))) -ErrorAction SilentlyContinue
                }
                $notes += "$fn ($(if ($passed) { 'passed' } else { 'failed again' }))"
            }
            $retryNote = "retried after lost activation: " + ($notes -join "; ")
            if ($allPassed -and $otherFails.Count -eq 0 -and @($logLines | Where-Object { $_ -match '^Totals' }).Count -gt 0) { $code = 0 }
        }
    }
    Remove-Item Env:\RUYA_SHOTS_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\QSG_RENDER_LOOP -ErrorAction SilentlyContinue
    Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    if ($retryNote) { Write-Host "    $retryNote" }
    # A red `shots` run keeps its full log (build-win is rebuilt and overwritten): one file per run,
    # the last 5 kept (T-429).
    if ($ShotsDir -and $code -ne 0 -and (Test-Path $log)) {
        $keep = Join-Path $Repo "output\shots-logs"
        New-Item -ItemType Directory -Force $keep | Out-Null
        $saved = Join-Path $keep ("ruya-qmltest-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        Copy-Item -LiteralPath $log -Destination $saved
        Get-ChildItem $keep -Filter "ruya-qmltest-*.txt" | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item
        Write-Host "    red run: full log kept in $saved"
    }
    # A run that failed while the desktop is locked says so too; the failures above stay visible,
    # since LogonUI can also belong to another session or a lock that came after a real failure.
    if ($ShotsDir -and $code -ne 0 -and (Test-SessionLocked)) { Stop-SessionLocked; return }
    Record $label ($code -eq 0)
}

# Half-size copies (960x540) in <dir>\review: an AI reviewer reads these instead of the full
# 1920x1080 PNGs, at about a quarter of the image tokens, for every turn they stay in context.
function Save-ReviewCopies([string]$Dir) {
    Add-Type -AssemblyName System.Drawing
    $out = Join-Path $Dir "review"
    New-Item -ItemType Directory -Force $out | Out-Null
    Remove-Item (Join-Path $out "*.png") -ErrorAction SilentlyContinue
    foreach ($f in Get-ChildItem $Dir -Filter *.png) {
        $src = [System.Drawing.Image]::FromFile($f.FullName)
        $w = [int]($src.Width / 2); $h = [int]($src.Height / 2)
        $dst = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $w, $h)
        $dst.Save((Join-Path $out $f.Name), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $dst.Dispose(); $src.Dispose()
    }
}

# The rules live in scripts\lint-tokens.ps1 (shared with CI).
function Test-Tokens {
    Step "token lint (no literal durations or colours outside Theme.qml)"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1")
    Record "token lint" ($LASTEXITCODE -eq 0)

    Step "QML member lint (no property redeclares a QQuickItem member: CI's Fedora qmllint rejects it)"
    & (Join-Path $PSScriptRoot "lint-qml-members.ps1")
    Record "QML member lint" ($LASTEXITCODE -eq 0)
    $memberFix = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-members-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force (Join-Path $memberFix "qml") | Out-Null
    [IO.File]::WriteAllText((Join-Path $memberFix "qml\Bad.qml"), "import QtQuick`nItem {`n    readonly property string state: `"x`"`n}`n")
    & (Join-Path $PSScriptRoot "lint-qml-members.ps1") -QmlDir $memberFix 6>&1 | Out-Null
    Record "QML member lint self-check (rejects a redeclared state)" ($LASTEXITCODE -ne 0)
    # T-297: a ternary inside a product in an anchor offset is rejected; the working form is accepted.
    [IO.File]::WriteAllText((Join-Path $memberFix "qml\Bad.qml"), "import QtQuick`nItem {`n    anchors.verticalCenterOffset: (flag ? -150 : 40) * u`n}`n")
    & (Join-Path $PSScriptRoot "lint-qml-members.ps1") -QmlDir $memberFix 6>&1 | Out-Null
    $offsetRejected = ($LASTEXITCODE -ne 0)
    [IO.File]::WriteAllText((Join-Path $memberFix "qml\Bad.qml"), "import QtQuick`nItem {`n    anchors.verticalCenterOffset: flag ? -150 * u : 40 * u`n}`n")
    & (Join-Path $PSScriptRoot "lint-qml-members.ps1") -QmlDir $memberFix 6>&1 | Out-Null
    Record "QML member lint self-check (rejects a ternary inside a product in an anchor offset, accepts the working form)" ($offsetRejected -and $LASTEXITCODE -eq 0)
    Remove-Item -Recurse -Force $memberFix -ErrorAction SilentlyContinue

    Step "glyph action lint (hints and glyphs name actions or positions, never letters, RUY-41)"
    & (Join-Path $PSScriptRoot "lint-glyph-actions.ps1")
    Record "glyph action lint" ($LASTEXITCODE -eq 0)
    $glyphFix = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-glyphs-" + [guid]::NewGuid().ToString("N"))
    $glyphForms = [ordered]@{
        "a button letter in a hint" = @("    readonly property var hints: [{ button: `"A`", text: qsTr(`"Select`") }]", $false)
        "two letters in a hint" = @("    readonly property var hints: [{ buttons: [`"LB`", `"RB`"], text: qsTr(`"Sections`") }]", $false)
        "a letter named as an action" = @("    readonly property var hints: [{ action: `"A`", text: qsTr(`"Select`") }]", $false)
        "a letter in an action pair" = @("    readonly property var hints: [{ actions: [`"LB`", `"tabNext`"], text: qsTr(`"Sections`") }]", $false)
        "a letter as a position" = @("    ButtonGlyph { position: `"A`" }", $false)
        "actions and positions" = @("    readonly property var hints: [{ action: `"accept`", text: qsTr(`"Select`") }, { actions: [`"tabPrev`", `"tabNext`"], text: qsTr(`"Sections`") }]`n    ButtonGlyph { position: `"south`" }", $true)
    }
    foreach ($form in $glyphForms.Keys) {
        Remove-Item -Recurse -Force $glyphFix -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $glyphFix | Out-Null
        [IO.File]::WriteAllText((Join-Path $glyphFix "Form.qml"), "import QtQuick`nItem {`n" + $glyphForms[$form][0] + "`n}`n")
        & (Join-Path $PSScriptRoot "lint-glyph-actions.ps1") -QmlDir $glyphFix 6>&1 | Out-Null
        $formOk = if ($glyphForms[$form][1]) { $LASTEXITCODE -eq 0 } else { $LASTEXITCODE -ne 0 }
        Record "glyph action lint self-check ($form)" $formOk
    }
    Remove-Item -Recurse -Force $glyphFix -ErrorAction SilentlyContinue

    Step "setting note lint (a note under a row in a Settings pane is a SettingNote, RUY-590)"
    & (Join-Path $PSScriptRoot "lint-setting-notes.ps1")
    Record "setting note lint" ($LASTEXITCODE -eq 0)
    $noteFix = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-notes-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $noteFix | Out-Null
    [IO.File]::WriteAllText((Join-Path $noteFix "BadPane.qml"), "import QtQuick`nItem {`n    Text {`n        font.pixelSize: Theme.typeCaption * u`n        wrapMode: Text.Wrap`n    }`n}`n")
    & (Join-Path $PSScriptRoot "lint-setting-notes.ps1") -QmlDir $noteFix 6>&1 | Out-Null
    Record "setting note lint self-check (rejects a raw Text note in a pane)" ($LASTEXITCODE -ne 0)
    # RUY-591: the other raw-note forms (a one-line Text, a `Text { id:` opener, Text.WordWrap) and a Text that is not a note.
    $noteForms = [ordered]@{
        "a one-line Text note" = @("    Text { font.pixelSize: Theme.typeCaption * u; wrapMode: Text.Wrap }", $false)
        "a Text { id: n opener" = @("    Text { id: n`n        font.pixelSize: Theme.typeCaption * u`n        wrapMode: Text.Wrap`n    }", $false)
        "Text.WordWrap" = @("    Text {`n        font.pixelSize: Theme.typeCaption * u`n        wrapMode: Text.WordWrap`n    }", $false)
        "a caption Text without wrapping (a glyph)" = @("    Text { font.pixelSize: Theme.typeCaption * u }", $true)
    }
    foreach ($form in $noteForms.Keys) {
        Remove-Item -Recurse -Force $noteFix -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $noteFix | Out-Null
        [IO.File]::WriteAllText((Join-Path $noteFix "FormPane.qml"), "import QtQuick`nItem {`n" + $noteForms[$form][0] + "`n}`n")
        & (Join-Path $PSScriptRoot "lint-setting-notes.ps1") -QmlDir $noteFix 6>&1 | Out-Null
        $formOk = if ($noteForms[$form][1]) { $LASTEXITCODE -eq 0 } else { $LASTEXITCODE -ne 0 }
        Record "setting note lint self-check ($form)" $formOk
    }
    Remove-Item -Recurse -Force $noteFix -ErrorAction SilentlyContinue

    Step "CI lines lint (ci.yml and ci-shell-linux.sh keep the same dnf packages and cmake flags, RUY-591)"
    & (Join-Path $PSScriptRoot "lint-ci-lines.ps1")
    Record "CI lines lint" ($LASTEXITCODE -eq 0)
    & (Join-Path $PSScriptRoot "lint-ci-lines.ps1") -SelfTest
    Record "CI lines lint self-test (equal, drifted package, drifted flag, drifted generator)" ($LASTEXITCODE -eq 0)

    # Self-check: the lint must reject a literal font size.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Set-Content -Path (Join-Path $fixture "Bad.qml") -Value 'Text { font.pixelSize: 30 * u }'
    $selfOut = & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1
    $rejected = ($LASTEXITCODE -eq 1)
    Remove-Item -Recurse -Force $fixture
    # The sample is deliberately bad: show the lint's output only when it was NOT rejected.
    if (-not $rejected) { $selfOut | ForEach-Object { Write-Host "    $_" } }
    Record "token lint self-check (rejects a literal font size)" $rejected

    # Self-check (T-209): a hard-coded colour of any spelling is rejected outside Theme.qml and the
    # theme sets, "transparent" and Theme tokens are fine, and the theme sets may hold colours.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture "themes") | Out-Null
    $bad = Join-Path $fixture "Colour.qml"
    $colourCases = @{
        "hex"        = 'Rectangle { color: "#336699" }'
        "name"       = 'Rectangle { color: "white" }'
        "single"     = "Rectangle { color: 'black' }"
        "Qt.rgba"    = 'Rectangle { color: Qt.rgba(1, 1, 1, 0.2) }'
        "Qt.hsla"    = 'Rectangle { color: Qt.hsla(0.5, 0.5, 0.5, 1) }'
    }
    $allColoursRejected = $true
    foreach ($k in $colourCases.Keys) {
        Set-Content -Path $bad -Value $colourCases[$k]
        & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
        if ($LASTEXITCODE -ne 1) { Write-Host "    lint accepted a hard-coded colour: $k" -ForegroundColor Yellow; $allColoursRejected = $false }
    }
    Set-Content -Path $bad -Value 'Rectangle { color: Theme.panel; border.color: "transparent" }'
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $tokensAccepted = ($LASTEXITCODE -eq 0)
    Remove-Item $bad
    Set-Content -Path (Join-Path (Join-Path $fixture "themes") "OneTheme.qml") -Value 'QtObject { property color background: "#05070d" }'
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $themesAccepted = ($LASTEXITCODE -eq 0)
    # A token that ThemeSet.qml declares but Themes.tokenNames forgets is a finding.
    Set-Content -Path (Join-Path (Join-Path $fixture "themes") "ThemeSet.qml") -Value "QtObject {`n    required property color background`n    required property color text`n}"
    Set-Content -Path (Join-Path (Join-Path $fixture "themes") "Themes.qml") -Value "QtObject {`n    readonly property var tokenNames: [`"background`"]`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $listRejected = ($LASTEXITCODE -eq 1)
    Set-Content -Path (Join-Path (Join-Path $fixture "themes") "Themes.qml") -Value "QtObject {`n    readonly property var tokenNames: [`"background`", `"text`"]`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $listAccepted = ($LASTEXITCODE -eq 0)
    Remove-Item -Recurse -Force $fixture
    # "themes" exempts only the directory directly under the scanned root: a root that merely has
    # "themes" somewhere in its path (a checkout in a folder called themes) is still checked.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-" + [guid]::NewGuid().ToString("N"))
    $inner = Join-Path (Join-Path $fixture "themes") "app"
    New-Item -ItemType Directory -Path $inner | Out-Null
    Set-Content -Path (Join-Path $inner "Colour.qml") -Value 'Rectangle { color: "#336699" }'
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $inner 6>&1 | Out-Null
    $pathThemesRejected = ($LASTEXITCODE -eq 1)
    Remove-Item -Recurse -Force $fixture
    Record "token lint self-check (a root with 'themes' in its path is not exempt)" $pathThemesRejected
    Record "token lint self-check (rejects a hard-coded colour: hex, name, Qt.rgba, Qt.hsla; accepts tokens, transparent and the theme sets)" ($allColoursRejected -and $tokensAccepted -and $themesAccepted)
    Record "token lint self-check (ThemeSet.qml and Themes.tokenNames must agree)" ($listRejected -and $listAccepted)

    # Self-check: the lint must reject a type step without a weight, and accept one with it.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $bad = Join-Path $fixture "NoWeight.qml"
    Set-Content -Path $bad -Value "Item {`n    Text {`n        font.pixelSize: Theme.typeTitle * u`n    }`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $rejectedW = ($LASTEXITCODE -eq 1)
    Set-Content -Path $bad -Value "Item {`n    Text {`n        font.pixelSize: Theme.typeTitle * u`n        font.weight: Theme.weightDemiBold`n    }`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $acceptedW = ($LASTEXITCODE -eq 0)
    # The weight must belong to the Text itself: not a child item's, not a comment's; and a
    # pixelSize whose Theme.type* is on the next line is still checked.
    $cases = @{
        "nested child"   = "Item {`n    Text {`n        font.pixelSize: Theme.typeTitle * u`n        Item { font.weight: Theme.weightDemiBold }`n    }`n}"
        "line comment"   = "Item {`n    Text {`n        font.pixelSize: Theme.typeTitle * u`n        // font.weight: Theme.weightDemiBold`n    }`n}"
        "block comment"  = "Item {`n    Text {`n        font.pixelSize: Theme.typeTitle * u`n        /* font.weight: Theme.weightDemiBold */`n    }`n}"
        "two-line size"  = "Item {`n    Text {`n        font.pixelSize:`n            Theme.typeTitle * u`n    }`n}"
    }
    $allRejected = $true
    foreach ($k in $cases.Keys) {
        Set-Content -Path $bad -Value $cases[$k]
        & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
        if ($LASTEXITCODE -ne 1) { Write-Host "    lint accepted: $k" -ForegroundColor Yellow; $allRejected = $false }
    }
    # A two-line size with its own weight is fine.
    Set-Content -Path $bad -Value "Item {`n    Text {`n        font.pixelSize:`n            Theme.typeTitle * u`n        font.weight: Theme.weightDemiBold`n    }`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $acceptedTwoLine = ($LASTEXITCODE -eq 0)
    # Capitals come from CapsText (the UI language), never from the font (RUY-804).
    Set-Content -Path $bad -Value "Item {`n    Text {`n        font.capitalization: Font.AllUppercase`n    }`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $rejectedCaps = ($LASTEXITCODE -eq 1)
    # Capitals come from CapsText, so a plain .toUpperCase( is refused too, unless it carries token-ok.
    Set-Content -Path $bad -Value "Item {`n    Text {`n        text: name.toUpperCase()`n    }`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $rejectedUpper = ($LASTEXITCODE -eq 1)
    Set-Content -Path $bad -Value "Item {`n    Text {`n        text: id.toUpperCase()  // token-ok: an id`n    }`n}"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1") -QmlDir $fixture 6>&1 | Out-Null
    $acceptedUpperId = ($LASTEXITCODE -eq 0)
    Remove-Item -Recurse -Force $fixture
    Record "token lint self-check (rejects a type step without font.weight)" ($rejectedW -and $acceptedW)
    Record "token lint self-check (weight in a child or comment, or a two-line size, is still rejected)" ($allRejected -and $acceptedTwoLine)
    Record "token lint self-check (rejects Font.AllUppercase and .toUpperCase(: capitals come from CapsText; token-ok exempts an id)" ($rejectedCaps -and $rejectedUpper -and $acceptedUpperId)
}

# The lupdate project (source list for lupdate) is written by the build's lupdate target, which
# also rewrites the tracked .ts files, so `dev.ps1` makes the project itself: from the configure-time
# <name>.Release.cmake, the same script that target runs. It is regenerated when missing (fresh
# worktree), empty (a full disk left 0 bytes) or older than shell\CMakeLists.txt (a merge added a
# source file). The configure that
# refreshes the Release.cmake happens first, explicitly, in the same case.
function Update-LUpdateProject {
    $dir = Join-Path $ShellBuild ".lupdate"
    $json = Join-Path $dir "ruya-shell_lupdate_project.json"
    $in = Join-Path $dir "ruya-shell_lupdate_project.Release.cmake"
    $cml = Join-Path $Repo "shell\CMakeLists.txt"
    # RUY-994: a build that ran out of disk leaves a 0-byte json or .Release.cmake with a fresh time: empty is stale.
    $stale = (-not (Test-Path $json)) -or (-not (Test-Path $in)) -or ((Get-Item $json).Length -eq 0) -or ((Get-Item $in).Length -eq 0) -or ((Get-Item $cml).LastWriteTime -gt (Get-Item $json).LastWriteTime)
    if (-not $stale) { return $json }
    if ((Test-Path (Join-Path $ShellBuild "CMakeCache.txt")) -and ((-not (Test-Path $in)) -or (Get-Item $in).Length -eq 0 -or (Get-Item $cml).LastWriteTime -gt (Get-Item $in).LastWriteTime)) {
        & $script:CMake -S (Join-Path $Repo "shell") -B $ShellBuild | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "    CMake reconfigure failed (exit $LASTEXITCODE)" -ForegroundColor Red; return $json }
    }
    $gen = Join-Path $QtDir "lib\cmake\Qt6LinguistTools\GenerateLUpdateProject.cmake"
    & $script:CMake "-DIN_FILE=$($in -replace '\\','/')" "-DOUT_FILE=$($json -replace '\\','/')" -P $gen | Out-Null
    # Touch only on success: a stale json with a fresh time would never be regenerated.
    if ($LASTEXITCODE -ne 0) { Write-Host "    lupdate project generation failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    elseif (Test-Path $json) { (Get-Item $json).LastWriteTime = Get-Date }
    return $json
}

# RUY-994: Update-LUpdateProject on a scratch build folder with a stand-in cmake (no Qt, no real build): a
# 0-byte json is regenerated, a 0-byte .Release.cmake also triggers the reconfigure, a good pair is left alone.
function Test-LUpdateProjectSelfCheck {
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lupdate-" + [guid]::NewGuid().ToString("N"))
    $Repo = $fx; $ShellBuild = Join-Path $fx "shell\build-win"; $QtDir = Join-Path $fx "qt"    # the callee sees these (dynamic scope)
    $dir = Join-Path $ShellBuild ".lupdate"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $fx "shell\CMakeLists.txt") -Value "x"
    Set-Content -LiteralPath (Join-Path $ShellBuild "CMakeCache.txt") -Value "x"
    $json = Join-Path $dir "ruya-shell_lupdate_project.json"
    $in = Join-Path $dir "ruya-shell_lupdate_project.Release.cmake"
    $calls = Join-Path $fx "calls.txt"
    $saved = $script:CMake
    # The stand-in writes what the real calls write: -B reconfigures the .Release.cmake, -P the json.
    $script:CMake = {
        if ($args -contains "-B") { Add-Content -LiteralPath $calls "configure"; Set-Content -LiteralPath $in -Value "cfg" }
        else { Add-Content -LiteralPath $calls "generate"; Set-Content -LiteralPath $json -Value "{}" }
        $global:LASTEXITCODE = 0
    }.GetNewClosure()
    try {
        $later = (Get-Date).AddMinutes(10)
        $cases = @(
            @{ Name = "0-byte json"; Json = ""; In = "cfg"; Calls = "generate" },
            @{ Name = "0-byte .Release.cmake"; Json = "{}"; In = ""; Calls = "configure,generate" },
            @{ Name = "good pair"; Json = "{}"; In = "cfg"; Calls = "" })
        $ok = $true
        foreach ($c in $cases) {
            Remove-Item -LiteralPath $calls -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText($json, $c.Json); [IO.File]::WriteAllText($in, $c.In)
            foreach ($f in $json, $in) { (Get-Item $f).LastWriteTime = $later }    # newer than CMakeLists.txt: only the size says stale
            $null = Update-LUpdateProject
            $got = if (Test-Path $calls) { (Get-Content -LiteralPath $calls) -join "," } else { "" }
            if ($got -ne $c.Calls) { $ok = $false; Write-Host "    $($c.Name): ran '$got', wanted '$($c.Calls)'" -ForegroundColor Yellow }
            if ($c.Json -eq "" -and (Get-Item $json).Length -eq 0) { $ok = $false; Write-Host "    $($c.Name): json still empty" -ForegroundColor Yellow }
        }
    } finally {
        $script:CMake = $saved
        Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    }
    Record "lupdate project self-check (a 0-byte json is regenerated, a 0-byte .Release.cmake is reconfigured first, a good pair is left alone)" $ok
}

# The rules live in scripts\lint-translations.ps1 (shared with CI).
function Test-Translations {
    Step "translation lint (shell\i18n is current with the sources and complete)"
    $project = Update-LUpdateProject
    & (Join-Path $PSScriptRoot "lint-translations.ps1") -LUpdateProject $project
    Record "translation lint" ($LASTEXITCODE -eq 0)
}

# RUY-1182: the self-check needs no lupdate, so it runs with the script self-checks (Test-ScriptSelfChecks).
function Test-TranslationSelfCheck {
    Step "translation lint self-check"
    & (Join-Path $PSScriptRoot "lint-translations.ps1") -SelfCheck
    Record "translation lint self-check (a translated pad button name is rejected)" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-text.ps1 (shared with CI).
function Test-Text {
    Step "text lint (tracked files are UTF-8, no stray control characters)"
    & (Join-Path $PSScriptRoot "lint-text.ps1")
    Record "text lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-boot.ps1 (shared with CI): the boot experience sources (T-269).
function Test-Boot {
    Step "boot lint (silent kernel arguments, Plymouth theme, GRUB menu policy, splash handover)"
    & (Join-Path $PSScriptRoot "lint-boot.ps1")
    Record "boot lint" ($LASTEXITCODE -eq 0)

    # Self-check: each mistake below, made in a copy of image/, must be reported.
    $lint = Join-Path $PSScriptRoot "lint-boot.ps1"
    $cases = @(
        @{ Name = "a missing silent argument"; File = "rootfs/usr/lib/bootc/kargs.d/10-ruyaos.toml"; From = '"quiet", '; To = "" },
        @{ Name = "the old loglevel"; File = "rootfs/usr/lib/bootc/kargs.d/10-ruyaos.toml"; From = "loglevel=0"; To = "loglevel=3" },
        @{ Name = "a theme image that is not there"; File = "rootfs/usr/share/plymouth/themes/ruyaos/ruyaos.script"; From = 'Image("glow.png")'; To = 'Image("nothere.png")' },
        @{ Name = "a visible boot menu"; File = "rootfs/usr/lib/bootupd/grub2-static/configs.d/07_ruyaos-menu.cfg"; From = "set timeout_style=hidden"; To = "set timeout_style=menu" },
        @{ Name = "a shell that does not wait for Plymouth to quit"; File = "rootfs/usr/lib/systemd/system/ruya-compositor@.service"; From = "After=systemd-user-sessions.service plymouth-quit-wait.service"; To = "After=systemd-user-sessions.service" },
        @{ Name = "a shell without its watchdog"; File = "rootfs/usr/lib/systemd/system/ruya-compositor@.service"; From = "WatchdogSec=30s"; To = "WatchdogSec=0" },
        @{ Name = "a watchdog that ignores the shell's pings"; File = "rootfs/usr/lib/systemd/system/ruya-compositor@.service"; From = "NotifyAccess=main"; To = "NotifyAccess=none" },
        @{ Name = "a stopped shell left for the 90 s stop timeout"; File = "rootfs/usr/lib/systemd/system/ruya-compositor@.service"; From = "TimeoutAbortSec=10s"; To = "" },
        @{ Name = "a splash that is cleared on quit"; File = "rootfs/usr/lib/systemd/system/plymouth-quit.service.d/10-ruyaos.conf"; From = " --retain-splash"; To = "" },
        @{ Name = "a zero menu timeout"; File = "rootfs/usr/lib/bootupd/grub2-static/configs.d/07_ruyaos-menu.cfg"; From = "set timeout=2"; To = "set timeout=0" },
        @{ Name = "the boot_counter branch removed"; File = "rootfs/usr/lib/ruyaos/grub-menu-custom.cfg"; From = 'if [ -n "${boot_counter}" ]; then'; To = 'if [ -n "${boot_counter_gone}" ]; then' }
    )
    foreach ($c in $cases) {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-boot-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force (Join-Path $fixture "image") | Out-Null
        Copy-Item -Recurse -Path (Join-Path $Repo "image\*") -Destination (Join-Path $fixture "image") -Exclude "bib"
        $target = Join-Path $fixture ("image/" + $c.File)
        $text = [IO.File]::ReadAllText($target)
        if (-not $text.Contains($c.From)) { Record ("boot lint self-check: fixture for " + $c.Name) $false; Remove-Item -Recurse -Force $fixture; continue }
        [IO.File]::WriteAllText($target, $text.Replace($c.From, $c.To))
        & $lint -Root $fixture 6>&1 | Out-Null
        Record ("boot lint reports " + $c.Name) ($LASTEXITCODE -eq 1)
        Remove-Item -Recurse -Force $fixture
    }
}

# The rules live in scripts\lint-bus-policies.ps1 (shared with CI); -SelfTest proves each rule refuses its fixture (T-423).
function Test-BusPolicies {
    Step "bus policy lint (deny-by-default, allow only root/ruya-shell/ruya-link per method)"
    & (Join-Path $PSScriptRoot "lint-bus-policies.ps1") -SelfTest
    Record "bus policy lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-ids.ps1 (shared with CI): profile user names are built only by ruya-ids (RUY-1021).
function Test-Ids {
    Step "profile id lint (no hand-built ruya-<id> user name outside services/ruya-ids)"
    & (Join-Path $PSScriptRoot "lint-ids.ps1")
    Record "profile id lint" ($LASTEXITCODE -eq 0)
    & (Join-Path $PSScriptRoot "lint-ids.ps1") -SelfTest
    Record "profile id lint self-test (a hit, a marked line, a test module, tests.rs, ruya-ids)" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-regex-anchors.ps1 (shared with CI): whole-string regexes use anchoredPattern (RUY-709).
function Test-RegexAnchors {
    Step "regex anchor lint (no bare ^...$ pattern in shell C++; anchoredPattern instead)"
    & (Join-Path $PSScriptRoot "lint-regex-anchors.ps1")
    Record "regex anchor lint" ($LASTEXITCODE -eq 0)
    & (Join-Path $PSScriptRoot "lint-regex-anchors.ps1") -SelfTest
    Record "regex anchor lint self-test (a hit, a marked line, one-sided anchors)" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-app-table.ps1 (shared with CI): per-app launch behaviour is one table (RUY-1050, ADR-043).
function Test-AppTable {
    Step "app table lint (the two retired per-app files stay gone: a per-app behaviour is a key in the apps table)"
    & (Join-Path $PSScriptRoot "lint-app-table.ps1")
    Record "app table lint" ($LASTEXITCODE -eq 0)
    & (Join-Path $PSScriptRoot "lint-app-table.ps1") -SelfTest
    Record "app table lint self-test" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-vm-checks.ps1 (shared with CI): the lead-run VM check scripts (T-296).
function Test-VmChecks {
    Step "VM check lint (vm-*.sh syntax and exec bit, host tests on canned data, ISO check refusals)"
    & (Join-Path $PSScriptRoot "lint-vm-checks.ps1")
    Record "VM check lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-dev-docs.ps1 (shared with CI): the developer guide (T-214).
function Test-DevDocs {
    Step "developer guide lint (docs\developers: links, code blocks, sources)"
    & (Join-Path $PSScriptRoot "lint-dev-docs.ps1")
    Record "developer guide lint" ($LASTEXITCODE -eq 0)

    # Self-check: a clean folder is accepted; each fixture below adds one mistake the lint must report.
    $lint = Join-Path $PSScriptRoot "lint-dev-docs.ps1"
    $chapter = @'
# A

Body, see [the other](other.md#other-chapter).

```python
print(1)
```

```xml
<a><b/></a>
```

```sh
if true; then echo hi; fi
```

```json
{"a": 1}
```

## Sources

Checked 2026-11-06.
'@
    $other = "# Other chapter`n`nText.`n`n## Sources`n`nChecked 2026-11-06.`n"
    $fence = '```'
    $cases = @(
        @{ name = "a clean folder"; a = $chapter; other = $other; expect = 0; text = "" },
        @{ name = "a broken link"; a = $chapter + "`n[x](missing.md)`n"; other = $other; expect = 1; text = "broken link: missing.md" },
        @{ name = "a broken anchor"; a = $chapter + "`n[x](other.md#nowhere)`n"; other = $other; expect = 1; text = "broken anchor" },
        @{ name = "a python syntax error"; a = $chapter + "`n${fence}python`ndef f(:`n${fence}`n"; other = $other; expect = 1; text = "python block does not parse" },
        @{ name = "a shell syntax error"; a = $chapter + "`n${fence}sh`nif then fi (`n${fence}`n"; other = $other; expect = 1; text = "fails bash -n" },
        @{ name = "ill-formed xml"; a = $chapter + "`n${fence}xml`n<a><b></a>`n${fence}`n"; other = $other; expect = 1; text = "not well-formed" },
        @{ name = "invalid json"; a = $chapter + "`n${fence}json`n{`"a`": }`n${fence}`n"; other = $other; expect = 1; text = "json block does not parse" },
        @{ name = "a chapter the README does not list"; a = $chapter; other = $other; extra = "orphan.md"; expect = 1; text = "is not listed" },
        @{ name = "a chapter without a Sources footer"; a = $chapter; other = "# Other chapter`n`nText.`n"; expect = 1; text = "no '## Sources'" },
        # T-297: the `/* sample: <path> */` C block must be the sample's own code, in order.
        @{ name = "a C block that is the sample's code"; a = $chapter + "`n${fence}c`n/* sample: s/game.c */`nint main(void) {`n...`n    return 0;`n}`n${fence}`n"; other = $other;
           files = @{ "s/game.c" = "#include <stdio.h>`nint main(void) {`n    puts(`"hi`");`n    return 0;`n}`n" }; expect = 0; text = "" },
        @{ name = "a C block whose code differs from the sample file"; a = $chapter + "`n${fence}c`n/* sample: s/game.c */`nint main(void) {`n    return 1;`n}`n${fence}`n"; other = $other;
           files = @{ "s/game.c" = "#include <stdio.h>`nint main(void) {`n    puts(`"hi`");`n    return 0;`n}`n" }; expect = 1; text = "line is not in s/game.c" },
        # T-297: an AppStream example is compared with the sample's real metainfo (names and attributes, not text).
        @{ name = "an AppStream example with the sample's elements and other text"; a = $chapter + "`nThe file (``samples/s/data/x.metainfo.xml``):`n`n${fence}xml`n<component type=`"desktop-application`"><id>a</id><name>Other name</name><releases><release version=`"2`" date=`"2030-01-01`"/></releases></component>`n${fence}`n"; other = $other;
           files = @{ "samples/s/data/x.metainfo.xml" = "<component type=`"desktop-application`"><id>b</id><name>Name</name><releases><release version=`"1`" date=`"2026-11-06`"/></releases></component>`n" }; expect = 0; text = "" },
        @{ name = "an AppStream example with a renamed element"; a = $chapter + "`nThe file (``samples/s/data/x.metainfo.xml``):`n`n${fence}xml`n<component type=`"desktop-application`"><id>a</id><title>Name</title><releases><release version=`"1`" date=`"2026-11-06`"/></releases></component>`n${fence}`n"; other = $other;
           files = @{ "samples/s/data/x.metainfo.xml" = "<component type=`"desktop-application`"><id>b</id><name>Name</name><releases><release version=`"1`" date=`"2026-11-06`"/></releases></component>`n" }; expect = 1; text = "the example differs from samples/s/data/x.metainfo.xml" },
        @{ name = "an AppStream example that drops a required attribute"; a = $chapter + "`nThe file (``samples/s/data/x.metainfo.xml``):`n`n${fence}xml`n<component type=`"desktop-application`"><id>a</id><name>Name</name><releases><release version=`"1`"/></releases></component>`n${fence}`n"; other = $other;
           files = @{ "samples/s/data/x.metainfo.xml" = "<component type=`"desktop-application`"><id>b</id><name>Name</name><releases><release version=`"1`" date=`"2026-11-06`"/></releases></component>`n" }; expect = 1; text = "/component/releases/release[date,version]" }
    )
    # RUY-155: public API elements (org.ruyaos.Stability on a method, signal or property).
    $xmlHead = "<node><interface name=`"org.ruyaos.T1`">"
    $xmlTail = "</interface></node>`n"
    $pub = { param($ann) $xmlHead + "<method name=`"Do`">$ann</method><method name=`"Hidden`"/>" + $xmlTail }
    $stabOk = "<annotation name=`"org.ruyaos.Stability`" value=`"experimental`"/>"
    $sinceOk = "<annotation name=`"org.ruyaos.Since`" value=`"1`"/>"
    $spanDo = "`nUse ``org.ruyaos.T1.Do`` to do it.`n"
    $cases += @(
        @{ name = "a tagged and documented API element"; a = $chapter + $spanDo; other = $other;
           files = @{ "api/dbus/t1.xml" = (& $pub ($stabOk + $sinceOk)) }; expect = 0; text = "" },
        @{ name = "a tagged API element no chapter documents"; a = $chapter; other = $other;
           files = @{ "api/dbus/t1.xml" = (& $pub ($stabOk + $sinceOk)) }; expect = 1; text = "org.ruyaos.T1.Do is public but no chapter" },
        @{ name = "a bad Stability value"; a = $chapter + $spanDo; other = $other;
           files = @{ "api/dbus/t1.xml" = (& $pub ("<annotation name=`"org.ruyaos.Stability`" value=`"beta`"/>" + $sinceOk)) }; expect = 1; text = "org.ruyaos.T1.Do has org.ruyaos.Stability 'beta'" },
        @{ name = "a tagged element without Since"; a = $chapter + $spanDo; other = $other;
           files = @{ "api/dbus/t1.xml" = (& $pub $stabOk) }; expect = 1; text = "org.ruyaos.T1.Do has no integer org.ruyaos.Since" },
        @{ name = "a Since that is not an integer"; a = $chapter + $spanDo; other = $other;
           files = @{ "api/dbus/t1.xml" = (& $pub ($stabOk + "<annotation name=`"org.ruyaos.Since`" value=`"one`"/>")) }; expect = 1; text = "org.ruyaos.T1.Do has no integer org.ruyaos.Since" },
        @{ name = "an untagged element and an interface-level tag (private)"; a = $chapter; other = $other;
           files = @{ "api/dbus/t1.xml" = ($xmlHead + $stabOk + "<method name=`"Do`"/>" + $xmlTail) }; expect = 0; text = "" }
    )
    # RUY-467: an api/dbus file must be well-formed; "--" inside a comment is not.
    $cases += @(
        @{ name = "an api/dbus file with -- inside a comment"; a = $chapter; other = $other;
           files = @{ "api/dbus/t2.xml" = ($xmlHead + "<!-- runs ruya-devices --display-guard -->" + $xmlTail) }; expect = 1; text = "api/dbus/t2.xml: is not well-formed xml (line 1)" }
    )
    # RUY-105: a json block that is a whole play.json must satisfy api/play/play.schema.json.
    $playSchema = '{"type":"object","required":["format","id","run"],"additionalProperties":true,"properties":{"format":{"const":1},"id":{"type":"string","pattern":"^[a-z]+(\\.[a-z]+){2,}$"},"build":{"$ref":"#/$defs/build"},"run":{"type":"object","additionalProperties":false,"required":["runner"],"properties":{"runner":{"enum":["native","wine"]}}}},"$defs":{"build":{"type":"integer","minimum":1}}}'
    $runnerSchema = '{"type":"object","additionalProperties":false,"required":["format","family","kind"],"properties":{"format":{"const":1},"family":{"type":"string"},"kind":{"enum":["wine","proton"]}}}'
    $manifestBlock = { param($m) $chapter + "`n${fence}json`n$m`n${fence}`n" }
    $cases += @(
        @{ name = "a play.json block that satisfies the schema"; a = (& $manifestBlock '{"format":1,"id":"com.example.game","build":3,"run":{"runner":"wine"}}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 0; text = "" },
        @{ name = "a play.json block below a minimum"; a = (& $manifestBlock '{"format":1,"id":"com.example.game","build":0,"run":{"runner":"wine"}}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 1; text = "play.json block does not satisfy play.schema.json: /build: below 1" },
        @{ name = "a play.json block with a value outside an enum"; a = (& $manifestBlock '{"format":1,"id":"com.example.game","run":{"runner":"dos"}}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 1; text = "/run/runner: not one of the allowed values" },
        @{ name = "a play.json block with an unknown key in a strict object"; a = (& $manifestBlock '{"format":1,"id":"com.example.game","run":{"runner":"wine","extra":true}}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 1; text = "/run/extra: false schema" },
        @{ name = "a play.json block that fails a pattern"; a = (& $manifestBlock '{"format":1,"id":"Game","run":{"runner":"wine"}}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 1; text = "/id: does not match" },
        @{ name = "a play.json block with a fractional integer"; a = (& $manifestBlock '{"format":1,"id":"com.example.game","build":1.5,"run":{"runner":"wine"}}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 1; text = "/build: not a integer" },
        @{ name = "a json block that is not a play.json is only parsed"; a = (& $manifestBlock '{"format":1,"other":true}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema }; expect = 0; text = "" },
        # RUY-898: a whole runner.json (format, family and kind) is checked against its own schema.
        @{ name = "a runner.json block that satisfies its schema"; a = (& $manifestBlock '{"format":1,"family":"wine","kind":"wine"}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema; "api/play/runner.schema.json" = $runnerSchema }; expect = 0; text = "" },
        @{ name = "a runner.json block with a kind outside the enum"; a = (& $manifestBlock '{"format":1,"family":"wine","kind":"native"}'); other = $other;
           files = @{ "api/play/play.schema.json" = $playSchema; "api/play/runner.schema.json" = $runnerSchema }; expect = 1; text = "runner.json block does not satisfy runner.schema.json: /kind: not one of the allowed values" }
    )
    # RUY-36: a sample's `# sample: <path>` python block is the sample's own code, like the C block.
    $pySample = "import os`ndef pick(root):`n    return None`n"
    $cases += @(
        @{ name = "a python block that is the sample's code"; a = $chapter + "`n${fence}python`n# sample: s/run.py`ndef pick(root):`n    # ...`n    return None`n${fence}`n"; other = $other;
           files = @{ "s/run.py" = $pySample }; expect = 0; text = "" },
        @{ name = "a python block whose code differs from the sample file"; a = $chapter + "`n${fence}python`n# sample: s/run.py`ndef pick(root):`n    return 1`n${fence}`n"; other = $other;
           files = @{ "s/run.py" = $pySample }; expect = 1; text = "line is not in s/run.py" }
    )
    # RUY-36: a sample Flatpak manifest that names the console's runner point must match the image
    # (the point and branch of commit.rs, the runner folders of image/play/runners/).
    $commitFx = "pub const PLAY_EXTENSION_BRANCH: &str = `"1`";`npub const RUNNER_EXTENSION: &str = `"org.ruyaos.Play.Runner`";`n"
    $runnerFx = "image/play/runners/ProtonGE11/runner.json"
    $manifestFx = { param($id, $keys) "{`"app-id`":`"org.example.App`",`"add-extensions`":{`"$id`":{`"directory`":`"runners`",$keys}}}`n" }
    $goodKeys = "`"version`":`"1`",`"subdirectories`":true,`"no-autodownload`":true"
    $runnerFiles = { param($manifest) @{ "services/ruya-play/src/service/commit.rs" = $commitFx; $runnerFx = "{}"; "samples/s/app.json" = $manifest } }
    $cases += @(
        @{ name = "a sample manifest with the runner point"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner" $goodKeys)); expect = 0; text = "" },
        @{ name = "a sample manifest with one runner id of the image"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner.ProtonGE11" "`"version`":`"1`",`"no-autodownload`":true")); expect = 0; text = "" },
        @{ name = "a sample manifest whose runner id is changed"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner.ProtonGE99" "`"version`":`"1`",`"no-autodownload`":true")); expect = 1; text = "names a runner that is not in image/play/runners/" },
        @{ name = "a sample manifest whose runner point is misspelled"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runnr" $goodKeys)); expect = 1; text = "neither org.ruyaos.Play.Runner nor one of its ids" },
        @{ name = "a sample manifest whose runner point has another branch"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner" "`"version`":`"2`",`"subdirectories`":true,`"no-autodownload`":true")); expect = 1; text = "the image's branch is '1'" },
        @{ name = "a sample manifest whose runner point mounts no subdirectories"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner" "`"version`":`"1`",`"no-autodownload`":true")); expect = 1; text = "must set subdirectories to true" },
        @{ name = "a sample manifest that would download the runner"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner" "`"version`":`"1`",`"subdirectories`":true")); expect = 1; text = "must set no-autodownload to true" },
        # RUY-36 round 2: the extensions of other vendors are not checked, a pinned id is one runner
        # (no subdirectories), and only an org.ruyaos.* extension makes a manifest a runner sample.
        @{ name = "a sample manifest with the runner point and an unrelated extension"; a = $chapter; other = $other;
           files = (& $runnerFiles ("{`"app-id`":`"org.example.App`",`"add-extensions`":{`"org.ruyaos.Play.Runner`":{`"directory`":`"runners`",$goodKeys},`"org.freedesktop.Platform.Compat.i386`":{`"directory`":`"lib/i386-linux-gnu`",`"version`":`"26.08`"}}}`n")); expect = 0; text = "" },
        @{ name = "a sample manifest with a pinned runner id that sets subdirectories"; a = $chapter; other = $other;
           files = (& $runnerFiles (& $manifestFx "org.ruyaos.Play.Runner.ProtonGE11" $goodKeys)); expect = 1; text = "is one runner and must not set subdirectories" },
        @{ name = "a sample manifest that only names the console's id in its app-id"; a = $chapter; other = $other;
           files = (& $runnerFiles "{`"app-id`":`"org.ruyaos.Play.Runner.Tool`",`"command`":`"x`"}`n"); expect = 0; text = "" }
    )
    # RUY-656: apis.json carries the normalised argument signature of each element.
    $sigXml = $xmlHead + "<method name=`"Do`"><arg name=`"a`" type=`"s`" direction=`"in`"/><arg name=`"b`" type=`"i`"/><arg name=`"r`" type=`"b`" direction=`"out`"/>$stabOk$sinceOk</method>" +
        "<signal name=`"Sig`"><arg name=`"x`" type=`"s`"/><arg name=`"y`" type=`"u`"/>$stabOk$sinceOk</signal>" +
        "<property name=`"Prop`" type=`"as`" access=`"read`">$stabOk$sinceOk</property>" + $xmlTail
    $cases += @(
        @{ name = "apis.json carries method, signal and property signatures"; a = $chapter + "`n``org.ruyaos.T1.Do`` ``org.ruyaos.T1.Sig`` ``org.ruyaos.T1.Prop``.`n"; other = $other;
           files = @{ "api/dbus/t1.xml" = $sigXml }; expect = 0; text = "";
           sigs = @{ "Do" = "in:a:s,b:i;out:r:b"; "Sig" = "x:s,y:u"; "Prop" = "as:read" } }
    )
    foreach ($c in $cases) {
        $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-devdocs-fx-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $fx | Out-Null
        [IO.File]::WriteAllText((Join-Path $fx "README.md"), "# Guide`n`n| Chapter |`n|---|`n| [A](a.md) |`n| [Other](other.md) |`n")
        [IO.File]::WriteAllText((Join-Path $fx "a.md"), $c.a)
        [IO.File]::WriteAllText((Join-Path $fx "other.md"), $c.other)
        if ($c.extra) { [IO.File]::WriteAllText((Join-Path $fx $c.extra), $other) }
        if ($c.files) {
            foreach ($rel in $c.files.Keys) {
                $dest = Join-Path $fx ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
                New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
                [IO.File]::WriteAllText($dest, $c.files[$rel])
            }
        }
        $out = & $lint -Dir $fx -Repo $fx *>&1 | Out-String
        $code = $LASTEXITCODE
        $sigOk = $true
        if ($c.sigs) {
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($x in (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $fx "output\apis.json"))))) { $list.Add($x) }
            foreach ($k in $c.sigs.Keys) {
                $e = $list | Where-Object { $_.member -eq $k }
                if (-not $e -or $e.signature -ne $c.sigs[$k]) { $sigOk = $false; Write-Host "    signature of $k is '$($e.signature)', expected '$($c.sigs[$k])'" }
            }
        }
        Remove-Item -Recurse -Force $fx
        $ok = ($code -eq $c.expect) -and $out.Contains($c.text) -and $sigOk
        if (-not $ok) { Write-Host $out }
        Record "developer guide lint self-check ($($c.name): $(if ($c.expect -eq 0) { 'accepted' } else { 'rejected' }))" $ok
    }

    # RUY-158: -Samples -SkipSample leaves a sample out and says so; without it the same sample
    # (a Makefile whose test cannot pass) is a finding, whether make is installed or not.
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-devdocs-fx-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force (Join-Path $fx "samples\s") | Out-Null
    [IO.File]::WriteAllText((Join-Path $fx "README.md"), "# Guide`n`n| Chapter |`n|---|`n| [A](a.md) |`n| [Other](other.md) |`n")
    [IO.File]::WriteAllText((Join-Path $fx "a.md"), $chapter)
    [IO.File]::WriteAllText((Join-Path $fx "other.md"), $other)
    [IO.File]::WriteAllText((Join-Path $fx "samples\s\Makefile"), "test:`n`tfalse`n")
    $skipOut = & $lint -Dir $fx -Repo $fx -Samples -SkipSample s *>&1 | Out-String
    $skipCode = $LASTEXITCODE
    $runOut = & $lint -Dir $fx -Repo $fx -Samples *>&1 | Out-String
    $runCode = $LASTEXITCODE
    Remove-Item -Recurse -Force $fx
    $ok = ($skipCode -eq 0) -and $skipOut.Contains("samples/s: make test not run here (-SkipSample)") -and ($runCode -eq 1) -and $runOut.Contains("samples/s")
    if (-not $ok) { Write-Host $skipOut; Write-Host $runOut }
    Record "developer guide lint self-check (-SkipSample leaves a sample out and says so; without it the sample is run)" $ok
}

# RUY-625: scripts\api-changelog.ps1 diffs the public elements of two sets of api/dbus files.
function Test-ApiChangelog {
    Step "API changelog self-check"
    $script = Join-Path $PSScriptRoot "api-changelog.ps1"
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-apichg-" + [guid]::NewGuid().ToString("N"))
    $mk = {
        param($name, $body)
        $d = Join-Path $fx $name
        New-Item -ItemType Directory -Force $d | Out-Null
        [IO.File]::WriteAllText((Join-Path $d "t.xml"), "<node><interface name=`"org.ruyaos.T1`">$body</interface></node>`n")
        return $d
    }
    $ann = { param($s, $n) "<annotation name=`"org.ruyaos.Stability`" value=`"$s`"/><annotation name=`"org.ruyaos.Since`" value=`"$n`"/>" }
    $oldBody = "<method name=`"Keep`">" + (& $ann "experimental" 1) + "</method><method name=`"Bump`">" + (& $ann "experimental" 1) + "</method><method name=`"Old`">" + (& $ann "stable" 1) + "</method><method name=`"Gone`">" + (& $ann "stable" 1) + "</method><method name=`"Private`"/>"
    $newBody = "<method name=`"Keep`">" + (& $ann "experimental" 1) + "</method><method name=`"Bump`">" + (& $ann "experimental" 2) + "</method><method name=`"Old`">" + (& $ann "deprecated" 1) + "</method><signal name=`"Fresh`">" + (& $ann "experimental" 2) + "</signal><method name=`"Private`"/><method name=`"Private2`"/>"
    $oldDir = & $mk "old" $oldBody
    $newDir = & $mk "new" $newBody
    $out = & $script -OldApiDir $oldDir -NewApiDir $newDir *>&1 | Out-String
    $ok = $out.Contains("org.ruyaos.T1.Fresh") -and $out.Contains("### Added") -and
          $out.Contains("org.ruyaos.T1.Bump") -and $out.Contains("### Changed") -and $out.Contains("since 1 -> 2") -and
          $out.Contains("### Deprecated") -and $out.Contains("org.ruyaos.T1.Old") -and
          $out.Contains("org.ruyaos.T1.Gone") -and $out.Contains("### Removed") -and
          $out.Contains("## API level 2") -and
          -not $out.Contains("T1.Keep") -and -not $out.Contains("Private")
    if (-not $ok) { Write-Host $out }
    Record "API changelog self-check (added, changed, deprecated and removed elements are listed by level; private and unchanged are not)" $ok
    $same = & $script -OldApiDir $oldDir -NewApiDir $oldDir *>&1 | Out-String
    $okSame = $same.Trim() -eq "no public API changes"
    if (-not $okSame) { Write-Host $same }
    Record "API changelog self-check (identical sets print 'no public API changes')" $okSame
    # RUY-656: a changed argument type and a gained argument are reported with both signatures.
    $m = { param($name, $args1) "<method name=`"$name`">$args1" + (& $ann "experimental" 1) + "</method>" }
    $oldSig = & $mk "oldsig" ((& $m "Typed" "<arg name=`"a`" type=`"s`"/>") + (& $m "Gains" "<arg name=`"a`" type=`"s`"/>") + (& $m "Same" "<arg name=`"a`" type=`"s`"/>"))
    $newSig = & $mk "newsig" ((& $m "Typed" "<arg name=`"a`" type=`"i`"/>") + (& $m "Gains" "<arg name=`"a`" type=`"s`"/><arg name=`"b`" type=`"s`"/>") + (& $m "Same" "<arg name=`"a`" type=`"s`"/>"))
    $sgOut = & $script -OldApiDir $oldSig -NewApiDir $newSig *>&1 | Out-String
    $okSig = $sgOut.Contains("### Changed") -and
             $sgOut.Contains("org.ruyaos.T1.Typed") -and $sgOut.Contains("in:a:s;out:") -and $sgOut.Contains("in:a:i;out:") -and
             $sgOut.Contains("org.ruyaos.T1.Gains") -and $sgOut.Contains("in:a:s,b:s;out:") -and
             -not $sgOut.Contains("T1.Same")
    if (-not $okSig) { Write-Host $sgOut }
    Record "API changelog self-check (a changed argument type and a gained argument are Changed, with both signatures)" $okSig
    Remove-Item -Recurse -Force $fx

    # Refs: the same script reads two git refs (this repo's HEAD against itself: nothing changed).
    $head = & $script HEAD HEAD *>&1 | Out-String
    Record "API changelog self-check (the same ref twice prints 'no public API changes')" ($head.Trim() -eq "no public API changes")
}

# RUY-158: every public element of org.ruyaos.Platform1.xml has a conformance case. The public
# elements come from the apis.json that Test-DevDocs wrote (lint-dev-docs.ps1, the one parser of
# the stability tags); the cases from ruya-platform-conformance. The run against the mock needs a
# Linux session bus (scripts/conformance.sh, CI's samples job).
function Test-Conformance {
    Step "Platform conformance coverage (a case for every public Platform1 element)"
    $apis = Join-Path $Repo "output\apis.json"
    Push-Location $Services
    $runner = { param($file) cargo run -q --locked -p ruya-platform --features dev-mock --bin ruya-platform-conformance -- coverage --apis $file 2>&1 | Out-String }
    $out = & $runner $apis
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Host $out }
    Record "conformance coverage of api\dbus\org.ruyaos.Platform1.xml" ($code -eq 0)

    # Self-check: a fixture contract with one more tagged element, documented, so lint-dev-docs
    # lists it: the coverage must fail and name it.
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-conformance-fx-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force (Join-Path $fx "api\dbus") | Out-Null
    $xml = [IO.File]::ReadAllText((Join-Path $Repo "api\dbus\org.ruyaos.Platform1.xml"))
    $extra = "    <method name=`"Extra`">`n      <annotation name=`"org.ruyaos.Stability`" value=`"experimental`"/>`n      <annotation name=`"org.ruyaos.Since`" value=`"1`"/>`n    </method>`n  </interface>"
    $at = $xml.IndexOf("  </interface>")
    $xml = $xml.Substring(0, $at) + $extra + $xml.Substring($at + "  </interface>".Length)
    [IO.File]::WriteAllText((Join-Path $fx "api\dbus\org.ruyaos.Platform1.xml"), $xml)
    $names = @("Register", "SaveDone", "Background", "Resume", "Stopping", "Extra") | ForEach-Object { "``org.ruyaos.Platform1.Lifecycle.$_``" }
    [IO.File]::WriteAllText((Join-Path $fx "README.md"), "# Guide`n`n| Chapter |`n|---|`n| [A](a.md) |`n")
    [IO.File]::WriteAllText((Join-Path $fx "a.md"), "# A`n`n$($names -join ' ')`n`n## Sources`n`nChecked 2026-11-23.`n")
    & (Join-Path $PSScriptRoot "lint-dev-docs.ps1") -Dir $fx -Repo $fx *>&1 | Out-Null
    $lintCode = $LASTEXITCODE
    $out = & $runner (Join-Path $fx "output\apis.json")
    $code = $LASTEXITCODE
    Pop-Location
    Remove-Item -Recurse -Force $fx
    $ok = ($lintCode -eq 0) -and ($code -ne 0) -and $out.Contains("no conformance case for org.ruyaos.Platform1.Lifecycle.Extra")
    if (-not $ok) { Write-Host "    lint exit $lintCode, coverage exit $code"; Write-Host $out }
    Record "conformance coverage self-check (a new tagged element without a case is named)" $ok
}

# The rules live in scripts\lint-tests.ps1 (shared with CI).
function Test-QmlTests {
    Step "test lint (no key presses in unbounded loops)"
    & (Join-Path $PSScriptRoot "lint-tests.ps1")
    Record "test lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-test-members.ps1 (shared with CI). It needs the shell build's
# qmllint response file, so it runs after Do-Build.
function Test-TestMembers {
    Step "test member lint (no test reads a member QML cannot see)"
    $rspFile = Join-Path $ShellBuild ".rcc\qmllint\ruyashell.rsp"
    $lint = Join-Path $PSScriptRoot "lint-test-members.ps1"
    & $lint -RspFile $rspFile
    Record "test member lint" ($LASTEXITCODE -eq 0)

    # Self-check: the lint must reject a test that waits on a member Storage does not expose (the
    # T-184 round-1 mistake: `wait(Storage.groupWindowMs + 200)` waited nothing because QML could
    # not see the member), a wait whose timeout is NaN from a typo on the shell, and accept
    # the same test reading a member that exists.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $bad = Join-Path $fixture "tst_bad.qml"
    $head = "import QtQuick`nimport QtTest`nimport RuyaShell`nItem {`n    TestCase {`n        name: `"Fixture`"`n"
    $tail = "    }`n}`n"
    $cases = @{
        "an unexposed singleton member" = "        function test_x() { wait(Storage.noSuchWindowMs + 200) }`n"
        "a misspelled shell property" = "        property Shell shell: null`n        function test_x() { tryVerify(() => shell.currentPag === `"`") }`n"
        "a nested function (qmllint stops checking the file)" = "        function test_x() {`n            function run(id) { const s = id.status }`n            run(1)`n        }`n"
    }
    $allRejected = $true
    foreach ($k in $cases.Keys) {
        [IO.File]::WriteAllText($bad, $head + $cases[$k] + $tail, (New-Object System.Text.UTF8Encoding($false)))
        & $lint -RspFile $rspFile -TestDir $fixture 6>&1 | Out-Null
        if ($LASTEXITCODE -ne 1) { Write-Host "    lint accepted: $k" -ForegroundColor Yellow; $allRejected = $false }
    }
    # The same tests reading members that exist, and the two context properties of the test
    # engine, are clean.
    $good = "        property Shell shell: null`n        function test_x() {`n            verify(windowGuard.ensureActive() === `"`")`n            wait(Storage.groupWindowMs + 200)`n            tryVerify(() => shell.currentPage === `"`")`n            if (shotsDir) skip(`"x`")`n        }`n"
    [IO.File]::WriteAllText($bad, $head + $good + $tail, (New-Object System.Text.UTF8Encoding($false)))
    $goodOut = & $lint -RspFile $rspFile -TestDir $fixture 6>&1
    $accepted = ($LASTEXITCODE -eq 0)
    Remove-Item -Recurse -Force $fixture
    if (-not $accepted) { $goodOut | ForEach-Object { Write-Host "    $_" } }
    Record "test member lint self-check (rejects unexposed reads, accepts exposed ones)" ($allRejected -and $accepted)
}

# The rules live in scripts\lint-sound-themes.ps1 (T-227): the generator, the bundled and example
# themes and the checker's fixtures. It runs the built ruya-shell, so it comes after the build.
function Test-SoundThemes {
    Step "sound themes (generator, bundled and example theme, checker fixtures)"
    & (Join-Path $PSScriptRoot "lint-sound-themes.ps1") -Exe (Join-Path $ShellBuild "Release\ruya-shell.exe")
    Record "sound theme lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-icons.ps1 (shared with CI).
function Test-Icons {
    Step "icon lint (shell\fonts\icons.txt and the Icon.qml table agree)"
    & (Join-Path $PSScriptRoot "lint-icons.ps1")
    Record "icon lint" ($LASTEXITCODE -eq 0)
}

# Every character the shell shows must be in the bundled Inter cuts (T-145; pure Python, no packages).
function Test-FontCoverage {
    Step "font coverage (every character in shell\qml, i18n and src is in the Inter cuts)"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Host "FAIL: python is not on PATH; scripts\check-font-coverage.py needs it" -ForegroundColor Red
        Record "font coverage (python missing)" $false
        return
    }
    & $py.Source -I (Join-Path $PSScriptRoot "check-font-coverage.py") (Join-Path $PSScriptRoot "..")
    Record "font coverage" ($LASTEXITCODE -eq 0)
    # T-297: the overlap geometry on hand-made outlines (two overlapping squares flagged, two disjoint not).
    & $py.Source -I (Join-Path $PSScriptRoot "check-font-coverage.py") --self-test
    Record "font coverage self-test (overlap helper: overlapping squares flagged, disjoint ones not)" ($LASTEXITCODE -eq 0)
}

# The game settings schema (RUY-406): the sample, the mock game's file and the chapter's example pass
# api\settings\game-settings.schema.json, and the schema refuses the bad cases (pure Python, no packages).
function Test-GameSettingsSchema {
    Step "game settings schema (sample, mock game, chapter example; refusals)"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Host "FAIL: python is not on PATH; scripts\check-game-settings-schema.py needs it" -ForegroundColor Red
        Record "game settings schema (python missing)" $false
        return
    }
    & $py.Source -I (Join-Path $PSScriptRoot "check-game-settings-schema.py") (Join-Path $PSScriptRoot "..")
    Record "game settings schema" ($LASTEXITCODE -eq 0)
}

# Every QML file is named in 04-design-system.md (or on the baseline): scripts\lint-spec-components.ps1 (shared with CI).
function Test-SpecComponents {
    Step "spec lint (every shell\qml file is named in 04-design-system.md)"
    & (Join-Path $PSScriptRoot "lint-spec-components.ps1")
    Record "spec lint" ($LASTEXITCODE -eq 0)

    # Self-check: a new, unlisted component must be rejected.
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-spec-fx-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fx | Out-Null
    Set-Content -LiteralPath (Join-Path $fx "BrandNewThing.qml") -Value "import QtQuick`nItem {}" -Encoding UTF8
    & (Join-Path $PSScriptRoot "lint-spec-components.ps1") -QmlDir $fx 6>&1 | Out-Null
    $rejected = ($LASTEXITCODE -eq 1)
    Remove-Item -Recurse -Force $fx
    Record "spec lint self-check (rejects an unlisted component)" $rejected
}

# RUY-889: no new copied block of 80+ tokens in shell, services or scripts: scripts\lint-duplicates.ps1 (shared with CI).
function Test-Duplicates {
    Step "duplicate-code lint (new copied blocks fail; old ones are on the baseline)"
    & (Join-Path $PSScriptRoot "lint-duplicates.ps1")
    Record "duplicate lint" ($LASTEXITCODE -eq 0)
    & (Join-Path $PSScriptRoot "lint-duplicates.ps1") -SelfTest
    Record "duplicate lint self-check (rejects a planted copy, passes a near-copy, shrinks the baseline)" ($LASTEXITCODE -eq 0)
}

# RUY-660: the self-checks of the scripts themselves need no build, so `docs` runs them too (revert-check
# -Mode docs relies on it). Once per process: `test` (via Do-Shell) and `docs` each run them once.
function Test-ScriptSelfChecks {
    if ($script:ScriptChecksDone) { return }
    $script:ScriptChecksDone = $true
    Step "Shard runner self-check (T-463)"
    Test-QmlShardRunner
    Step "Revert check self-check (RUY-654)"
    Test-RevertCheckPiping
    Step "Revert check restore self-check (RUY-752)"
    Test-RevertCheckRestore
    Step "Shots filter and retry self-check (RUY-511)"
    Test-ShotsFilterAndRetry
    Test-QmlNameParsing
    Test-Duplicates
    Test-Ids
    Test-RegexAnchors
    Test-AppTable
    Test-TranslationSelfCheck
    Test-LUpdateProjectSelfCheck
    Test-BusPolicies
}

function Do-Shell {
    Do-Build
    Test-Tokens
    Test-Icons
    Test-SpecComponents
    Test-SoundThemes
    Test-FontCoverage
    Test-Translations
    Test-QmlTests
    Test-TestMembers
    Step "qmllint (module context)"
    # --max-warnings 0: without it qmllint exits 0 even when it reports warnings.
    # RUY-582: qmllint's Info/Warning lines go to stderr. Start-Process (no 2>&1) lets them print as they are,
    # so PowerShell 5.1 never wraps them in NativeCommandError records; the verdict is the exit code only.
    $lint = Start-Process (Get-Command qmllint).Source -ArgumentList @("--max-warnings", "0", "`"@$ShellBuild\.rcc\qmllint\ruyashell.rsp`"") -NoNewWindow -Wait -PassThru
    Record "qmllint" ($lint.ExitCode -eq 0)
    # T-462: the probe path of `shots` (a window that presents no frames stops it), without a display:
    # the window is never shown, so the probe must report "no frames" even though offscreen draws.
    Step "Display probe self-check (no frames -> asleep)"
    Record "display probe self-check (a window that presents no frames is reported)" ((Test-DisplayPresentsFrames -NoFrames -Offscreen) -eq 3)
    Test-ScriptSelfChecks
    Step "Qt Quick tests (offscreen)"
    Run-QmlTests $null
}

# Every check that reads docs\ (text lint: all tracked files;
# developer guide lint: docs\developers; spec lint: 04-design-system.md). A check that starts
# reading docs\ belongs here too: push-main.ps1 and the reviewer's round 2 run only this group
# when nothing but docs\*.md changed since a green `test`.
function Do-Docs { Test-Text; Test-DevDocs; Test-ApiChangelog; Test-SpecComponents; Test-ScriptSelfChecks }

# HEAD and whether the working tree is clean (no tracked change, no untracked file that is not ignored).
function Get-TreeState {
    $head = "$(& $Git -C $Repo rev-parse HEAD 2>$null)".Trim()
    $okHead = ($LASTEXITCODE -eq 0) -and ($head -match '^[0-9a-f]{40}$')
    $dirty = & $Git -C $Repo status --porcelain 2>$null
    $okStatus = ($LASTEXITCODE -eq 0)
    return [pscustomobject]@{ Head = $head; Clean = $okHead -and $okStatus -and (-not $dirty) }
}

function Write-GreenMarker($Before, $After) {
    $why = $null
    if (-not $Before.Clean) { $why = "the tree was not clean when the run started" }
    elseif (-not $After.Clean) { $why = "the tree changed during the run" }
    elseif ($Before.Head -ne $After.Head) { $why = "HEAD moved during the run" }
    if ($why) { Write-Host "    no green marker: $why (push-main.ps1 will run test itself)"; return }
    New-Item -ItemType Directory -Force (Split-Path -Parent $GreenMarker) | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    [IO.File]::WriteAllText($GreenMarker, "commit $($After.Head)`ntime $stamp`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host "    green marker: $($After.Head) ($GreenMarker)"
}

# RUY-725: the one place that turns the test names of `qml` and `shots` into a flat list. PowerShell passes
# `a,b` as ONE array argument, so an element can itself be an array: flatten before splitting on commas.
function ConvertTo-TestNames($Raw) {
    $out = @()
    foreach ($item in @($Raw)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) { $out += @(ConvertTo-TestNames @($item)) }
        else { foreach ($p in ("$item" -split ',')) { if ($p.Trim()) { $out += $p.Trim() } } }
    }
    return $out
}

# shell\tests\<name>.qml for each name; an unknown name is a failure, not a silent skip.
# -NoRecord (the self-check): an unknown name comes back as "unknown:<base>" and records nothing.
function Resolve-QmlTestFiles([string[]]$Names, [string]$Dir = (Join-Path $Repo "shell\tests"), [switch]$NoRecord) {
    $files = @()
    foreach ($n in $Names) {
        $base = [IO.Path]::GetFileNameWithoutExtension($n.Trim())
        $path = Join-Path $Dir "$base.qml"
        if ($base -and (Test-Path -LiteralPath $path)) { $files += $path }
        elseif ($NoRecord) { $files += "unknown:$base" }
        else { Write-Host "    no such test file: shell\tests\$base.qml" -ForegroundColor Red; Record "test file $n" $false }
    }
    return $files
}

function Test-QmlNameParsing {
    $dir = Join-Path $Repo "output\qml-names-fixture"
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($x in @("a", "b", "c")) { [IO.File]::WriteAllText((Join-Path $dir "tst_$x.qml"), "TestCase {}`n") }
    $resolve = { param($raw) (@(Resolve-QmlTestFiles @(ConvertTo-TestNames $raw) $dir -NoRecord) | ForEach-Object { Split-Path $_ -Leaf }) -join "," }
    $space = & $resolve @("tst_a", "tst_b", "tst_c")
    $commaArray = & $resolve @(, @("tst_a", "tst_b"))
    $commaString = & $resolve @("tst_a,tst_b.qml")
    $suffix = & $resolve @("tst_a.qml", "tst_c.qml")
    $unknown = & $resolve @("tst_a", "tst_zz")
    $ok = $space -eq "tst_a.qml,tst_b.qml,tst_c.qml" -and $commaArray -eq "tst_a.qml,tst_b.qml" -and
        $commaString -eq "tst_a.qml,tst_b.qml" -and $suffix -eq "tst_a.qml,tst_c.qml" -and $unknown -eq "tst_a.qml,unknown:tst_zz"
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    Record "qml test names self-check (several names, a comma list passed as an array, a comma string, .qml suffixes, an unknown name)" $ok
}

$PartialBanner = "PARTIAL: dev.ps1 qml ran only the named test files (no lints, no Rust, no other tests). NOT a substitute for dev.ps1 test."
$TestNames = @(ConvertTo-TestNames $Tests)
if ($TestNames.Count -gt 0 -and $Command -ne "qml" -and $Command -ne "shots") {
    Write-Host "Only 'qml' and 'shots' take test file names: .\scripts\dev.ps1 qml tst_themes" -ForegroundColor Red
    exit 2
}
# RUY-511: `shots tst_x` runs only those files' screenshot functions; an unknown name stops at once.
$ShotFiles = @()
if ($Command -eq "shots" -and $TestNames.Count -gt 0) {
    $testDir = Join-Path $Repo "shell\tests"
    $sel = Resolve-ShotsFilter $TestNames $testDir
    if ($sel.Unknown.Count -gt 0) {
        Write-Host "No such test file: $($sel.Unknown -join ', '). Test files:" -ForegroundColor Red
        Write-Host ("    " + ((Get-ChildItem $testDir -Filter tst_*.qml | ForEach-Object { $_.BaseName }) -join ", "))
        exit 2
    }
    foreach ($b in $sel.Files) {
        if (@(Get-ScreenshotFunctions $testDir @($b)).Count -eq 0) {
            Write-Host "$b has no screenshot function (none saves to shotsDir)." -ForegroundColor Red
            exit 2
        }
    }
    $ShotFiles = @($sel.Files)
}

switch ($Command) {
    "check" { Do-Check }
    "build" { Do-Build }
    "rust" { Do-Rust }
    "shell" { Do-Shell }
    "docs" { Do-Docs }
    "qml" {
        Write-Host $PartialBanner -ForegroundColor Yellow
        if ($TestNames.Count -eq 0) { Write-Host "Name at least one test file: .\scripts\dev.ps1 qml tst_themes" -ForegroundColor Red; exit 2 }
        $files = @(Resolve-QmlTestFiles $TestNames)
        if ($script:Failures.Count -eq 0) {
            Remove-Item (Join-Path $ShellBuild "ruya-qmltest-*.txt") -ErrorAction SilentlyContinue
            Do-Build "tst_ruyashell"
            if ($script:Failures.Count -eq 0) {
                foreach ($f in $files) {
                    Step "Qt Quick tests (offscreen): $([IO.Path]::GetFileName($f)) only"
                    Run-QmlTests $null $f
                }
            }
        }
    }
    "test" {
        # A stale marker must never outlive a run that did not finish green.
        Remove-Item $GreenMarker -ErrorAction SilentlyContinue
        $treeBefore = Get-TreeState
        Test-Text; Test-Boot; Test-DevDocs; Test-ApiChangelog; Test-VmChecks; Do-Rust; Test-Conformance; Do-Shell
        if ($script:Failures.Count -eq 0) { Write-GreenMarker $treeBefore (Get-TreeState) }
    }
    "shots" {
        if (Test-SessionLocked) { Stop-SessionLocked } else {
            Do-Build
            # One shots run per desktop: two builders' windows (parallel worktrees, LEAD.md 4b) would
            # take each other's activation. A run killed while holding the lock counts as released.
            $shotsLock = New-Object System.Threading.Mutex($false, "Local\RuyaOS-shots")
            $got = $false
            try {
                $got = $shotsLock.WaitOne(0)
                if (-not $got) {
                    Write-Host "    another shots run is using the desktop; waiting for it..."
                    # Poll, so a session that locks while we wait ends the wait.
                    while (-not $got -and -not (Test-SessionLocked)) { $got = $shotsLock.WaitOne(2000) }
                }
            } catch [System.Threading.AbandonedMutexException] { $got = $true }
            if (-not $got) { Stop-SessionLocked } else {
                try {
                    Step "Display presents frames?"
                    $probe = Test-DisplayPresentsFrames -NoFrames:$NoFramesProbe
                    if ($probe -eq 3) { Stop-DisplayAsleep }
                    elseif ($probe -ne 0) { Record "shots (the display probe failed: exit $probe)" $false }
                    else {
                        # Start empty: a screenshot no test writes any more must not be reviewed as current.
                        # A filtered run keeps the others' PNGs: only the ones its functions write are replaced.
                        if ($ShotFiles.Count -eq 0) { Remove-Item (Join-Path $Repo "output\shell-shots\*.png") -ErrorAction SilentlyContinue }
                        Step "Qt Quick tests with screenshots"
                        Run-QmlTests (Join-Path $Repo "output\shell-shots") $null $ShotFiles
                        Save-ReviewCopies (Join-Path $Repo "output\shell-shots")
                        Write-Host "    screenshots: $(Join-Path $Repo 'output\shell-shots') (half size for review: review\)"
                        # Which code the PNGs show (lead-30: review shots older than the last commit were
                        # reviewed twice): the commit, and "+ uncommitted changes" when the tree was dirty.
                        $shotHead = (& git -C $Repo rev-parse --short=8 HEAD 2>$null)
                        $shotDirty = (& git -C $Repo status --porcelain --untracked-files=no 2>$null)
                        $shotAt = if ($shotDirty) { "$shotHead + uncommitted changes" } else { "$shotHead" }
                        Set-Content -Path (Join-Path $Repo "output\shell-shots\review\SHOTS-AT.txt") -Value $shotAt -Encoding utf8
                        Write-Host "    shots taken at: $shotAt (review\SHOTS-AT.txt; a reviewer compares it with the branch head)"
                    }
                } finally {
                    $shotsLock.ReleaseMutex()
                }
            }
        }
    }
    "run" {
        Do-Build
        Step "Run shell (windowed, mock services; Alt+F4 quits)"
        $env:RUYA_SERVICES = "mock"
        & (Join-Path $ShellBuild "Release\ruya-shell.exe") --windowed
    }
}

Close-Step
Write-Host ""
if ($Command -ne "run" -and $script:StepTimes.Count -gt 0) {
    $slow = $script:StepTimes | Sort-Object Sec -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name) $([int]$_.Sec) s" }
    Write-Host "time: $([int]$script:Clock.Elapsed.TotalSeconds) s; slowest steps: $($slow -join '; ')"
}
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED: $($script:Failures -join ', ')" -ForegroundColor Red
    if ($Command -eq "qml") { Write-Host $PartialBanner -ForegroundColor Yellow }
    exit 1
}
# The fast mode never prints ALL GREEN: that phrase means a full gate (push-main.ps1 matches it).
if ($Command -eq "qml") {
    Write-Host "PARTIAL PASS (qml: $($TestNames -join ', '))" -ForegroundColor Yellow
    Write-Host $PartialBanner -ForegroundColor Yellow
    exit 0
}
if ($Command -ne "run") { Write-Host "ALL GREEN ($Command)" -ForegroundColor Green }
exit 0
