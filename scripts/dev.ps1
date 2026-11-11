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
    [string[]]$Tests = @(),
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
    Invoke-Native "clippy windows" { cargo clippy --all-targets --locked -q -- -D warnings }
    Step "Rust: clippy (Linux target, type-checks Linux-only code)"
    Invoke-Native "clippy linux" { cargo clippy --all-targets --locked -q --target x86_64-unknown-linux-gnu -- -D warnings }
    Step "Rust: tests"
    Invoke-Native "cargo test" { cargo test --locked -q }
    Pop-Location
}

# "Name::test_x" for every test function in shell\tests that saves a screenshot
# (`shotsDir + "/...`; Name = the file's TestCase name), so `shots` runs only those.
function Get-ScreenshotFunctions {
    $fns = @()
    foreach ($file in Get-ChildItem (Join-Path $Repo "shell\tests") -Filter *.qml) {
        $case = $null; $fn = $null
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
            if (-not $case -and $line -match '^\s+name:\s*"(\w+)"') { $case = $Matches[1] }
            if ($line -match '\bfunction (test_\w+)\s*\(') { $fn = $Matches[1] }
            if ($fn -and $case -and $line -match 'shotsDir \+ "/' -and $fns -notcontains "${case}::$fn") { $fns += "${case}::$fn" }
        }
    }
    return $fns
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
    $res = [pscustomobject]@{ Passed = 0; Failed = 0; Skipped = 0; Files = 0; Bad = @(); Lines = @() }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Shards) {
            $f = $queue.Dequeue()
            $base = [IO.Path]::GetFileNameWithoutExtension($f)
            $log = Join-Path $LogDir "$base.txt"
            $cmd = & $MakeCommand $f $log
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
    $make = {
        param($file, $log)
        $base = [IO.Path]::GetFileNameWithoutExtension($file)
        $line = "Totals: 3 passed, 0 failed, 1 skipped, 0 blacklisted, 5ms"
        $body = switch ($base) {
            "tst_fail"  { "Set-Content -LiteralPath '$log' 'FAIL!  : x::test_y() boom'; Add-Content -LiteralPath '$log' 'Totals: 2 passed, 1 failed, 0 skipped, 0 blacklisted, 5ms'; exit 1" }
            "tst_crash" { "Set-Content -LiteralPath '$log' 'Start testing of x'; exit 3" }
            "tst_hang"  { "Start-Sleep -Seconds 60" }
            default     { "Set-Content -LiteralPath '$log' '$line'; exit 0" }
        }
        @{ Exe = $ps; Args = @("-NoProfile", "-Command", "`"$body`"") }
    }.GetNewClosure()
    $all = @($names | ForEach-Object { Join-Path $fx "$_.qml" })
    $r = Invoke-QmlShards $all (Join-Path $fx "logs") 2 4 $make
    $bad = $r.Bad -join "`n"
    $ok = ($r.Files -eq 5) -and ($r.Bad.Count -eq 3) -and ($r.Passed -eq 8) -and ($r.Failed -eq 1) -and ($r.Skipped -eq 2) `
        -and ($bad -match 'tst_fail: failed .*tst_fail\.txt') -and ($bad -match 'tst_crash: crashed .*tst_crash\.txt') -and ($bad -match 'tst_hang: hung .*tst_hang\.txt') `
        -and ($bad -notmatch 'tst_ok')
    if (-not $ok) { Write-Host "    got: files $($r.Files), passed $($r.Passed), failed $($r.Failed), skipped $($r.Skipped), bad:`n$bad" -ForegroundColor Yellow }
    Record "shard runner self-check (a failed, a crashed and a hung file are named by log; the totals add up)" $ok

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
            -and ($out -match 'Totals: 8 passed, 1 failed, 2 skipped in 5 files')
        if (-not $shOk) { Write-Host "    exit $shExit, output:`n$out" -ForegroundColor Yellow }
        Record "shard runner (sh) self-check (CI's script names a failed, a crashed and a hung file by log; the totals add up)" $shOk
    }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
}

# -InputFile: one test file (the `qml` fast mode), through the runner's -input, offscreen, with its own log.
function Run-QmlTests([string]$ShotsDir, [string]$InputFile) {
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
        $only = Get-ScreenshotFunctions
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
    Remove-Item Env:\RUYA_SHOTS_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\QSG_RENDER_LOOP -ErrorAction SilentlyContinue
    Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    Get-Content $log | Where-Object { $_ -match '^(FAIL|XPASS|SKIP|Totals)|failure location|QWARN|QCRITICAL' } | ForEach-Object { Write-Host "    $_" }
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
    Remove-Item -Recurse -Force $fixture
    Record "token lint self-check (rejects a type step without font.weight)" ($rejectedW -and $acceptedW)
    Record "token lint self-check (weight in a child or comment, or a two-line size, is still rejected)" ($allRejected -and $acceptedTwoLine)
}

# The lupdate project (source list for lupdate) is written by the build's lupdate target, which
# also rewrites the tracked .ts files, so `dev.ps1` makes the project itself: from the configure-time
# <name>.Release.cmake, the same script that target runs. It is regenerated when missing (fresh
# worktree) or older than shell\CMakeLists.txt (a merge added a source file). The configure that
# refreshes the Release.cmake happens first, explicitly, in the same case.
function Update-LUpdateProject {
    $dir = Join-Path $ShellBuild ".lupdate"
    $json = Join-Path $dir "ruya-shell_lupdate_project.json"
    $in = Join-Path $dir "ruya-shell_lupdate_project.Release.cmake"
    $cml = Join-Path $Repo "shell\CMakeLists.txt"
    $stale = (-not (Test-Path $json)) -or (-not (Test-Path $in)) -or ((Get-Item $cml).LastWriteTime -gt (Get-Item $json).LastWriteTime)
    if (-not $stale) { return $json }
    if ((Test-Path (Join-Path $ShellBuild "CMakeCache.txt")) -and ((-not (Test-Path $in)) -or (Get-Item $cml).LastWriteTime -gt (Get-Item $in).LastWriteTime)) {
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

# The rules live in scripts\lint-translations.ps1 (shared with CI).
function Test-Translations {
    Step "translation lint (shell\i18n is current with the sources and complete)"
    $project = Update-LUpdateProject
    & (Join-Path $PSScriptRoot "lint-translations.ps1") -LUpdateProject $project
    Record "translation lint" ($LASTEXITCODE -eq 0)
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

# The rules live in scripts\lint-vm-checks.ps1 (shared with CI): the lead-run VM check scripts (T-296).
function Test-VmChecks {
    Step "VM check lint (vm-*.sh syntax and exec bit, host tests on canned data, ISO check refusals)"
    & (Join-Path $PSScriptRoot "lint-vm-checks.ps1")
    Record "VM check lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-board.ps1 (shared with CI).
function Test-Board {
    Step "board lint (docs\STATUS.md and the task files agree)"
    & (Join-Path $PSScriptRoot "lint-board.ps1")
    Record "board lint" ($LASTEXITCODE -eq 0)
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
        Remove-Item -Recurse -Force $fx
        $ok = ($code -eq $c.expect) -and $out.Contains($c.text)
        if (-not $ok) { Write-Host $out }
        Record "developer guide lint self-check ($($c.name): $(if ($c.expect -eq 0) { 'accepted' } else { 'rejected' }))" $ok
    }
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
    Invoke-Native "qmllint" { qmllint --max-warnings 0 "@$ShellBuild\.rcc\qmllint\ruyashell.rsp" }
    # T-462: the probe path of `shots` (a window that presents no frames stops it), without a display:
    # the window is never shown, so the probe must report "no frames" even though offscreen draws.
    Step "Display probe self-check (no frames -> asleep)"
    Record "display probe self-check (a window that presents no frames is reported)" ((Test-DisplayPresentsFrames -NoFrames -Offscreen) -eq 3)
    Step "Shard runner self-check (T-463)"
    Test-QmlShardRunner
    Step "Qt Quick tests (offscreen)"
    Run-QmlTests $null
}

# Every check that reads docs\ (text lint: all tracked files; board lint: STATUS and tasks;
# developer guide lint: docs\developers; spec lint: 04-design-system.md). A check that starts
# reading docs\ belongs here too: push-main.ps1 and the reviewer's round 2 run only this group
# when nothing but docs\*.md changed since a green `test`.
function Do-Docs { Test-Text; Test-Board; Test-DevDocs; Test-SpecComponents }

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

# shell\tests\<name>.qml for each name; an unknown name is a failure, not a silent skip.
function Resolve-QmlTestFiles([string[]]$Names) {
    $files = @()
    foreach ($n in $Names) {
        $base = [IO.Path]::GetFileNameWithoutExtension($n.Trim())
        $path = Join-Path $Repo "shell\tests\$base.qml"
        if ($base -and (Test-Path -LiteralPath $path)) { $files += $path }
        else { Write-Host "    no such test file: shell\tests\$base.qml" -ForegroundColor Red; Record "test file $n" $false }
    }
    return $files
}

$PartialBanner = "PARTIAL: dev.ps1 qml ran only the named test files (no lints, no Rust, no other tests). NOT a substitute for dev.ps1 test."
$TestNames = @($Tests | ForEach-Object { "$_" -split ',' } | Where-Object { $_.Trim() })
if ($TestNames.Count -gt 0 -and $Command -ne "qml") {
    Write-Host "Only 'qml' takes test file names: .\scripts\dev.ps1 qml tst_themes" -ForegroundColor Red
    exit 2
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
        Test-Text; Test-Board; Test-Boot; Test-BusPolicies; Test-DevDocs; Test-VmChecks; Do-Rust; Do-Shell
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
                        Remove-Item (Join-Path $Repo "output\shell-shots\*.png") -ErrorAction SilentlyContinue
                        Step "Qt Quick tests with screenshots"
                        Run-QmlTests (Join-Path $Repo "output\shell-shots")
                        Save-ReviewCopies (Join-Path $Repo "output\shell-shots")
                        Write-Host "    screenshots: $(Join-Path $Repo 'output\shell-shots') (half size for review: review\)"
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
