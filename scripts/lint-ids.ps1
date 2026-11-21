# Profile user-name lint (RUY-1021): the rule that turns a profile id into a user name ("ruya-" + id) and
# back lives only in services\ruya-ids (USER_PREFIX). A copy of it elsewhere drifts (lint-duplicates cannot
# see a five-line re-copy), so non-test Rust code under services\*\src outside ruya-ids must not contain
#   the string literal "ruya-" (strip_prefix, concatenation, format!("{}{}", "ruya-", id), ...)
#   or a format string that starts with ruya- and goes straight into a placeholder ("ruya-{...).
# Allowed: a #[cfg(test)] module (from its `mod name {` line to the end of the file), any other
# #[cfg(test)] item (only that item is skipped, the scan goes on), tests.rs and *_tests.rs files, and a
# line that carries `// ids-ok: <reason>` for a name that is not a profile user (ruya-app-... is a longer
# literal and is not flagged).
# -SelfTest proves a hit, a marked line, test items and modules on a temporary tree.
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
            $lines = [IO.File]::ReadAllLines($f.FullName)
            $i = 0
            while ($i -lt $lines.Count) {
                $line = $lines[$i]
                if ($line -match '^\s*#\[cfg\(test\)\]') {
                    # The item the attribute covers: a `mod name {` is the rest of the file (the test module is
                    # the last item by convention); any other item is skipped up to its closing brace or `;`.
                    $j = $i + 1
                    while ($j -lt $lines.Count -and $lines[$j] -match '^\s*(#\[.*\])?\s*$') { $j++ }
                    if ($j -ge $lines.Count) { break }
                    if ($lines[$j] -match '^\s*(pub(\([^)]*\))?\s+)?mod\s+\w+\s*\{') { break }
                    $depth = 0
                    while ($j -lt $lines.Count) {
                        $depth += ([regex]::Matches($lines[$j], '\{')).Count - ([regex]::Matches($lines[$j], '\}')).Count
                        if ($depth -le 0 -and ($lines[$j] -match '[;}]\s*$' -or $lines[$j] -match '\{.*\}')) { break }
                        $j++
                    }
                    $i = $j + 1
                    continue
                }
                $n = $i + 1
                $i++
                if ($line -match '//\s*ids-ok:\s*\S') { continue }
                if ($line -match '"ruya-"' -or $line -match '"ruya-\{') {
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
            '#[cfg(test)]',                                                                    # 1
            'use x;',                                                                          # 2
            'fn a(id: &str) -> String { format!("ruya-{id}") }',                               # 3 hit
            'fn b(u: &str) -> Option<&str> { u.strip_prefix("ruya-") }',                       # 4 hit
            'fn c(id: &str) -> String { format!("ruya-{id}") } // ids-ok: a unit name, not a profile user',
            'fn d(u: &str) -> Option<&str> { u.strip_prefix("ruya-app-") }',
            'fn e(id: &str) -> String { "ruya-".to_string() + id }',                           # 7 hit
            'fn f(id: &str) -> String { format!("{}{}", "ruya-", id) }',                       # 8 hit
            '#[cfg(test)]',
            'fn t1() {',
            '    let _ = format!("ruya-{}", 1);',
            '}',
            'fn g(id: &str) -> String { format!("ruya-{id}") }',                               # 13 hit
            '#[cfg(test)]',
            '#[allow(dead_code)]',
            'fn t2() { let _ = "ruya-"; }',
            'fn h(id: &str) -> String { format!("ruya-{id}") }',                               # 17 hit
            '#[cfg(test)]',
            'mod t { fn i(id: &str) -> String { format!("ruya-{id}") } }',
            'fn after_module() -> String { format!("ruya-{}", 1) }'
        )
        [IO.File]::WriteAllLines((Join-Path $src "lib.rs"), $code)
        [IO.File]::WriteAllLines((Join-Path $src "tests.rs"), @('fn f(id: &str) -> String { format!("ruya-{id}") }'))
        [IO.File]::WriteAllLines((Join-Path $idsSrc "lib.rs"), @('fn g(u: &str) -> Option<&str> { u.strip_prefix("ruya-") }'))
        $hits = @(Find-HandBuiltUserNames $tmp)
        $want = @(3, 4, 7, 8, 13, 17)
        $got = @($hits | ForEach-Object { if ($_ -match 'lib\.rs:(\d+):') { [int]$Matches[1] } })
        $ok = (($got -join ",") -eq ($want -join ","))
        Write-Host ("    self-test hits, marker, ruya-app-, cfg(test) use/fn/mod, tests.rs, ruya-ids: {0} (lines {1}, want {2})" -f $(if ($ok) { "ok" } else { "WRONG" }), ($got -join ","), ($want -join ","))
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
