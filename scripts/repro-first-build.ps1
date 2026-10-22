# Reproduces (and guards against) T-116: the first build after adding a C++ QML_ELEMENT type.
#
#   .\scripts\repro-first-build.ps1 [-Name Probe] [-Keep]
#
# Adds a scratch singleton class <Name> (src/probe/), lists it in shell/CMakeLists.txt, uses it from
# a module QML file and from a Qt Quick test, runs `dev.ps1 shell` ONCE, then reverts everything
# (unless -Keep). Exit code 0 = the first run after adding the type was green.
param(
    [string]$Name = "Probe",
    [switch]$Keep,
    [switch]$NoBuild   # only apply the probe (implies -Keep), to build by hand with extra logging
)
if ($NoBuild) { $Keep = $true }

$Repo = Split-Path -Parent $PSScriptRoot
$Shell = Join-Path $Repo "shell"
$Cmake = Join-Path $Shell "CMakeLists.txt"
$Dir = Join-Path $Shell "src\probe"
$Qml = Join-Path $Shell "qml\${Name}User.qml"
$Test = Join-Path $Shell "tests\tst_${Name}.qml"
$Orig = [IO.File]::ReadAllText($Cmake)

function Write-Lf([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

New-Item -ItemType Directory -Force $Dir | Out-Null
Write-Lf (Join-Path $Dir "$Name.h") @"
#pragma once

#include <QObject>
#include <QQmlEngine>

class $Name : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(int answer READ answer CONSTANT)

public:
    using QObject::QObject;
    static $Name *create(QQmlEngine *, QJSEngine *) { return new $Name; }
    int answer() const { return 42; }
};
"@
Write-Lf (Join-Path $Dir "$Name.cpp") "#include `"$Name.h`"`n"
Write-Lf $Qml @"
import QtQuick

Item {
    property int answer: ${Name}.answer
}
"@
Write-Lf $Test @"
import QtQuick
import QtTest
import RuyaShell

TestCase {
    name: "$Name"
    function test_answer() { compare(${Name}.answer, 42) }
}
"@

$new = $Orig.Replace("        src/audio/Audio.h src/audio/Audio.cpp`n",
    "        src/audio/Audio.h src/audio/Audio.cpp`n        src/probe/$Name.h src/probe/$Name.cpp`n")
$new = $new.Replace("        qml/Main.qml`n", "        qml/Main.qml`n        qml/${Name}User.qml`n")
$new = $new.Replace("src/system)", "src/system src/probe)")
if ($new -eq $Orig) { Write-Host "CMakeLists.txt anchors not found" -ForegroundColor Red; exit 2 }
[IO.File]::WriteAllText($Cmake, $new, (New-Object Text.UTF8Encoding $false))

if ($NoBuild) { Write-Host "probe $Name applied; build it, then delete shell\src\probe, shell\qml\${Name}User.qml, shell\tests\tst_${Name}.qml and undo the CMakeLists.txt edit by hand"; exit 0 }

$sw = [Diagnostics.Stopwatch]::StartNew()
& (Join-Path $PSScriptRoot "dev.ps1") shell
$code = $LASTEXITCODE
Write-Host "first run after adding ${Name}: exit $code in $([int]$sw.Elapsed.TotalSeconds) s" -ForegroundColor Cyan

if (-not $Keep) {
    [IO.File]::WriteAllText($Cmake, $Orig, (New-Object Text.UTF8Encoding $false))
    Remove-Item -Recurse -Force $Dir, $Qml, $Test
    Write-Host "reverted; rebuilding the clean tree (removing a type must not break the build either)" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "dev.ps1") build
    $revertCode = $LASTEXITCODE
    Write-Host "first run after removing ${Name}: exit $revertCode" -ForegroundColor Cyan
    if ($revertCode -ne 0) { $code = 1 }
}
exit $code
