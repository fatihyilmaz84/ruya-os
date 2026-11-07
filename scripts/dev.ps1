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

# A locked Windows session (LogonUI running) renders nothing and stalls timers. RUYA_ASSUME_LOCKED=1
# simulates it (only this script reads it) so the behaviour can be checked on an unlocked desktop.
function Test-SessionLocked {
    return ($env:RUYA_ASSUME_LOCKED -eq "1") -or [bool](Get-Process LogonUI -ErrorAction SilentlyContinue)
}
function Stop-SessionLocked {
    Write-Host "    The Windows session is locked: real windows can't render. Unlock it and re-run shots." -ForegroundColor Red
    Record "shots (session locked)" $false
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

function Do-Build {
    Use-Qt
    Step "Build shell (Release)"
    if (-not (Test-Path (Join-Path $ShellBuild "CMakeCache.txt"))) {
        Invoke-Native "cmake configure" { & $script:CMake -S (Join-Path $Repo "shell") -B $ShellBuild -G "Visual Studio 18 2026" -A x64 "-DCMAKE_PREFIX_PATH=$($QtDir -replace '\\','/')" }
    }
    Invoke-Native "cmake build" { & $script:CMake --build $ShellBuild --config Release -- -m '-v:minimal' -nologo }   # quoted: PS 5.1 splits -v:x
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

function Run-QmlTests([string]$ShotsDir) {
    # Per checkout: worktree lanes run `test` at the same time (a shared %TEMP% log collided, 2026-11-04).
    $log = Join-Path $ShellBuild "ruya-qmltest.txt"
    $only = @()
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
    # A run that failed while the desktop is locked says so too; the failures above stay visible,
    # since LogonUI can also belong to another session or a lock that came after a real failure.
    if ($ShotsDir -and $code -ne 0 -and (Test-SessionLocked)) { Stop-SessionLocked; return }
    Record "Qt Quick tests" ($code -eq 0)
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
        @{ name = "a chapter without a Sources footer"; a = $chapter; other = "# Other chapter`n`nText.`n"; expect = 1; text = "no '## Sources'" }
    )
    foreach ($c in $cases) {
        $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-devdocs-fx-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $fx | Out-Null
        [IO.File]::WriteAllText((Join-Path $fx "README.md"), "# Guide`n`n| Chapter |`n|---|`n| [A](a.md) |`n| [Other](other.md) |`n")
        [IO.File]::WriteAllText((Join-Path $fx "a.md"), $c.a)
        [IO.File]::WriteAllText((Join-Path $fx "other.md"), $c.other)
        if ($c.extra) { [IO.File]::WriteAllText((Join-Path $fx $c.extra), $other) }
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
}

function Do-Shell {
    Do-Build
    Test-Tokens
    Test-Icons
    Test-FontCoverage
    Test-Translations
    Test-QmlTests
    Test-TestMembers
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
    "test" { Test-Text; Test-Board; Test-DevDocs; Do-Rust; Do-Shell }
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
                    # Start empty: a screenshot no test writes any more must not be reviewed as current.
                    Remove-Item (Join-Path $Repo "output\shell-shots\*.png") -ErrorAction SilentlyContinue
                    Step "Qt Quick tests with screenshots"
                    Run-QmlTests (Join-Path $Repo "output\shell-shots")
                    Save-ReviewCopies (Join-Path $Repo "output\shell-shots")
                    Write-Host "    screenshots: $(Join-Path $Repo 'output\shell-shots') (half size for review: review\)"
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

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED: $($script:Failures -join ', ')" -ForegroundColor Red
    exit 1
}
if ($Command -ne "run") { Write-Host "ALL GREEN ($Command)" -ForegroundColor Green }
exit 0
