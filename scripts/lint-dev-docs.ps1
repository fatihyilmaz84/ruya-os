# Developer guide lint (T-214): docs/developers/ stays true to what can be checked by a machine.
#   - every chapter linked from README.md exists, and every chapter in the folder is linked there;
#   - every relative link (and #anchor) in every file resolves;
#   - fenced code blocks: `python` parses (ast), `sh`/`bash` pass `bash -n`, `xml` is well-formed,
#     `json` parses, and a `json` block that is a whole play.json (it has format, id and run) must
#     satisfy api/play/play.schema.json (RUY-105; a small validator for the keywords it uses), a
#     whole runner.json (format, family and kind) api/play/runner.schema.json (RUY-898);
#   - a fenced `c` block whose first line is `/* sample: <repo path> */` (a `python`, `sh` or `bash`
#     block: `# sample: <repo path>`) is the sample's code: each of its lines must be in that file,
#     in order (a line that is only `...` or `/* ... */` is a gap);
#   - a sample Flatpak manifest (samples/<name>/*.json) that names org.ruyaos.Play must match
#     the image (RUY-36): the runner point and branch of services/ruya-play/src/service/commit.rs
#     (subdirectories, no-autodownload), and an id <point>.<Name> needs a folder image/play/runners/<Name>;
#   - a fenced `xml` block that starts with `<component` and is introduced (within the three lines
#     before the fence) by a `samples/.../*.metainfo.xml` path in backticks is compared with that
#     file (T-297): the same elements at the same places, with the same attribute names, and the
#     same value of `id`, `type` and `key`; text, other values and the order do not matter;
#   - every chapter ends with a "## Sources" section that names a date (YYYY-MM-DD);
#   - public API elements (RUY-155, ADR-022): in <Repo>/api/dbus/*.xml a method, signal or property
#     with an org.ruyaos.Stability annotation is public (a tag on the interface is ignored; an
#     untagged element is private). Stability must be experimental, stable or deprecated;
#     org.ruyaos.Since must be an integer; and "<Interface>.<Member>" must appear in a code span
#     in a chapter other than api-surface.md;
#   - samples (-Samples only): `make -C samples/<name> test` for every sample with a Makefile; a
#     failing test or a missing make is a finding. Without -Samples the lint prints
#     "samples not built (use -Samples)" and stays green.
#
# This is the one parser of the Stability/Since annotations. It writes the public elements to
# apis.json (default <Repo>/output/apis.json, git-ignored; change with -ApisJson), for the API
# changelog, the mock, `ruya sdk` and the catalogue to read. Shape, a JSON array (empty: []):
#   [{ "interface": "org.ruyaos.X1", "member": "Name", "kind": "method|signal|property",
#      "stability": "experimental|stable|deprecated", "since": 1, "signature": "...", "file": "api/dbus/<file>.xml" }]
# signature (RUY-656), arguments in XML order as name:type: a method "in:a:s,b:i;out:r:b", a signal
# "a:s,b:i", a property "type:access" ("s:read"). The API changelog reports a changed signature.
# Only elements without a finding are listed.
#
# Used by dev.ps1 (test) and by the CI workflow. Works on Windows PowerShell 5.1 and on pwsh.
# Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-dev-docs.ps1                  # the real folder
#   .\scripts\lint-dev-docs.ps1 -Dir <folder>    # another folder (dev.ps1's self-check uses fixtures)
#   .\scripts\lint-dev-docs.ps1 -Samples         # also build and test the samples (CI, Linux)
param(
    [string]$Dir = "",
    [string]$Repo = "",
    [string]$ApisJson = "",
    [switch]$Samples
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

# --- JSON Schema subset (RUY-105) ---------------------------------------------------------------
# The keywords api/play/play.schema.json uses, nothing else (a keyword this does not know is itself
# a finding, as in services/ruya-play-format/tests/schema.rs, so a new keyword cannot be ignored).
# $v and $schema come from ConvertFrom-Json (PSCustomObject, object[], string, bool, numbers).
$SchemaAnnotations = @('$schema', '$id', 'title', 'description', '$comment', '$defs', 'default')
function Test-SchemaType($v, [string]$t) {
    switch ($t) {
        'object'  { return ($v -is [System.Management.Automation.PSCustomObject]) }
        'array'   { return ($v -is [System.Array]) }
        'string'  { return ($v -is [string]) }
        'boolean' { return ($v -is [bool]) }
        'integer' { return (($v -is [int]) -or ($v -is [long]) -or ((($v -is [double]) -or ($v -is [decimal])) -and ($v -eq [Math]::Floor($v)))) }
        'number'  { return (($v -is [int]) -or ($v -is [long]) -or ($v -is [decimal]) -or ($v -is [double])) }
        default   { throw "schema type $t is not supported by the lint" }
    }
}
function Test-SchemaEqual($a, $b) {
    if (($a -is [string]) -and ($b -is [string])) { return ($a -ceq $b) }
    if (($a -is [string]) -or ($b -is [string])) { return $false }
    return ((ConvertTo-Json -InputObject $a -Compress -Depth 20) -eq (ConvertTo-Json -InputObject $b -Compress -Depth 20))
}
function Get-SchemaErrors($root, $schema, $v, [string]$at, $out) {
    if ($schema -is [bool]) { if (-not $schema) { $out.Add("${at}: false schema") }; return }
    foreach ($p in $schema.PSObject.Properties) {
        $k = $p.Name; $kv = $p.Value
        if ($SchemaAnnotations -contains $k) { continue }
        switch ($k) {
            '$ref' {
                $target = $root
                foreach ($seg in ($kv -replace '^#/?', '').Split('/', [StringSplitOptions]::RemoveEmptyEntries)) { $target = $target.$seg }
                Get-SchemaErrors $root $target $v $at $out
            }
            'type' { if (-not (Test-SchemaType $v $kv)) { $out.Add("${at}: not a $kv") } }
            'enum' {
                $hit = $false
                foreach ($e in $kv) { if (Test-SchemaEqual $v $e) { $hit = $true; break } }
                if (-not $hit) { $out.Add("${at}: not one of the allowed values") }
            }
            'const' { if (-not (Test-SchemaEqual $v $kv)) { $out.Add("${at}: not $kv") } }
            'minimum' { if ((Test-SchemaType $v 'number') -and ([double]$v -lt [double]$kv)) { $out.Add("${at}: below $kv") } }
            'maximum' { if ((Test-SchemaType $v 'number') -and ([double]$v -gt [double]$kv)) { $out.Add("${at}: above $kv") } }
            'minLength' { if (($v -is [string]) -and ($v.Length -lt $kv)) { $out.Add("${at}: too short") } }
            'maxLength' { if (($v -is [string]) -and ($v.Length -gt $kv)) { $out.Add("${at}: too long") } }
            'pattern' { if (($v -is [string]) -and (-not [regex]::IsMatch($v, $kv))) { $out.Add("${at}: does not match $kv") } }
            'minItems' { if (($v -is [System.Array]) -and ($v.Count -lt $kv)) { $out.Add("${at}: too few items") } }
            'maxItems' { if (($v -is [System.Array]) -and ($v.Count -gt $kv)) { $out.Add("${at}: too many items") } }
            'uniqueItems' {
                if (($v -is [System.Array]) -and $kv) {
                    $seen = @{}
                    foreach ($x in $v) {
                        $key = ConvertTo-Json -InputObject $x -Compress -Depth 20
                        if ($seen.ContainsKey($key)) { $out.Add("${at}: items repeat"); break }
                        $seen[$key] = $true
                    }
                }
            }
            'items' {
                if ($v -is [System.Array]) {
                    for ($i = 0; $i -lt $v.Count; $i++) { Get-SchemaErrors $root $kv $v[$i] "$at/$i" $out }
                }
            }
            'required' {
                if (Test-SchemaType $v 'object') {
                    foreach ($r in $kv) { if (-not $v.PSObject.Properties[$r]) { $out.Add("${at}: missing $r") } }
                }
            }
            'maxProperties' { if ((Test-SchemaType $v 'object') -and (@($v.PSObject.Properties).Count -gt $kv)) { $out.Add("${at}: too many properties") } }
            'properties' {
                if (Test-SchemaType $v 'object') {
                    foreach ($sp in $kv.PSObject.Properties) {
                        $x = $v.PSObject.Properties[$sp.Name]
                        if ($x) { Get-SchemaErrors $root $sp.Value $x.Value "$at/$($sp.Name)" $out }
                    }
                }
            }
            'additionalProperties' {
                if (Test-SchemaType $v 'object') {
                    $known = $schema.PSObject.Properties['properties']
                    foreach ($vp in $v.PSObject.Properties) {
                        if ($known -and $known.Value.PSObject.Properties[$vp.Name]) { continue }
                        Get-SchemaErrors $root $kv $vp.Value "$at/$($vp.Name)" $out
                    }
                }
            }
            'propertyNames' {
                if (Test-SchemaType $v 'object') {
                    foreach ($vp in $v.PSObject.Properties) { Get-SchemaErrors $root $kv $vp.Name "$at/$($vp.Name) (name)" $out }
                }
            }
            'allOf' { foreach ($sub in $kv) { Get-SchemaErrors $root $sub $v $at $out } }
            'oneOf' {
                $n = 0
                foreach ($sub in $kv) {
                    $e = New-Object System.Collections.Generic.List[string]
                    Get-SchemaErrors $root $sub $v $at $e
                    if ($e.Count -eq 0) { $n++ }
                }
                if ($n -ne 1) { $out.Add("${at}: matches $n of the oneOf branches") }
            }
            'not' {
                $e = New-Object System.Collections.Generic.List[string]
                Get-SchemaErrors $root $kv $v $at $e
                if ($e.Count -eq 0) { $out.Add("${at}: matches a pattern that is not allowed") }
            }
            'if' {
                $e = New-Object System.Collections.Generic.List[string]
                Get-SchemaErrors $root $kv $v $at $e
                $then = $schema.PSObject.Properties['then']
                if (($e.Count -eq 0) -and $then) { Get-SchemaErrors $root $then.Value $v $at $out }
            }
            'then' { }
            default { $out.Add("${at}: the lint does not know the schema keyword $k") }
        }
    }
}
$schemaTexts = @{}

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

# A fenced c, python, sh or bash block whose first line is `/* sample: <repo path> */` (c) or
# `# sample: <repo path>` (the others) is the sample's code: each of its lines must be in that file,
# in order (a line that is only `...` or `/* ... */` is a gap). Returns the finding, or $null.
function Test-SampleBlock($b) {
    $first = ($b.body | Where-Object { $_.Trim() } | Select-Object -First 1)
    $re = if ($b.lang -eq 'c') { '^\s*/\*\s*sample:\s*(\S+)\s*\*/\s*$' } else { '^\s*#\s*sample:\s*(\S+)\s*$' }
    if ($first -notmatch $re) { return $null }
    $rel = $Matches[1]
    $src = Join-Path $Repo $rel
    if (-not (Test-Path $src)) { return "sample file $rel does not exist" }
    $srcLines = @([IO.File]::ReadAllText($src, $Utf8) -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    $pos = 0
    foreach ($l in ($b.body | Select-Object -Skip 1)) {
        $t = $l.TrimEnd()
        if (-not $t.Trim()) { continue }
        if ($t.Trim() -match '^(\.\.\.|/\*\s*\.\.\.\s*\*/|#\s*\.\.\.)$') { continue }
        $found = $false
        for ($k = $pos; $k -lt $srcLines.Count; $k++) {
            if ($srcLines[$k].Trim() -eq $t.Trim()) { $pos = $k + 1; $found = $true; break }
        }
        if (-not $found) { return "line is not in $rel (or is out of order): $($t.Trim())" }
    }
    return $null
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
                try { $obj = $body | ConvertFrom-Json }
                catch { Fail $where "json block does not parse: $($_.Exception.Message)"; break }
                # RUY-105: a whole play.json (it has format, id and run) must satisfy its schema;
                # RUY-898: so must a whole runner.json (it has format, family and kind).
                $isObject = $obj -is [System.Management.Automation.PSCustomObject]
                $schemaName = $null
                if ($isObject -and $obj.PSObject.Properties['format'] -and $obj.PSObject.Properties['id'] -and $obj.PSObject.Properties['run']) { $schemaName = "play" }
                elseif ($isObject -and $obj.PSObject.Properties['format'] -and $obj.PSObject.Properties['family'] -and $obj.PSObject.Properties['kind']) { $schemaName = "runner" }
                if (-not $schemaName) { break }
                $schemaPath = Join-Path (Join-Path (Join-Path $Repo "api") "play") "$schemaName.schema.json"
                if (-not (Test-Path $schemaPath)) { Fail $where "json block is a $schemaName.json but api/play/$schemaName.schema.json does not exist"; break }
                if (-not $schemaTexts.ContainsKey($schemaName)) { $schemaTexts[$schemaName] = [IO.File]::ReadAllText($schemaPath, $Utf8) }
                $schemaDoc = $schemaTexts[$schemaName] | ConvertFrom-Json
                $errs = New-Object System.Collections.Generic.List[string]
                Get-SchemaErrors $schemaDoc $schemaDoc $obj "" $errs
                foreach ($e in $errs) { Fail $where "$schemaName.json block does not satisfy $schemaName.schema.json: $e" }
            }
            '^(c|python|sh|bash)$' {
                $msg = Test-SampleBlock $b
                if ($msg) { Fail $where $msg }
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

# --- public API elements (RUY-155) -----------------------------------------------------------
# The one parser of org.ruyaos.Stability / org.ruyaos.Since: it writes $ApisJson.
$apis = New-Object System.Collections.Generic.List[object]
$xmlDir = Join-Path (Join-Path $Repo "api") "dbus"
$chapterSpans = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    if ($f.Name -eq "api-surface.md") { continue }
    foreach ($l in $parsed[$f.Name].prose) {
        foreach ($m in [regex]::Matches($l, '`([^`]+)`')) { $chapterSpans.Add($m.Groups[1].Value) }
    }
}
if (Test-Path $xmlDir) {
    foreach ($x in (Get-ChildItem $xmlDir -Filter "*.xml" | Sort-Object Name)) {
        $rel = "api/dbus/$($x.Name)"
        $d = New-Object System.Xml.XmlDocument
        $d.XmlResolver = $null   # the introspection DOCTYPE points at freedesktop.org: never fetch it
        $xmlText = [IO.File]::ReadAllText($x.FullName, $Utf8)
        try { $d.LoadXml($xmlText) }
        catch {
            $ln = if ($_.Exception.InnerException -and $null -ne $_.Exception.InnerException.LineNumber) { $_.Exception.InnerException.LineNumber } else { 0 }
            Fail $rel "is not well-formed xml (line $ln): $($_.Exception.Message)"; continue
        }
        foreach ($iface in $d.SelectNodes("//interface")) {
            $iname = $iface.GetAttribute("name")
            foreach ($el in $iface.ChildNodes) {
                if ($el.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ($el.LocalName -notin @("method", "signal", "property")) { continue }
                $stab = $null; $since = $null
                foreach ($an in $el.ChildNodes) {
                    if ($an.NodeType -ne [System.Xml.XmlNodeType]::Element -or $an.LocalName -ne "annotation") { continue }
                    if ($an.GetAttribute("name") -eq "org.ruyaos.Stability") { $stab = $an.GetAttribute("value") }
                    if ($an.GetAttribute("name") -eq "org.ruyaos.Since") { $since = $an.GetAttribute("value") }
                }
                if ($null -eq $stab) { continue }   # untagged: private
                $full = "$iname.$($el.GetAttribute('name'))"
                $bad = $false
                if ($stab -notin @("experimental", "stable", "deprecated")) {
                    Fail $rel "$full has org.ruyaos.Stability '$stab' (use experimental, stable or deprecated)"; $bad = $true
                }
                if ($null -eq $since -or $since -notmatch '^\d+$') {
                    Fail $rel "$full has no integer org.ruyaos.Since"; $bad = $true
                }
                if ($bad) { continue }
                $sig = ""
                if ($el.LocalName -eq "property") {
                    $sig = "$($el.GetAttribute('type')):$($el.GetAttribute('access'))"
                } else {
                    $ins = New-Object System.Collections.Generic.List[string]
                    $outs = New-Object System.Collections.Generic.List[string]
                    foreach ($a in $el.ChildNodes) {
                        if ($a.NodeType -ne [System.Xml.XmlNodeType]::Element -or $a.LocalName -ne "arg") { continue }
                        $item = "$($a.GetAttribute('name')):$($a.GetAttribute('type'))"
                        $dir = $a.GetAttribute("direction")
                        if ($el.LocalName -eq "signal") { $outs.Add($item) }   # signal args are always out
                        elseif ($dir -eq "out") { $outs.Add($item) } else { $ins.Add($item) }
                    }
                    $sig = if ($el.LocalName -eq "signal") { $outs -join "," } else { "in:" + ($ins -join ",") + ";out:" + ($outs -join ",") }
                }
                $apis.Add([ordered]@{ interface = $iname; member = $el.GetAttribute("name"); kind = $el.LocalName; stability = $stab; since = [int]$since; signature = $sig; file = $rel })
                $hit = $false
                foreach ($s in $chapterSpans) { if ($s.Contains($full)) { $hit = $true; break } }
                if (-not $hit) { Fail $rel "$full is public but no chapter of docs/developers/ (other than api-surface.md) names it in a code span" }
            }
        }
    }
}
if (-not $ApisJson) { $ApisJson = Join-Path (Join-Path $Repo "output") "apis.json" }
New-Item -ItemType Directory -Force (Split-Path -Parent $ApisJson) | Out-Null
$json = if ($apis.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($apis.ToArray()) -Depth 4 }
[IO.File]::WriteAllText($ApisJson, $json + "`n", $Utf8)

# --- samples that use a system runner (RUY-36) ----------------------------------------------------
# A Flatpak manifest at samples/<name>/*.json that names org.ruyaos.Play (a misspelt runner id too) must parse and its
# add-extensions must match what the image ships: the point is RUNNER_EXTENSION of
# services/ruya-play/src/service/commit.rs (a subdirectories point, mounting every runner) or one
# runner id <point>.<Name> whose <Name> is a folder of image/play/runners/; the branch is
# PLAY_EXTENSION_BRANCH; no-autodownload is true (the image links the runners in, nothing is fetched).
$runnerManifests = @()
$samplesRoot = Join-Path $Repo "samples"
if (Test-Path $samplesRoot) {
    foreach ($m in (Get-ChildItem $samplesRoot -Directory | ForEach-Object { Get-ChildItem $_.FullName -Filter "*.json" -File })) {
        if ([IO.File]::ReadAllText($m.FullName, $Utf8).Contains("org.ruyaos.Play")) { $runnerManifests += $m }
    }
}
if ($runnerManifests.Count -gt 0) {
    $commitRs = Join-Path $Repo "services/ruya-play/src/service/commit.rs"
    $commitText = if (Test-Path $commitRs) { [IO.File]::ReadAllText($commitRs, $Utf8) } else { "" }
    $pointMatch = [regex]::Match($commitText, 'RUNNER_EXTENSION:\s*&str\s*=\s*"([^"]+)"')
    $branchMatch = [regex]::Match($commitText, 'PLAY_EXTENSION_BRANCH:\s*&str\s*=\s*"([^"]+)"')
    $runnerNames = @()
    $runnersDir = Join-Path $Repo "image/play/runners"
    if (Test-Path $runnersDir) {
        $runnerNames = @(Get-ChildItem $runnersDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName "runner.json") } | ForEach-Object { $_.Name })
    }
    foreach ($m in $runnerManifests) {
        $rel = "samples/$($m.Directory.Name)/$($m.Name)"
        if (-not ($pointMatch.Success -and $branchMatch.Success)) {
            Fail $rel "cannot read RUNNER_EXTENSION and PLAY_EXTENSION_BRANCH from services/ruya-play/src/service/commit.rs"; continue
        }
        $point = $pointMatch.Groups[1].Value
        $branch = $branchMatch.Groups[1].Value
        try { $man = [IO.File]::ReadAllText($m.FullName, $Utf8) | ConvertFrom-Json }
        catch { Fail $rel "is not valid json: $($_.Exception.Message)"; continue }
        $exts = if ($man.PSObject.Properties['add-extensions']) { @($man.'add-extensions'.PSObject.Properties) } else { @() }
        if ($exts.Count -eq 0) { Fail $rel "has no add-extensions entry for $point"; continue }
        foreach ($e in $exts) {
            $id = $e.Name; $ext = $e.Value
            if ($id -ceq $point) {
                if ($ext.subdirectories -ne $true) { Fail $rel "$id must set subdirectories to true: every runner mounts under /app/<directory>/<Name>" }
            } elseif ($id.StartsWith("$point.")) {
                $name = $id.Substring($point.Length + 1)
                if ($runnerNames -cnotcontains $name) { Fail $rel "$id names a runner that is not in image/play/runners/ (folders: $($runnerNames -join ', '))" }
            } else {
                Fail $rel "extension $id is neither $point nor one of its ids ($point.<Name>)"; continue
            }
            if ("$($ext.version)" -ne $branch) { Fail $rel "$id has version '$($ext.version)', the image's branch is '$branch'" }
            if ($ext.'no-autodownload' -ne $true) { Fail $rel "$id must set no-autodownload to true" }
            if (-not $ext.directory) { Fail $rel "$id has no directory" }
        }
    }
}

# --- samples (RUY-155) -----------------------------------------------------------------------
if ($Samples) {
    $make = Get-Command make -ErrorAction SilentlyContinue | Select-Object -First 1
    foreach ($s in (Get-ChildItem (Join-Path $Repo "samples") -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if (-not (Test-Path (Join-Path $s.FullName "Makefile"))) { continue }
        $where = "samples/$($s.Name)"
        if (-not $make) { Fail $where "has a Makefile and make was not found"; continue }
        $r = Run-Native $make.Source @("-C", $s.FullName, "test")
        if ($r.code -ne 0) { Fail $where "make test failed: $(($r.out -split "`n" | Select-Object -Last 3) -join ' | ')" }
    }
} else {
    Write-Host "samples not built (use -Samples)"
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Red }
    Write-Host "dev docs lint: $($problems.Count) problem(s)" -ForegroundColor Red
    exit 1
}
Write-Host "dev docs lint: $($files.Count) file(s), $n code block(s) ok"
exit 0
