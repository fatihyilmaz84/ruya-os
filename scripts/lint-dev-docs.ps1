# Developer guide lint (T-214): docs/developers/ stays true to what can be checked by a machine.
#   - every chapter linked from README.md exists, and every chapter in the folder is linked there;
#   - every relative link (and #anchor) in every file resolves;
#   - fenced code blocks: `python` parses (ast), `sh`/`bash` pass `bash -n`, `xml` is well-formed,
#     `json` parses;
#   - a fenced `c` block whose first line is `/* sample: <repo path> */` is the sample's code: each
#     of its lines must be in that file, in order (a line that is only `...` or `/* ... */` is a gap);
#   - a fenced `xml` block that starts with `<component` and is introduced (within the three lines
#     before the fence) by a `samples/.../*.metainfo.xml` path in backticks is compared with that
#     file (T-297): the same elements at the same places, with the same attribute names, and the
#     same value of `id`, `type` and `key`; text, other values and the order do not matter;
#   - every chapter ends with a "## Sources" section that names a date (YYYY-MM-DD).
#
# Used by dev.ps1 (test) and by the CI workflow. Works on Windows PowerShell 5.1 and on pwsh.
# Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-dev-docs.ps1                  # the real folder
#   .\scripts\lint-dev-docs.ps1 -Dir <folder>    # another folder (dev.ps1's self-check uses fixtures)
param(
    [string]$Dir = "",
    [string]$Repo = ""
)
$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $Dir) { $Dir = Join-Path (Join-Path $Repo "docs") "developers" }
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$problems = New-Object System.Collections.Generic.List[string]
function Fail([string]$file, [string]$msg) { $problems.Add("$file`: $msg") }

# --- tools ---------------------------------------------------------------------------------
function Find-Python {
    foreach ($n in "python3", "python") {
        $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c -and $c.Source -notmatch 'WindowsApps') { return $c.Source }
    }
    return $null
}
function Find-Bash {
    foreach ($p in "$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") {
        if ($p -and (Test-Path $p)) { return $p }
    }
    # Not the WSL launcher in System32: it would run the block in another distribution.
    $c = Get-Command bash -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch 'System32|WindowsApps' } | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}
$python = Find-Python
$bash = Find-Bash
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-devdocs-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null

# A native tool's complaint on stderr must not end the script (Windows PowerShell 5.1 turns it into
# an error record, which $ErrorActionPreference = Stop would throw).
function Run-Native([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
        return @{ code = $LASTEXITCODE; out = ($out -join "`n") }
    } finally { $ErrorActionPreference = $old }
}

function Write-Block([string]$name, [string]$text) {
    $p = Join-Path $tmp $name
    [IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"), $Utf8)
    return $p
}

# GitHub's heading slug: lower case, spaces to '-', punctuation dropped.
function Get-Slug([string]$heading) {
    $s = $heading.Trim().ToLowerInvariant()
    $s = $s -replace '[`*_]', ''
    $s = [regex]::Replace($s, '[^\p{L}\p{N}\- ]', '')
    return ($s -replace ' ', '-')
}

# Lines of a markdown file outside fenced blocks, and the fenced blocks themselves.
function Read-Markdown([string]$path) {
    $text = [IO.File]::ReadAllText($path, $Utf8)
    $prose = New-Object System.Collections.Generic.List[string]
    $blocks = New-Object System.Collections.Generic.List[object]
    $lines = $text -split "`r?`n"
    $open = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -eq $open) {
            if ($line -match '^(\s*)```+\s*([A-Za-z0-9_+-]*)') {
                $open = @{ lang = $Matches[2].ToLowerInvariant(); start = $i + 1; indent = $Matches[1].Length; body = New-Object System.Collections.Generic.List[string] }
            } else { $prose.Add($line) }
        } else {
            if ($line -match '^\s*```+\s*$') { $blocks.Add($open); $open = $null }
            else {
                $l = $line
                if ($open.indent -gt 0 -and $l.Length -ge $open.indent) { $l = $l.Substring($open.indent) }
                $open.body.Add($l)
            }
        }
    }
    if ($null -ne $open) { $blocks.Add($open); $open.unterminated = $true }
    return @{ prose = $prose; blocks = $blocks; text = $text; lines = $lines }
}

