# Lints the D-Bus system bus policies in image/rootfs/usr/share/dbus-1/system.d (T-423).
#   .\scripts\lint-bus-policies.ps1              check the tree
#   .\scripts\lint-bus-policies.ps1 -SelfTest    also prove each rule refuses its fixture
# Rules (every file):
#   1. A `<policy context="default">` has a `deny send_destination="<name>"` for every bus name the file
#      allows, and never an `allow` of any kind (the system bus denies `own` and receive by default).
#   2. `allow` appears only in `user="root"` and `user="ruya-shell"` policies, plus:
#      - `user="ruya-link"` (ADR-029): every allow names `send_destination` AND `send_member`
#        (never a whole destination or interface), and never `own`;
#      - a service user (ruya-library) may `allow own` only.
#   3. No other policy kind (group, at_console, mandatory, other users).
param([string]$Root, [switch]$SelfTest)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = $Repo }
$ownerOnlyUsers = @("ruya-library")

function Test-BusPolicyFile([string]$Path) {
    $errs = New-Object System.Collections.Generic.List[string]
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    try {
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        try { $doc.Load($reader) } finally { $reader.Dispose() }
    } catch { return @("not valid XML: $($_.Exception.Message)") }

    $allowedNames = New-Object System.Collections.Generic.HashSet[string]
    $deniedNames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $doc.SelectNodes("//policy")) {
        $ctx = $p.GetAttribute("context"); $user = $p.GetAttribute("user")
        $rules = @($p.ChildNodes | Where-Object { $_.NodeType -eq "Element" })
        if ($ctx -eq "default") {
            foreach ($r in $rules) {
                if ($r.LocalName -eq "allow") { $errs.Add("default context has an allow ($($r.OuterXml))") }
                elseif ($r.LocalName -eq "deny" -and $r.HasAttribute("send_destination")) { [void]$deniedNames.Add($r.GetAttribute("send_destination")) }
            }
            continue
        }
        if ($ctx -or ($user -notin @("root", "ruya-shell", "ruya-link") -and $user -notin $ownerOnlyUsers)) {
            $errs.Add("policy kind not allowed: $($p.OuterXml.Substring(0, [Math]::Min(60, $p.OuterXml.Length)))")
            continue
        }
        foreach ($r in $rules) {
            if ($r.LocalName -ne "allow") { continue }
            foreach ($a in "own", "send_destination") { if ($r.HasAttribute($a)) { [void]$allowedNames.Add($r.GetAttribute($a)) } }
            if ($user -eq "ruya-link") {
                if ($r.HasAttribute("own")) { $errs.Add("ruya-link may not own a name ($($r.OuterXml))") }
                if (-not ($r.HasAttribute("send_destination") -and $r.HasAttribute("send_member"))) { $errs.Add("ruya-link allow needs send_destination and send_member ($($r.OuterXml))") }
            } elseif ($user -in $ownerOnlyUsers) {
                if (-not $r.HasAttribute("own") -or $r.Attributes.Count -ne 1) { $errs.Add("$user may only allow own ($($r.OuterXml))") }
            }
        }
    }
    foreach ($n in $allowedNames) {
        if (-not $deniedNames.Contains($n)) { $errs.Add("no default-context deny send_destination for $n") }
    }
    if ($allowedNames.Count -eq 0 -and $deniedNames.Count -eq 0) { $errs.Add("no policy rules found") }
    return $errs
}

function Test-BusPolicies([string]$Dir) {
    $files = @(Get-ChildItem -Path $Dir -Filter "*.conf" -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host "FAIL: no policy files in $Dir"; return 1 }
    $bad = 0
    foreach ($f in $files) {
        $e = @(Test-BusPolicyFile $f.FullName)
        foreach ($m in $e) { Write-Host "FAIL: $($f.Name): $m"; $bad++ }
    }
    return $bad
}

$policyDir = Join-Path $Root "image/rootfs/usr/share/dbus-1/system.d"
$bad = Test-BusPolicies $policyDir
if ($bad -eq 0) { Write-Host "ok: bus policies are deny-by-default" }

if ($SelfTest) {
    $good = @'
<busconfig>
  <policy user="root"><allow own="org.x.A1"/><allow send_destination="org.x.A1"/></policy>
  <policy user="ruya-shell"><allow send_destination="org.x.A1"/></policy>
  <policy user="ruya-link"><allow send_destination="org.x.A1" send_member="Ping"/></policy>
  <policy context="default"><deny send_destination="org.x.A1"/></policy>
</busconfig>
'@
    $cases = @(
        @{ Name = "the good fixture (control)"; From = ""; To = ""; Expect = 0 },
        @{ Name = "a missing default deny"; From = '<deny send_destination="org.x.A1"/>'; To = ""; Expect = 1 },
        @{ Name = "an allow in the default context"; From = '<deny send_destination="org.x.A1"/>'; To = '<deny send_destination="org.x.A1"/><allow send_destination="org.x.A1"/>'; Expect = 1 },
        @{ Name = "an allow for another user"; From = '<policy user="ruya-shell">'; To = '<policy user="nobody">'; Expect = 1 },
        @{ Name = "a group policy"; From = '<policy user="ruya-shell">'; To = '<policy group="wheel">'; Expect = 1 },
        @{ Name = "ruya-link allowing a whole destination"; From = ' send_member="Ping"'; To = ""; Expect = 1 },
        @{ Name = "ruya-link owning a name"; From = '<allow send_destination="org.x.A1" send_member="Ping"/>'; To = '<allow own="org.x.A1"/>'; Expect = 1 }
    )
    foreach ($c in $cases) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-bus-" + [guid]::NewGuid().ToString("N"))
        $pd = Join-Path $dir "image/rootfs/usr/share/dbus-1/system.d"
        New-Item -ItemType Directory -Force $pd | Out-Null
        $text = if ($c.From) { $good.Replace($c.From, $c.To) } else { $good }
        if ($c.From -and $text -eq $good) { Write-Host "FAIL: self-test fixture for $($c.Name) did not change"; $bad++ }
        [IO.File]::WriteAllText((Join-Path $pd "org.x.A1.conf"), $text)
        $n = Test-BusPolicies $pd 6>&1 | Where-Object { $_ -is [int] } | Select-Object -Last 1
        $failed = [bool]($n -gt 0)
        $want = ($c.Expect -gt 0)
        if ($failed -ne $want) { Write-Host "FAIL: self-test: lint $(if ($want) {'accepted'} else {'refused'}) $($c.Name)"; $bad++ }
        Remove-Item -Recurse -Force $dir
    }
    if ($bad -eq 0) { Write-Host "ok: each bus policy rule refuses its fixture" }
}
if ($bad -gt 0) { exit 1 }
exit 0
