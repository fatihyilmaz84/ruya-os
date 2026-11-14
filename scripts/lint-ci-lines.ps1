# CI line drift lint (RUY-591): scripts/ci-shell-linux.sh reproduces CI's Fedora `shell` job, but its dnf
# package list and its cmake configure line are copied by hand from .github/workflows/ci.yml. This compares
# the package set (order-free), the cmake -D flags (order-free) and the generator (-G) of the two files and
# names every difference. -SelfTest proves the comparison refuses a drifted package and a drifted flag.
#
#   .\scripts\lint-ci-lines.ps1 [-SelfTest]
param([switch]$SelfTest)
$Root = Split-Path -Parent $PSScriptRoot

function Get-CiLines([string]$text) {
    $dnf = $null; $cmake = $null
    foreach ($line in ($text -split "`n")) {
        if ($null -eq $dnf -and $line -match 'dnf -y install(?<rest>[^>|&]*)') { $dnf = $Matches['rest'] }
        if ($null -eq $cmake -and $line -match 'cmake -S (?<rest>[^>|&]*)') { $cmake = $Matches['rest'] }
    }
    $pkgs = @(); $flags = @(); $gen = ''
    if ($dnf) { $pkgs = @($dnf -split '\s+' | Where-Object { $_ -ne '' -and $_ -notlike '-*' }) }
    if ($cmake) {
        $flags = @($cmake -split '\s+' | Where-Object { $_ -like '-D*' })
        if ($cmake -match '-G\s+(\S+)') { $gen = $Matches[1] }
    }
    return [pscustomobject]@{ Found = ($null -ne $dnf -and $null -ne $cmake); Packages = $pkgs; Flags = $flags; Generator = $gen }
}

# Returns the list of differences between the two texts (empty = equal).
function Compare-CiLines([string]$ymlText, [string]$shText) {
    $y = Get-CiLines $ymlText; $s = Get-CiLines $shText
    $diff = New-Object System.Collections.Generic.List[string]
    if (-not $y.Found) { $diff.Add("ci.yml: no 'dnf -y install' line or no 'cmake -S' line found") }
    if (-not $s.Found) { $diff.Add("ci-shell-linux.sh: no 'dnf -y install' line or no 'cmake -S' line found") }
    if ($diff.Count -gt 0) { return $diff }
    foreach ($p in $y.Packages) { if ($s.Packages -notcontains $p) { $diff.Add("package '$p' is in ci.yml but not in ci-shell-linux.sh") } }
    foreach ($p in $s.Packages) { if ($y.Packages -notcontains $p) { $diff.Add("package '$p' is in ci-shell-linux.sh but not in ci.yml") } }
    foreach ($f in $y.Flags) { if ($s.Flags -notcontains $f) { $diff.Add("cmake flag '$f' is in ci.yml but not in ci-shell-linux.sh") } }
    foreach ($f in $s.Flags) { if ($y.Flags -notcontains $f) { $diff.Add("cmake flag '$f' is in ci-shell-linux.sh but not in ci.yml") } }
    if ($y.Generator -ne $s.Generator) { $diff.Add("cmake generator differs: ci.yml '$($y.Generator)', ci-shell-linux.sh '$($s.Generator)'") }
    return $diff
}

if ($SelfTest) {
    $base = "run: dnf -y install --setopt=install_weak_deps=False cmake ninja-build gcc-c++ gawk`nrun: cmake -S shell -B shell/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DRUYA_COMPOSITOR=ON && cmake --build shell/build`n"
    $reordered = "dnf -y install --setopt=install_weak_deps=False gawk gcc-c++ ninja-build cmake >/logs/dnf.log 2>&1`ncmake -S shell -B shell/build -DRUYA_COMPOSITOR=ON -G Ninja -DCMAKE_BUILD_TYPE=Release >/logs/build.log 2>&1`n"
    $pkgDrift = $reordered.Replace(" gawk", " gawk findutils")
    $flagDrift = $reordered.Replace("-DRUYA_COMPOSITOR=ON", "-DRUYA_COMPOSITOR=OFF")
    $genDrift = $reordered.Replace("-G Ninja", "-G Unix")
    $ok = $true
    $cases = @(
        @{ Name = "equal (order-free)"; Text = $reordered; Expect = 0 },
        @{ Name = "one drifted package"; Text = $pkgDrift; Expect = 1 },
        @{ Name = "one drifted flag"; Text = $flagDrift; Expect = 2 },
        @{ Name = "drifted generator"; Text = $genDrift; Expect = 1 },
        @{ Name = "no lines at all"; Text = "echo nothing`n"; Expect = 1 }
    )
    foreach ($c in $cases) {
        $d = @(Compare-CiLines $base $c.Text)
        $pass = ($d.Count -eq $c.Expect)
        if (-not $pass) { $ok = $false }
        Write-Host ("    self-test {0}: {1} ({2} difference(s))" -f $c.Name, $(if ($pass) { "ok" } else { "WRONG" }), $d.Count)
    }
    if (-not $ok) { exit 1 }
    exit 0
}

$yml = [IO.File]::ReadAllText((Join-Path $Root ".github\workflows\ci.yml"))
$sh = [IO.File]::ReadAllText((Join-Path $Root "scripts\ci-shell-linux.sh"))
$diff = @(Compare-CiLines $yml $sh)
if ($diff.Count -gt 0) {
    foreach ($d in $diff) { Write-Host "    $d" -ForegroundColor Yellow }
    exit 1
}
Write-Host "    ci lines: ok"
exit 0
