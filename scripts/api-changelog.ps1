# API changelog (RUY-625, ADR-022 point 4): which public API elements changed between two git refs.
#
#   .\scripts\api-changelog.ps1 <old-ref> <new-ref>
#
# For each ref, api/dbus/*.xml is read with `git show <ref>:<path>` into a temp dir and
# lint-dev-docs.ps1 (the one parser of org.ruyaos.Stability / Since, RUY-155) writes its apis.json.
# The two lists are diffed and printed as Markdown, grouped by API level (org.ruyaos.Since of the
# element): Added, Changed (stability, since or kind differs), Deprecated (became deprecated),
# Removed. Nothing differs: "no public API changes".
# apis.json has no argument lists, so a changed argument list is not seen (a new method signature
# with the same Since is not reported).
#
# -OldApiDir / -NewApiDir read the XML files from a folder instead of a ref (dev.ps1's self-check).
# Works on Windows PowerShell 5.1 and on pwsh. Exit code 0, or 1 when a ref or the lint fails.
param(
    [string]$OldRef = "",
    [string]$NewRef = "",
    [string]$OldApiDir = "",
    [string]$NewApiDir = "",
    [string]$Repo = ""
)
$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
$Lint = Join-Path $PSScriptRoot "lint-dev-docs.ps1"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$work = Join-Path ([IO.Path]::GetTempPath()) ("api-changelog-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null

# Returns the apis.json entries for a ref (or for a folder of XML files).
function Get-Apis([string]$tag, [string]$ref, [string]$xmlSrc) {
    $root = Join-Path $work $tag
    $dbus = Join-Path (Join-Path $root "api") "dbus"
    $docs = Join-Path (Join-Path $root "docs") "developers"
    New-Item -ItemType Directory -Force $dbus, $docs | Out-Null
    if ($xmlSrc) {
        Copy-Item (Join-Path $xmlSrc "*.xml") $dbus
    } else {
        $names = & git -C $Repo ls-tree --name-only $ref "api/dbus/"
        if ($LASTEXITCODE -ne 0) { throw "git: cannot list api/dbus at '$ref'" }
        foreach ($n in $names) {
            if ($n -notlike "*.xml") { continue }
            $text = & git -C $Repo show "${ref}:$n"
            if ($LASTEXITCODE -ne 0) { throw "git: cannot read $n at '$ref'" }
            [IO.File]::WriteAllText((Join-Path $dbus (Split-Path -Leaf $n)), (($text -join "`n") + "`n"), $Utf8)
        }
    }
    $out = Join-Path $root "apis.json"
    # The lint's findings (docs coverage of the old ref) are not ours: only apis.json is read.
    & $Lint -Repo $root -Dir $docs -ApisJson $out *> $null
    if (-not (Test-Path $out)) { throw "lint-dev-docs.ps1 wrote no apis.json for $tag" }
    $raw = [IO.File]::ReadAllText($out, $Utf8)
    $list = ConvertFrom-Json $raw
    if ($null -eq $list) { return @() }
    return @($list)
}

try {
    $old = Get-Apis "old" $OldRef $OldApiDir
    $new = Get-Apis "new" $NewRef $NewApiDir
} catch {
    Write-Host "api-changelog: $($_.Exception.Message)"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

$oldBy = @{}; foreach ($e in $old) { $oldBy["$($e.interface).$($e.member)"] = $e }
$newBy = @{}; foreach ($e in $new) { $newBy["$($e.interface).$($e.member)"] = $e }
$rows = New-Object System.Collections.Generic.List[object]   # level, section, text
foreach ($k in ($newBy.Keys | Sort-Object)) {
    $n = $newBy[$k]
    if (-not $oldBy.ContainsKey($k)) {
        $rows.Add(@{ level = [int]$n.since; section = "Added"; text = "``$k`` ($($n.kind), $($n.stability))" })
        continue
    }
    $o = $oldBy[$k]
    if ($n.stability -eq "deprecated" -and $o.stability -ne "deprecated") {
        $rows.Add(@{ level = [int]$n.since; section = "Deprecated"; text = "``$k`` ($($n.kind))" })
    }
    $diff = @()
    if ($n.kind -ne $o.kind) { $diff += "kind $($o.kind) -> $($n.kind)" }
    if ([int]$n.since -ne [int]$o.since) { $diff += "since $($o.since) -> $($n.since)" }
    if ($n.stability -ne $o.stability -and $n.stability -ne "deprecated") { $diff += "stability $($o.stability) -> $($n.stability)" }
    if ($diff.Count -gt 0) {
        $rows.Add(@{ level = [int]$n.since; section = "Changed"; text = "``$k`` ($($diff -join ', '))" })
    }
}
foreach ($k in ($oldBy.Keys | Sort-Object)) {
    if (-not $newBy.ContainsKey($k)) {
        $rows.Add(@{ level = [int]$oldBy[$k].since; section = "Removed"; text = "``$k`` ($($oldBy[$k].kind))" })
    }
}

if ($rows.Count -eq 0) { Write-Output "no public API changes"; exit 0 }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Public API changes")
foreach ($lvl in ($rows | ForEach-Object { $_.level } | Sort-Object -Unique)) {
    $lines.Add(""); $lines.Add("## API level $lvl")
    foreach ($sec in "Added", "Changed", "Deprecated", "Removed") {
        $hit = @($rows | Where-Object { $_.level -eq $lvl -and $_.section -eq $sec })
        if ($hit.Count -eq 0) { continue }
        $lines.Add(""); $lines.Add("### $sec"); $lines.Add("")
        foreach ($h in $hit) { $lines.Add("- $($h.text)") }
    }
}
$lines | ForEach-Object { Write-Output $_ }
