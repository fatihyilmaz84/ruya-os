# RuyaOS development loop on the Windows host. One entry point for building, testing and
# running, so every contributor (human or AI) runs the exact same checks.
#
#   .\scripts\dev.ps1 check     # prerequisites present?
#   .\scripts\dev.ps1 build     # configure (first time) + build the shell
#   .\scripts\dev.ps1 test      # EVERYTHING that must pass before a commit (text lint, rust, shell)
#   .\scripts\dev.ps1 run       # start the shell in a window with mock services
#   .\scripts\dev.ps1 shots     # run the QML tests and save screenshots to output\shell-shots
#   .\scripts\dev.ps1 rust      # Rust checks only (fmt, clippy for Windows + Linux, tests)
#   .\scripts\dev.ps1 shell     # shell checks only (build, token lint, qmllint, Qt Quick tests)
#
# Qt location: $env:RUYA_QT_DIR, default D:\dev\Qt\6.10.3\msvc2022_64.
param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "build", "test", "run", "shots", "rust", "shell")]
    [string]$Command = "test"
)

# Native tools write progress to stderr; never let PowerShell turn that into errors.
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
$QtDir = if ($env:RUYA_QT_DIR) { $env:RUYA_QT_DIR } else { "D:\dev\Qt\6.10.3\msvc2022_64" }
$ShellBuild = Join-Path $Repo "shell\build-win"
$Services = Join-Path $Repo "services"
$script:Failures = @()

function Step([string]$Name) { Write-Host ""; Write-Host "==> $Name" -ForegroundColor Cyan }

function Record([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "    ok: $Name" -ForegroundColor Green }
    else { Write-Host "    FAILED: $Name" -ForegroundColor Red; $script:Failures += $Name }
}

function Invoke-Native([string]$Name, [scriptblock]$Block) {
    & $Block
    Record $Name ($LASTEXITCODE -eq 0)
}

function Use-Qt {
    if (-not (Test-Path (Join-Path $QtDir "bin\Qt6Core.dll"))) {
        Write-Host "Qt not found at $QtDir (set RUYA_QT_DIR). See docs/dev-setup.md." -ForegroundColor Red
        exit 2
    }
    if (-not ($env:PATH -like "*$QtDir\bin*")) { $env:PATH = "$QtDir\bin;$env:PATH" }
}

function Do-Check {
    Step "Prerequisites"
    $ok = $true
    foreach ($tool in "git", "cmake", "cargo", "rustup") {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if ($found) { Write-Host "    $tool : $($found.Source)" } else { Write-Host "    $tool : MISSING" -ForegroundColor Red; $ok = $false }
    }
    if (Test-Path (Join-Path $QtDir "bin\Qt6Core.dll")) { Write-Host "    Qt   : $QtDir" } else { Write-Host "    Qt   : MISSING at $QtDir" -ForegroundColor Red; $ok = $false }
    $targets = rustup target list --installed
    if ($targets -contains "x86_64-unknown-linux-gnu") { Write-Host "    rust linux target: installed" }
    else { Write-Host "    rust linux target: MISSING (rustup target add x86_64-unknown-linux-gnu)" -ForegroundColor Red; $ok = $false }
    Record "prerequisites" $ok
}

function Do-Build {
    Use-Qt
    Step "Build shell (Release)"
    if (-not (Test-Path (Join-Path $ShellBuild "CMakeCache.txt"))) {
        Invoke-Native "cmake configure" { cmake -S (Join-Path $Repo "shell") -B $ShellBuild -G "Visual Studio 18 2026" -A x64 "-DCMAKE_PREFIX_PATH=$($QtDir -replace '\\','/')" }
    }
    Invoke-Native "cmake build" { cmake --build $ShellBuild --config Release -- -m '-v:minimal' -nologo }   # quoted: PS 5.1 splits -v:x
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

function Run-QmlTests([string]$ShotsDir) {
    $log = Join-Path $env:TEMP "ruya-qmltest.txt"
    if ($ShotsDir) {
        # Screenshots need a real GPU window (offscreen = software renderer, no MultiEffect).
        # Real windows depend on the desktop: keep it unlocked and don't click other windows.
        New-Item -ItemType Directory -Force $ShotsDir | Out-Null
        $env:RUYA_SHOTS_DIR = $ShotsDir
    } else {
        # The gate runs offscreen: immune to a locked screen, OS focus changes and other
        # windows, same as CI. Logic and focus are tested; visuals are checked by `shots`.
        $env:QT_QPA_PLATFORM = "offscreen"
    }
    # -o <file>,txt: the runner's stdout is unreliable under PowerShell.
    & (Join-Path $ShellBuild "Release\tst_ruyashell.exe") -o "$log,txt" | Out-Null
    $code = $LASTEXITCODE
    Remove-Item Env:\RUYA_SHOTS_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    Get-Content $log | Where-Object { $_ -match '^(FAIL|XPASS|SKIP|Totals)|failure location|QWARN|QCRITICAL' } | ForEach-Object { Write-Host "    $_" }
    Record "Qt Quick tests" ($code -eq 0)
}

# The rules live in scripts\lint-tokens.ps1 (shared with CI).
function Test-Tokens {
    Step "token lint (no literal durations or colours outside Theme.qml)"
    & (Join-Path $PSScriptRoot "lint-tokens.ps1")
    Record "token lint" ($LASTEXITCODE -eq 0)
}

# The rules live in scripts\lint-text.ps1 (shared with CI).
function Test-Text {
    Step "text lint (tracked files are UTF-8, no stray control characters)"
    & (Join-Path $PSScriptRoot "lint-text.ps1")
    Record "text lint" ($LASTEXITCODE -eq 0)
}

function Do-Shell {
    Do-Build
    Test-Tokens
    Step "qmllint (module context)"
    # --max-warnings 0: without it qmllint exits 0 even when it reports warnings.
    Invoke-Native "qmllint" { qmllint --max-warnings 0 "@$ShellBuild\.rcc\qmllint\ruyashell.rsp" }
    Step "Qt Quick tests (offscreen)"
    Run-QmlTests $null
}

switch ($Command) {
    "check" { Do-Check }
    "build" { Do-Build }
    "rust" { Do-Rust }
    "shell" { Do-Shell }
    "test" { Test-Text; Do-Rust; Do-Shell }
    "shots" {
        Do-Build
        # Start empty: a screenshot no test writes any more must not be reviewed as current.
        Remove-Item (Join-Path $Repo "output\shell-shots\*.png") -ErrorAction SilentlyContinue
        Step "Qt Quick tests with screenshots"
        Run-QmlTests (Join-Path $Repo "output\shell-shots")
        Write-Host "    screenshots: $(Join-Path $Repo 'output\shell-shots')"
    }
    "run" {
        Do-Build
        Step "Run shell (windowed, mock services; Alt+F4 quits)"
        $env:RUYA_SERVICES = "mock"
        & (Join-Path $ShellBuild "Release\ruya-shell.exe") --windowed
    }
}

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED: $($script:Failures -join ', ')" -ForegroundColor Red
    exit 1
}
if ($Command -ne "run") { Write-Host "ALL GREEN ($Command)" -ForegroundColor Green }
exit 0
