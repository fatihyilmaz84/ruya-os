# App table lint (RUY-1050, ADR-043): per-app launch behaviour lives in one table,
# image\rootfs\usr\share\ruyaos\apps\<flatpak-id>.conf (read by services\ruya-session\src\apps.rs).
# The two files it replaced, `app-args` and `x11-apps`, must not come back: nothing in the code,
# the image or the scripts may name them. A new per-app behaviour is a key in the table.
# Docs are not scanned (the ADR and the archive name them to say they are gone).
# -SelfTest proves a hit and a clean tree on a temporary tree.
#
#   .\scripts\lint-app-table.ps1 [-SelfTest]
# Exit code 0 = fine, 1 = findings.
param([switch]$SelfTest, [string]$Root = "")
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = $Repo }
$Pattern = '\b(app-args|x11-apps)\b'
$Skip = '[\\/](target|build|build-win|node_modules|\.git)[\\/]'

function Find-OldTableNames([string]$root) {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($dir in "services", "shell", "image", "scripts", ".github", "api") {
        $path = Join-Path $root $dir
        if (-not (Test-Path $path)) { continue }
        foreach ($f in Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue) {
            if ($f.FullName -match $Skip) { continue }
            if ($f.Name -eq "lint-app-table.ps1") { continue }
            if ($f.Length -gt 2MB) { continue }
            $n = 0
            foreach ($line in [IO.File]::ReadLines($f.FullName)) {
                $n++
                if ($line -match $Pattern) {
                    $rel = $f.FullName.Substring($root.Length).TrimStart('\')
                    $hits.Add(("{0}:{1}: {2}" -f $rel, $n, $line.Trim()))
                }
            }
        }
    }
    return $hits
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-apps-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force (Join-Path $tmp "services\x\src"), (Join-Path $tmp "image\rootfs\usr\share\ruyaos\apps") | Out-Null
    try {
        [IO.File]::WriteAllLines((Join-Path $tmp "services\x\src\lib.rs"), @('const A: &str = "/usr/share/ruyaos/app-args";', 'const B: &str = "x11-apps";', 'const C: &str = "app-argsX";'))
        [IO.File]::WriteAllLines((Join-Path $tmp "image\rootfs\usr\share\ruyaos\apps\a.conf"), @("[App]", "args=-a"))
        $hits = @(Find-OldTableNames $tmp)
        $ok = ($hits.Count -eq 2)
        Write-Host ("    self-test hits (app-args, x11-apps; not a longer word): {0} ({1} hits, want 2)" -f $(if ($ok) { "ok" } else { "WRONG" }), $hits.Count)
        if (-not $ok) { exit 1 }
        exit 0
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

$hits = @(Find-OldTableNames $Root)
if ($hits.Count -gt 0) {
    foreach ($h in $hits) { Write-Host "    $h" -ForegroundColor Yellow }
    Write-Host "    app-args and x11-apps are gone (ADR-043): a per-app behaviour is a key in image/rootfs/usr/share/ruyaos/apps/<flatpak-id>.conf (services/ruya-session/src/apps.rs)" -ForegroundColor Yellow
    exit 1
}
Write-Host "    app table lint: ok"
exit 0
