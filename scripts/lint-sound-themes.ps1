# Sound theme lint (T-227): the bundled theme and the guide's example pass the same checker the shell
# uses, the checker rejects every kind of broken theme, and the generator is deterministic.
#   1. scripts/make-sounds.py --verify: two runs give identical bytes, the limits hold, the ambient
#      loop's seam is smooth, the FLAC decodes to what was written, the files in the repo are the
#      generator's output;
#   2. `ruya-shell --check-sound-theme` over shell/sounds/dreamglass and samples/sound-theme-example;
#   3. `ruya-shell --check-sound-theme-fixtures`: every "ok-" fixture passes and every "bad-" fixture is
#      rejected for the reason it was made for (the same fixtures tst_sounds.qml uses).
#
# Needs the shell built (dev.ps1 shell builds it first). Used by dev.ps1 (shell, test).
# Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-sound-themes.ps1
#   .\scripts\lint-sound-themes.ps1 -Exe <path to ruya-shell> -Theme <folder>...
param(
    [string]$Exe = "",
    [string[]]$Theme = @()
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $Repo "shell\build-win\Release\ruya-shell.exe" }
if ($Theme.Count -eq 0) {
    $Theme = @((Join-Path $Repo "shell\sounds\dreamglass"), (Join-Path $Repo "samples\sound-theme-example"))
}
$problems = New-Object System.Collections.Generic.List[string]

# ruya-shell needs the Qt DLLs on PATH (dev.ps1 has put them there; a direct run may not have).
$qtDir = if ($env:RUYA_QT_DIR) { $env:RUYA_QT_DIR } else { "D:\dev\Qt\6.10.3\msvc2022_64" }
if ((Test-Path (Join-Path $qtDir "bin\Qt6Core.dll")) -and -not ($env:PATH -like "*$qtDir\bin*")) { $env:PATH = "$qtDir\bin;$env:PATH" }

function Find-Python {
    foreach ($n in "python3", "python") {
        $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c -and $c.Source -notmatch 'WindowsApps') { return $c.Source }
    }
    return $null
}

# A native tool's complaint on stderr must not end the script (Windows PowerShell 5.1).
function Run-Native([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
        return @{ code = $LASTEXITCODE; out = $out }
    } finally { $ErrorActionPreference = $old }
}

# 1. The generator.
$python = Find-Python
if (-not $python) {
    $problems.Add("python was not found (the generator check needs python with numpy)")
} else {
    $r = Run-Native $python @("-I", (Join-Path $PSScriptRoot "make-sounds.py"), "--verify")
    $r.out | ForEach-Object { Write-Host "    $_" }
    if ($r.code -ne 0) { $problems.Add("make-sounds.py --verify failed") }
}

# 2 and 3. The checker, built into the shell.
if (-not (Test-Path $Exe)) {
    $problems.Add("$Exe is missing: build the shell first (.\scripts\dev.ps1 shell)")
} else {
    $r = Run-Native $Exe (@("--check-sound-theme") + $Theme)
    $r.out | ForEach-Object { Write-Host "    $_" }
    if ($r.code -ne 0) { $problems.Add("a sound theme did not pass the checker") }

    $r = Run-Native $Exe @("--check-sound-theme-fixtures")
    $bad = @($r.out | Where-Object { $_ -like "FAIL*" })
    $r.out | Where-Object { $_ -like "FAIL*" } | ForEach-Object { Write-Host "    $_" }
    Write-Host ("    fixtures: {0} cases, {1} not as expected" -f @($r.out).Count, $bad.Count)
    if ($r.code -ne 0 -or @($r.out).Count -lt 10) { $problems.Add("the checker fixtures did not all end as expected") }
}

foreach ($p in $problems) { Write-Host "    FAIL: $p" -ForegroundColor Red }
if ($problems.Count -eq 0) { Write-Host "    sound themes: ok" -ForegroundColor Green }
exit ([int]($problems.Count -gt 0))
