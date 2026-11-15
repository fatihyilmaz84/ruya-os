# Lints the D-Bus system bus policies in image/rootfs/usr/share/dbus-1/system.d (T-423).
#   .\scripts\lint-bus-policies.ps1              check the tree
#   .\scripts\lint-bus-policies.ps1 -SelfTest    also prove each rule refuses its fixture
# Rules (every file):
#   1. A `<policy context="default">` has a `deny own="<name>"` and a `deny send_destination="<name>"` for
#      every bus name the file allows, and never an `allow` of any kind. dbus-broker's own system.conf already
#      denies `own` by default; the policy says so in writing (RUY-18), so it holds whatever another file
#      or a changed distribution default says.
#   2. `allow` appears only in `user="root"` and `user="ruya-shell"` policies, plus:
#      - `user="ruya-link"` (ADR-029): every allow names `send_destination` AND `send_member`
#        (never a whole destination or interface), and never `own`;
#      - a service user (ruya-library, ruya-input) may `allow own` only.
#   3. No other policy kind (group, at_console, mandatory, other users).
#   4. Signals (RUY-594): a service's signals are broadcasts, so for every bus name the file allows, the default
#      context has `deny receive_sender="<name>" receive_type="signal"` and BOTH `user="root"` and `user="ruya-shell"`
#      have `allow receive_sender="<name>" receive_type="signal"` (the receive rules always name receive_type=signal:
#      a rule without it would also drop a method reply, which ADR-029's ruya-link calls need).
#      The default deny is only that when it carries no other receive_* attribute and no eavesdrop (receive_member,
#      receive_interface, receive_path, receive_error, receive_requested_reply narrow it: `receive_member="Nothing"`
#      would close nothing), and root and ruya-shell have no receive deny at all (RUY-616).
param([string]$Root, [switch]$SelfTest)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = $Repo }
$ownerOnlyUsers = @("ruya-library", "ruya-input")

