# Regex anchor lint (RUY-709): in QRegularExpression "$" also matches before a final line feed, so a
# whole-string check written "^...$" accepts "x\n". Validate a whole string with
# QRegularExpression::anchoredPattern(<pattern without ^ and $>) (it anchors at the very end).
# Fails on a C++ string literal under shell\ that starts with ^ and ends with $ unless the line also
# uses anchoredPattern or carries `// anchor-ok: <reason>` (a deliberate "accepts a final newline").
# -SelfTest proves a hit, an anchoredPattern line and a marked line on a temporary tree.
#
#   .\scripts\lint-regex-anchors.ps1 [-SelfTest]
# Exit code 0 = fine, 1 = findings.
param([switch]$SelfTest, [string]$Shell = "")
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Shell) { $Shell = Join-Path $Root "shell" }

# Returns "file:line: text" for every unanchored ^...$ string literal in shell\src and shell\tests C++.
function Find-BareAnchors([string]$shell) {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @("src", "tests")) {
        $d = Join-Path $shell $dir
        if (-not (Test-Path $d)) { continue }
        foreach ($f in Get-ChildItem $d -Recurse -Include "*.cpp", "*.h") {
            $lines = [IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '//\s*anchor-ok:\s*\S') { continue }
                if ($line -match 'anchoredPattern') { continue }
                if ($line -match '"\^(?:[^"\\]|\\.)*\$"') {
                    $rel = $f.FullName.Substring($shell.Length).TrimStart('\', '/') -replace '\\', '/'
                    $hits.Add(("shell/{0}:{1}: {2}" -f $rel, ($i + 1), $line.Trim()))
                }
            }
        }
    }
    return $hits
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-anchors-" + [guid]::NewGuid().ToString("N"))
    $src = Join-Path $tmp "src"
    New-Item -ItemType Directory -Force $src | Out-Null
    try {
        $code = @(
            'static const QRegularExpression a(QStringLiteral("^[a-z]{1,8}$"));',                                          # 1 hit
            'static const QRegularExpression b(QRegularExpression::anchoredPattern(QStringLiteral("[a-z]{1,8}")));',
            'static const QRegularExpression c(QStringLiteral("^[a-z]+$")); // anchor-ok: a final newline is fine here',
            'static const QRegularExpression d(QStringLiteral("^\\.[a-z0-9]{1,8}$"));',                                     # 4 hit
            'static const QRegularExpression e(QStringLiteral("^abc"));',
            'static const QRegularExpression f(QStringLiteral("abc$"));'
        )
        [IO.File]::WriteAllLines((Join-Path $src "x.cpp"), $code)
        $hits = @(Find-BareAnchors $tmp)
        $want = @(1, 4)
        $got = @($hits | ForEach-Object { if ($_ -match 'x\.cpp:(\d+):') { [int]$Matches[1] } })
        $ok = (($got -join ",") -eq ($want -join ","))
        Write-Host ("    self-test hit, anchoredPattern, marker, one-sided anchors: {0} (lines {1}, want {2})" -f $(if ($ok) { "ok" } else { "WRONG" }), ($got -join ","), ($want -join ","))
        if (-not $ok) { $hits | ForEach-Object { Write-Host "      $_" }; exit 1 }
        exit 0
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

$hits = @(Find-BareAnchors $Shell)
if ($hits.Count -gt 0) {
    foreach ($h in $hits) { Write-Host "    $h" -ForegroundColor Yellow }
    Write-Host "    a ^...$ pattern accepts a final line feed; use QRegularExpression::anchoredPattern(...) without ^ and $, or mark a deliberate case with '// anchor-ok: <reason>'" -ForegroundColor Yellow
    exit 1
}
Write-Host "    regex anchor lint: ok"
exit 0