# The shape of an XML document: one string per element, "/a/b[attr1,attr2,id=x,type=y]", sorted.
# Attribute names count; only the values of id, type and key identify an element and are kept.
function Get-XmlShape($node, [string]$path, $out) {
    foreach ($c in $node.ChildNodes) {
        if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $p = "$path/$($c.LocalName)"
        $attrs = @()
        foreach ($a in $c.Attributes) {
            if ($a.Name -in @("id", "type", "key")) { $attrs += "$($a.Name)=$($a.Value)" } else { $attrs += $a.Name }
        }
        $out.Add("$p[" + ((@($attrs) | Sort-Object) -join ",") + "]")
        Get-XmlShape $c $p $out
    }
}

if (-not (Test-Path $Dir)) { Write-Host "dev docs lint: $Dir does not exist" -ForegroundColor Red; exit 1 }
$files = @(Get-ChildItem $Dir -Filter "*.md" | Sort-Object Name)
$readme = $files | Where-Object { $_.Name -eq "README.md" }
if (-not $readme) { Fail "README.md" "the index is missing" }

$parsed = @{}
foreach ($f in $files) { $parsed[$f.Name] = Read-Markdown $f.FullName }
$headings = @{}
foreach ($f in $files) {
    $set = @{}
    foreach ($l in $parsed[$f.Name].prose) {
        if ($l -match '^#{1,6}\s+(.+?)\s*#*\s*$') { $set[(Get-Slug $Matches[1])] = $true }
    }
    $headings[$f.FullName] = $set
}

# --- chapters: README <-> folder ------------------------------------------------------------
$linkRe = [regex]'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)'
$listed = @{}
if ($readme) {
    foreach ($l in $parsed["README.md"].prose) {
        foreach ($m in $linkRe.Matches($l)) {
            $t = ($m.Groups[1].Value -split '#')[0]
            if ($t -match '^[A-Za-z0-9._-]+\.md$') { $listed[$t] = $true }
        }
    }
    foreach ($t in $listed.Keys) {
        if (-not (Test-Path (Join-Path $Dir $t))) { Fail "README.md" "lists the chapter $t, which does not exist" }
    }
    foreach ($f in $files) {
        if ($f.Name -ne "README.md" -and -not $listed.ContainsKey($f.Name)) { Fail $f.Name "is not listed in README.md" }
    }
}

# --- links ----------------------------------------------------------------------------------
foreach ($f in $files) {
    foreach ($l in $parsed[$f.Name].prose) {
        foreach ($m in $linkRe.Matches($l)) {
            $target = $m.Groups[1].Value
            if ($target -match '^(https?:|mailto:)') { continue }
            $pathPart = $target; $anchor = ""
            if ($target.Contains("#")) { $pathPart = $target.Substring(0, $target.IndexOf("#")); $anchor = $target.Substring($target.IndexOf("#") + 1) }
            $resolved = if ($pathPart) { Join-Path $f.DirectoryName $pathPart } else { $f.FullName }
            if (-not (Test-Path $resolved)) { Fail $f.Name "broken link: $target"; continue }
            if ($anchor -and $resolved -like "*.md") {
                $full = (Resolve-Path $resolved).Path
                if (-not $headings.ContainsKey($full)) {
                    $p = Read-Markdown $full
                    $set = @{}
                    foreach ($hl in $p.prose) { if ($hl -match '^#{1,6}\s+(.+?)\s*#*\s*$') { $set[(Get-Slug $Matches[1])] = $true } }
                    $headings[$full] = $set
                }
                if (-not $headings[$full].ContainsKey($anchor)) { Fail $f.Name "broken anchor: $target" }
            }
        }
    }
}

