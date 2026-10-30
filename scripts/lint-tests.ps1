# Test lint: no QML test presses keys in an unbounded loop.
# `while (!list.activeFocus) keyClick(Qt.Key_Down)` spins forever when focus never arrives
# (an inactive or locked desktop, a broken page), so `shots` hung instead of failing
# (T-111, lead 2026-10-30). Bound the loop and assert afterwards:
#   for (let i = 0; i < 20 && list.currentIndex < 4; ++i) keyClick(Qt.Key_Down)
#   compare(list.currentIndex, 4)
# Flags a `while (` whose condition line or next line sends a key (keyClick, keyPress,
# keySequence). Loops that end by themselves (dismissing toasts) are not affected.
#
# Used by dev.ps1 (shell, test) and by the CI workflow. Works on Windows PowerShell 5.1 and
# on pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-tests.ps1 [-TestDir <dir>]
param([string]$TestDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shell/tests"))

$findings = 0
foreach ($file in Get-ChildItem -Path $TestDir -Filter *.qml) {
    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '\bwhile\s*\(') { continue }
        $body = $lines[$i]
        if ($i + 1 -lt $lines.Count) { $body += "`n" + $lines[$i + 1] }
        if ($body -match '\bkey(Click|Press|Sequence)\s*\(') {
            Write-Host "    $($file.Name):$($i + 1): $($lines[$i].Trim())"
            $findings++
        }
    }
}
if ($findings -gt 0) {
    Write-Host "    A key-pressing while loop can hang the test run: bound it (for, with a limit) and assert after it."
    exit 1
}
exit 0
