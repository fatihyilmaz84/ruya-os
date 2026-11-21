# Profile user-name lint (RUY-1021): the rule that turns a profile id into a user name ("ruya-" + id) and
# back lives only in services\ruya-ids (USER_PREFIX). A copy of it elsewhere drifts (lint-duplicates cannot
# see a five-line re-copy), so non-test Rust code under services\*\src outside ruya-ids must not contain
#   strip_prefix("ruya-")      or      format!("ruya-{...
# Allowed: a #[cfg(test)] module (everything after the first #[cfg(test)] line of a file), tests.rs and
# *_tests.rs files, and a line that carries `// ids-ok: <reason>` for a name that is not a profile user.
# -SelfTest proves a hit, a marked line and a test-module line on a temporary tree.
#
#   .\scripts\lint-ids.ps1 [-SelfTest]
# Exit code 0 = fine, 1 = findings.
param([switch]$SelfTest, [string]$Services = "")
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Services) { $Services = Join-Path $Root "services" }

# Returns "file:line: text" findings for every .rs file under <services>\<crate>\src.
function Find-HandBuiltUserNames([string]$services) {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($crate in Get-ChildItem $services -Directory) {
        if ($crate.Name -eq "ruya-ids") { continue }
        $src = Join-Path $crate.FullName "src"
        if (-not (Test-Path $src)) { continue }
        foreach ($f in Get-ChildItem $src -Recurse -Filter "*.rs") {
            if ($f.Name -eq "tests.rs" -or $f.Name -like "*_tests.rs") { continue }
            $n = 0
            foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
                $n++
                if ($line -match '^\s*#\[cfg\(test\)\]') { break }
                if ($line -match '//\s*ids-ok:\s*\S') { continue }
                if ($line -match 'strip_prefix\("ruya-"\)' -or $line -match 'format!\("ruya-\{') {
                    $rel = $f.FullName.Substring($services.Length).TrimStart('\', '/') -replace '\\', '/'
                    $hits.Add(("services/{0}:{1}: {2}" -f $rel, $n, $line.Trim()))
                }
            }
        }
    }
    return $hits
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-ids-" + [guid]::NewGuid().ToString("N"))
    $src = Join-Path $tmp "ruya-x\src"
    $idsSrc = Join-Path $tmp "ruya-ids\src"
    New-Item -ItemType Directory -Force $src, $idsSrc | Out-Null
    try {
        $code = @(
            'fn a(id: &str) -> String { format!("ruya-{id}") }',
            'fn b(u: &str) -> Option<&str> { u.strip_prefix("ruya-") }',
            'fn c(id: &str) -> String { format!("ruya-{id}") } // ids-ok: a unit name, not a profile user',
            'fn d(u: &str) -> Option<&str> { u.strip_prefix("ruya-app-") }',
            '#[cfg(test)]',
            'mod t { fn e(id: &str) -> String { format!("ruya-{id}") } }'
        )
        [IO.File]::WriteAllLines((Join-Path $src "lib.rs"), $code)
        [IO.File]::WriteAllLines((Join-Path $src "tests.rs"), @('fn f(id: &str) -> String { format!("ruya-{id}") }'))
        [IO.File]::WriteAllLines((Join-Path $idsSrc "lib.rs"), @('fn g(u: &str) -> Option<&str> { u.strip_prefix("ruya-") }'))
        $hits = @(Find-HandBuiltUserNames $tmp)
        $ok = ($hits.Count -eq 2 -and $hits[0] -like "*lib.rs:1:*" -and $hits[1] -like "*lib.rs:2:*")
        Write-Host ("    self-test hit / marked / prefix-with-more / test module / tests.rs / ruya-ids: {0} ({1} finding(s), want lines 1 and 2)" -f $(if ($ok) { "ok" } else { "WRONG" }), $hits.Count)
        if (-not $ok) { $hits | ForEach-Object { Write-Host "      $_" }; exit 1 }
        exit 0
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

$hits = @(Find-HandBuiltUserNames $Services)
if ($hits.Count -gt 0) {
    foreach ($h in $hits) { Write-Host "    $h" -ForegroundColor Yellow }
    Write-Host "    profile user names are built and parsed only by services/ruya-ids (user_of, profile_of_user); use it, or mark a name that is not a profile user with '// ids-ok: <reason>'" -ForegroundColor Yellow
    exit 1
}
Write-Host "    ids lint: ok"
exit 0