# --- code blocks ----------------------------------------------------------------------------
$n = 0
foreach ($f in $files) {
    foreach ($b in $parsed[$f.Name].blocks) {
        $n++
        $where = "$($f.Name):$($b.start)"
        $body = ($b.body -join "`n")
        if ($b.unterminated) { Fail $where "code block is never closed" }
        switch -Regex ($b.lang) {
            '^python$' {
                if (-not $python) { Fail $where "python is needed to check this block and was not found"; break }
                $p = Write-Block "b$n.py" $body
                $r = Run-Native $python @("-I", "-c", "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())", $p)
                if ($r.code -ne 0) { Fail $where "python block does not parse: $(($r.out -split "`n" | Select-Object -Last 1))" }
            }
            '^(sh|bash)$' {
                if (-not $bash) { Fail $where "bash is needed to check this block and was not found"; break }
                $p = Write-Block "b$n.sh" $body
                $r = Run-Native $bash @("-n", ($p -replace '\\', '/'))
                if ($r.code -ne 0) { Fail $where "shell block fails bash -n: $(($r.out -split "`n" | Select-Object -First 1))" }
            }
            '^xml$' {
                try { $d = New-Object System.Xml.XmlDocument; $d.LoadXml($body) }
                catch { Fail $where "xml block is not well-formed: $($_.Exception.Message)"; break }
                if ($d.DocumentElement.LocalName -ne "component") { break }
                # The sample's real metainfo, named in the lines just before the fence.
                $rel = $null
                $lines = $parsed[$f.Name].lines
                for ($k = $b.start - 2; $k -ge [Math]::Max(0, $b.start - 4); $k--) {
                    $mm = [regex]::Match($lines[$k], '`(samples/[^`\s]+\.metainfo\.xml)`')
                    if ($mm.Success) { $rel = $mm.Groups[1].Value; break }
                }
                if (-not $rel) { break }
                $src = Join-Path $Repo $rel
                if (-not (Test-Path $src)) { Fail $where "sample metainfo $rel does not exist"; break }
                $real = New-Object System.Xml.XmlDocument
                try { $real.LoadXml([IO.File]::ReadAllText($src, $Utf8)) }
                catch { Fail $where "sample metainfo $rel is not well-formed: $($_.Exception.Message)"; break }
                $a = New-Object System.Collections.Generic.List[string]
                $c2 = New-Object System.Collections.Generic.List[string]
                Get-XmlShape $d "" $a
                Get-XmlShape $real "" $c2
                $ga = @{}; foreach ($s in $a) { $ga[$s] = 1 + [int]$ga[$s] }
                $gc = @{}; foreach ($s in $c2) { $gc[$s] = 1 + [int]$gc[$s] }
                foreach ($s in (@($ga.Keys) + @($gc.Keys) | Sort-Object -Unique)) {
                    $na = [int]$ga[$s]; $nc = [int]$gc[$s]
                    if ($na -ne $nc) { Fail $where "the example differs from $rel`: $s appears $na time(s) in the example and $nc in the file" }
                }
            }
            '^json$' {
                try { $null = $body | ConvertFrom-Json }
                catch { Fail $where "json block does not parse: $($_.Exception.Message)" }
            }
            '^c$' {
                $first = ($b.body | Where-Object { $_.Trim() } | Select-Object -First 1)
                if ($first -match '^\s*/\*\s*sample:\s*(\S+)\s*\*/\s*$') {
                    $rel = $Matches[1]
                    $src = Join-Path $Repo $rel
                    if (-not (Test-Path $src)) { Fail $where "sample file $rel does not exist"; break }
                    $srcLines = @([IO.File]::ReadAllText($src, $Utf8) -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
                    $pos = 0
                    foreach ($l in ($b.body | Select-Object -Skip 1)) {
                        $t = $l.TrimEnd()
                        if (-not $t.Trim()) { continue }
                        if ($t.Trim() -match '^(\.\.\.|/\*\s*\.\.\.\s*\*/)$') { continue }
                        $found = $false
                        for ($k = $pos; $k -lt $srcLines.Count; $k++) {
                            if ($srcLines[$k].Trim() -eq $t.Trim()) { $pos = $k + 1; $found = $true; break }
                        }
                        if (-not $found) { Fail $where "line is not in $rel (or is out of order): $($t.Trim())"; break }
                    }
                }
            }
        }
    }
}

# --- sources footer -------------------------------------------------------------------------
foreach ($f in $files) {
    if ($f.Name -eq "README.md") { continue }
    $m = [regex]::Match($parsed[$f.Name].text, '(?ms)^##\s+Sources\s*$(.*)\z')
    if (-not $m.Success) { Fail $f.Name "has no '## Sources' section at the end"; continue }
    if ($m.Groups[1].Value -notmatch '20\d\d-\d\d-\d\d') { Fail $f.Name "its '## Sources' section names no date (YYYY-MM-DD)" }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Red }
    Write-Host "dev docs lint: $($problems.Count) problem(s)" -ForegroundColor Red
    exit 1
}
Write-Host "dev docs lint: $($files.Count) file(s), $n code block(s) ok"
exit 0