# The attributes that narrow a receive rule in dbus-daemon(1): with one of them the rule matches only some signals.
function Get-RecvNarrowing($Rule) {
    foreach ($a in $Rule.Attributes) {
        if (($a.Name -like "receive_*" -and $a.Name -notin @("receive_sender", "receive_type")) -or $a.Name -eq "eavesdrop") { $a.Name }
    }
}

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
    $deniedOwn = New-Object System.Collections.Generic.HashSet[string]
    $deniedRecv = New-Object System.Collections.Generic.HashSet[string]
    $allowedRecv = New-Object System.Collections.Generic.HashSet[string]   # "<user>|<name>"
    foreach ($p in $doc.SelectNodes("//policy")) {
        $ctx = $p.GetAttribute("context"); $user = $p.GetAttribute("user")
        $rules = @($p.ChildNodes | Where-Object { $_.NodeType -eq "Element" })
        if ($ctx -eq "default") {
            foreach ($r in $rules) {
                if ($r.LocalName -eq "allow") { $errs.Add("default context has an allow ($($r.OuterXml))") }
                elseif ($r.LocalName -eq "deny" -and $r.HasAttribute("send_destination")) { [void]$deniedNames.Add($r.GetAttribute("send_destination")) }
                elseif ($r.LocalName -eq "deny" -and $r.HasAttribute("own")) { [void]$deniedOwn.Add($r.GetAttribute("own")) }
                elseif ($r.LocalName -eq "deny" -and $r.HasAttribute("receive_sender")) {
                    $narrow = @(Get-RecvNarrowing $r)
                    if ($narrow.Count -gt 0) { $errs.Add("a narrowed receive deny does not close the default: it also names $($narrow -join ', ') ($($r.OuterXml))") }
                    elseif ($r.GetAttribute("receive_type") -eq "signal") { [void]$deniedRecv.Add($r.GetAttribute("receive_sender")) }
                    else { $errs.Add("a receive deny must name receive_type=signal ($($r.OuterXml))") }
                }
            }
            continue
        }
        if ($ctx -or ($user -notin @("root", "ruya-shell", "ruya-link") -and $user -notin $ownerOnlyUsers)) {
            $errs.Add("policy kind not allowed: $($p.OuterXml.Substring(0, [Math]::Min(60, $p.OuterXml.Length)))")
            continue
        }
        foreach ($r in $rules) {
            if ($r.LocalName -eq "deny" -and $user -in @("root", "ruya-shell") -and (@($r.Attributes | Where-Object { $_.Name -like "receive_*" }).Count -gt 0)) {
                $errs.Add("a receive deny in the $user policy would cut it off from the service's signals ($($r.OuterXml))")
            }
            if ($r.LocalName -ne "allow") { continue }
            foreach ($a in "own", "send_destination") { if ($r.HasAttribute($a)) { [void]$allowedNames.Add($r.GetAttribute($a)) } }
            if ($r.HasAttribute("receive_sender") -and $user -in @("root", "ruya-shell")) {
                if ($r.GetAttribute("receive_type") -eq "signal") { [void]$allowedRecv.Add("$user|$($r.GetAttribute('receive_sender'))") }
                else { $errs.Add("a receive allow must name receive_type=signal ($($r.OuterXml))") }
            }
            if ($user -eq "ruya-link") {
                if ($r.HasAttribute("own")) { $errs.Add("ruya-link may not own a name ($($r.OuterXml))") }
                if (-not ($r.HasAttribute("send_destination") -and $r.HasAttribute("send_member"))) { $errs.Add("ruya-link allow needs send_destination and send_member ($($r.OuterXml))") }
                foreach ($a in "send_destination", "send_member") {
                    $v = $r.GetAttribute($a)
                    if ($r.HasAttribute($a) -and ([string]::IsNullOrWhiteSpace($v) -or $v.Contains("*"))) { $errs.Add("ruya-link $a must be an exact name, not empty or a wildcard ($($r.OuterXml))") }
                }
            } elseif ($user -in $ownerOnlyUsers) {
                if (-not $r.HasAttribute("own") -or $r.Attributes.Count -ne 1) { $errs.Add("$user may only allow own ($($r.OuterXml))") }
            }
        }
    }
    foreach ($n in $allowedNames) {
        if (-not $deniedNames.Contains($n)) { $errs.Add("no default-context deny send_destination for $n") }
        if (-not $deniedOwn.Contains($n)) { $errs.Add("no default-context deny own for $n") }
        if (-not $deniedRecv.Contains($n)) { $errs.Add("no default-context deny receive_sender (receive_type signal) for $n") }
        foreach ($u in "root", "ruya-shell") {
            if (-not $allowedRecv.Contains("$u|$n")) { $errs.Add("$u has no allow receive_sender (receive_type signal) for $n") }
        }
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
  <policy user="root"><allow own="org.x.A1"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/></policy>
  <policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/></policy>
  <policy user="ruya-link"><allow send_destination="org.x.A1" send_member="Ping"/></policy>
  <policy context="default"><deny own="org.x.A1"/><deny send_destination="org.x.A1"/><deny receive_sender="org.x.A1" receive_type="signal"/></policy>
</busconfig>
'@
    $cases = @(
        @{ Name = "the good fixture (control)"; From = ""; To = ""; Expect = 0 },
        @{ Name = "a missing default deny"; From = '<deny send_destination="org.x.A1"/>'; To = ""; Expect = 1 },
        @{ Name = "a missing default deny own"; From = '<deny own="org.x.A1"/>'; To = ""; Expect = 1 },
        @{ Name = "a default deny own for another name"; From = '<deny own="org.x.A1"/>'; To = '<deny own="org.x.B1"/>'; Expect = 1 },
        @{ Name = "an allow in the default context"; From = '<deny send_destination="org.x.A1"/>'; To = '<deny send_destination="org.x.A1"/><allow send_destination="org.x.A1"/>'; Expect = 1 },
        @{ Name = "a missing default deny receive_sender"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = ""; Expect = 1 },
        @{ Name = "a default deny receive_sender without receive_type"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1"/>'; Expect = 1 },
        @{ Name = "no receive allow for ruya-shell"; From = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/></policy>'; To = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/></policy>'; Expect = 1 },
        @{ Name = "no receive allow for root"; From = '<allow own="org.x.A1"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; To = '<allow own="org.x.A1"/><allow send_destination="org.x.A1"/>'; Expect = 1 },
        @{ Name = "a receive allow without receive_type"; From = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; To = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1"/>'; Expect = 1 },
        @{ Name = "ruya-link receiving the service's signals"; From = '<allow send_destination="org.x.A1" send_member="Ping"/>'; To = '<allow send_destination="org.x.A1" send_member="Ping"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; Expect = 1 },
        @{ Name = "a default receive deny narrowed by receive_member"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1" receive_type="signal" receive_member="Nothing"/>'; Expect = 1 },
        @{ Name = "a default receive deny narrowed by receive_interface"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1" receive_type="signal" receive_interface="org.x.Nothing"/>'; Expect = 1 },
        @{ Name = "a default receive deny narrowed by receive_path"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1" receive_type="signal" receive_path="/nothing"/>'; Expect = 1 },
        @{ Name = "a default receive deny narrowed by receive_requested_reply"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1" receive_type="signal" receive_requested_reply="true"/>'; Expect = 1 },
        @{ Name = "a default receive deny with eavesdrop"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1" receive_type="signal" eavesdrop="true"/>'; Expect = 1 },
        @{ Name = "a receive deny in the root policy"; From = '<policy user="root"><allow own="org.x.A1"/>'; To = '<policy user="root"><deny receive_sender="org.x.A1" receive_type="signal"/><allow own="org.x.A1"/>'; Expect = 1 },
        @{ Name = "a receive deny in the ruya-shell policy"; From = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/>'; To = '<policy user="ruya-shell"><deny receive_sender="org.x.A1" receive_type="signal"/><allow send_destination="org.x.A1"/>'; Expect = 1 },
        @{ Name = "an allow for another user"; From = '<policy user="ruya-shell">'; To = '<policy user="nobody">'; Expect = 1 },
        @{ Name = "a group policy"; From = '<policy user="ruya-shell">'; To = '<policy group="wheel">'; Expect = 1 },
        @{ Name = "ruya-link allowing a whole destination"; From = ' send_member="Ping"'; To = ""; Expect = 1 },
        @{ Name = "ruya-link with a wildcard send_member"; From = 'send_member="Ping"'; To = 'send_member="*"'; Expect = 1 },
        @{ Name = "ruya-link with a wildcard send_destination"; From = '<allow send_destination="org.x.A1" send_member'; To = '<allow send_destination="*" send_member'; Expect = 1 },
        @{ Name = "ruya-link with an empty send_member"; From = 'send_member="Ping"'; To = 'send_member=""'; Expect = 1 },
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
