# Lints the D-Bus system bus policies in image/rootfs/usr/share/dbus-1/system.d (T-423).
#   .\scripts\lint-bus-policies.ps1              check the tree
#   .\scripts\lint-bus-policies.ps1 -SelfTest    also prove each rule refuses its fixture
# Rules (every file):
#   1. A `<policy context="default">` has a `deny own="<name>"` and a `deny send_destination="<name>"` for
#      every bus name the file allows, and no `allow` but a public door's. dbus-broker's own system.conf already
#      denies `own` by default; the policy says so in writing (RUY-18), so it holds whatever another file
#      or a changed distribution default says.
#      Public doors (ADR-022, RUY-157): image/security-baseline.json "public_bus_doors" names the bus names
#      (today only org.ruyaos.Platform1) and the interfaces each may open to every user, and every element of
#      a listed interface must be tagged org.ruyaos.Stability in api/dbus/<name>.xml. Their default-context
#      allows have exactly one of two shapes, after the name's default deny: `send_destination` +
#      `send_interface` + `send_type="method_call"`, or `receive_sender` + `receive_interface` +
#      `receive_type="signal"`. vm-security-check.sh busrecv reads the same list.
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
#   5. Root-only members (RUY-1056): a method that api/dbus/<name>.xml marks
#      `<annotation name="org.ruyaos.Caller" value="root"/>` is denied to ruya-shell in writing: the
#      `user="ruya-shell"` policy has `deny send_destination="<name>" send_member="<method>"` AFTER its
#      last `allow send_destination="<name>"` (in dbus policy the last matching rule wins).
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

# The methods api/dbus/<name>.xml marks root only (org.ruyaos.Caller = root); none without that file.
function Get-RootOnlyMembers([string]$ApiDir, [string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9_.]+$') { return @() }   # a wildcard or empty name (refused by rule 2)
    $xml = Join-Path $ApiDir "$Name.xml"
    if (-not (Test-Path $xml)) { return @() }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $reader = [System.Xml.XmlReader]::Create($xml, $settings)
    try { $doc.Load($reader) } finally { $reader.Dispose() }
    foreach ($m in $doc.SelectNodes("//interface/method")) {
        foreach ($an in $m.SelectNodes("annotation")) {
            if ($an.GetAttribute("name") -eq "org.ruyaos.Caller" -and $an.GetAttribute("value") -eq "root") { $m.GetAttribute("name") }
        }
    }
}

# The public doors (image/security-baseline.json "public_bus_doors"): bus name -> the interfaces a
# default-context allow may open. Each listed interface must exist in api/dbus/<name>.xml with every
# method, signal and property tagged org.ruyaos.Stability (a public element, ADR-022).
function Get-PublicDoors([string]$BaselinePath, [string]$ApiDir) {
    $doors = @{}; $problems = @()
    if (-not (Test-Path $BaselinePath)) { return @{ Doors = $doors; Problems = @("no $BaselinePath") } }
    $json = Get-Content -Raw $BaselinePath | ConvertFrom-Json
    if ($null -eq $json.public_bus_doors) { return @{ Doors = $doors; Problems = $problems } }
    foreach ($p in $json.public_bus_doors.PSObject.Properties) {
        if ($p.Name -like "_*") { continue }
        $doors[$p.Name] = @($p.Value)
        $xml = Join-Path $ApiDir "$($p.Name).xml"
        if (-not (Test-Path $xml)) { $problems += "public door $($p.Name) has no $xml"; continue }
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $doc = New-Object System.Xml.XmlDocument
        $reader = [System.Xml.XmlReader]::Create($xml, $settings)
        try { $doc.Load($reader) } finally { $reader.Dispose() }
        foreach ($i in $doors[$p.Name]) {
            $iface = $doc.SelectSingleNode("//interface[@name='$i']")
            if ($null -eq $iface) { $problems += "public door $($p.Name): interface $i is not in $xml"; continue }
            foreach ($el in $iface.SelectNodes("method|signal|property")) {
                if ($null -eq $el.SelectSingleNode("annotation[@name='org.ruyaos.Stability']")) {
                    $problems += "public door $($p.Name): $i.$($el.GetAttribute('name')) is not tagged org.ruyaos.Stability"
                }
            }
        }
    }
    return @{ Doors = $doors; Problems = $problems }
}

# Why a default-context allow is refused, or nothing when it is a public door's allow: exactly
# send_destination + send_interface (+ send_type="method_call"), or receive_sender + receive_interface +
# receive_type="signal", for a listed name and interface, after that name's deny in the same policy.
function Test-DoorAllow($Rule, $Doors, $DeniedNames, $DeniedRecv) {
    $attrs = @($Rule.Attributes | ForEach-Object { $_.Name } | Sort-Object)
    if ($Rule.HasAttribute("send_destination")) {
        $name = $Rule.GetAttribute("send_destination"); $iface = $Rule.GetAttribute("send_interface")
        $shape = (($attrs -join ",") -eq "send_destination,send_interface,send_type" -and $Rule.GetAttribute("send_type") -eq "method_call")
        $denied = $DeniedNames.Contains($name)
    } elseif ($Rule.HasAttribute("receive_sender")) {
        $name = $Rule.GetAttribute("receive_sender"); $iface = $Rule.GetAttribute("receive_interface")
        $shape = (($attrs -join ",") -eq "receive_interface,receive_sender,receive_type" -and $Rule.GetAttribute("receive_type") -eq "signal")
        $denied = $DeniedRecv.Contains($name)
    } else { return "is not a public door's send or receive" }
    if (-not $Doors.ContainsKey($name)) { return "is for $name, which is not a public door (security-baseline.json public_bus_doors)" }
    if (-not $shape) { return "is not exactly a door's shape (send_destination + send_interface + send_type=method_call, or receive_sender + receive_interface + receive_type=signal)" }
    if ($iface -notin $Doors[$name]) { return "opens $iface, which is not a public interface of $name" }
    if (-not $denied) { return "comes before the default deny of $name (the last matching rule wins: the allow must follow it)" }
    return $null
}

function Test-BusPolicyFile([string]$Path, [string]$ApiDir, $Doors) {
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
                if ($r.LocalName -eq "allow") {
                    $why = Test-DoorAllow $r $Doors $deniedNames $deniedRecv
                    if ($why) { $errs.Add("default context has an allow that $why ($($r.OuterXml))") }
                }
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
    # Rule 5: every root-only member of a name the file allows is denied to ruya-shell after its allow.
    $shellRules = @()
    foreach ($p in $doc.SelectNodes("//policy")) {
        if ($p.GetAttribute("user") -eq "ruya-shell") { $shellRules += @($p.ChildNodes | Where-Object { $_.NodeType -eq "Element" }) }
    }
    foreach ($n in $allowedNames) {
        foreach ($member in @(Get-RootOnlyMembers $ApiDir $n)) {
            $lastAllow = -1; $deny = -1
            for ($i = 0; $i -lt $shellRules.Count; $i++) {
                $r = $shellRules[$i]
                if ($r.GetAttribute("send_destination") -ne $n) { continue }
                if ($r.LocalName -eq "allow") { $lastAllow = $i }
                elseif ($r.LocalName -eq "deny" -and $r.GetAttribute("send_member") -eq $member) { $deny = $i }
            }
            if ($deny -lt 0) { $errs.Add("$n.$member is root only (org.ruyaos.Caller) but ruya-shell has no deny send_member=`"$member`"") }
            elseif ($deny -lt $lastAllow) { $errs.Add("the ruya-shell deny of $n.$member comes before an allow of $n, which wins") }
        }
    }
    if ($allowedNames.Count -eq 0 -and $deniedNames.Count -eq 0) { $errs.Add("no policy rules found") }
    return $errs
}

function Test-BusPolicies([string]$Dir, [string]$ApiDir, $Doors) {
    $files = @(Get-ChildItem -Path $Dir -Filter "*.conf" -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host "FAIL: no policy files in $Dir"; return 1 }
    $bad = 0
    foreach ($f in $files) {
        $e = @(Test-BusPolicyFile $f.FullName $ApiDir $Doors)
        foreach ($m in $e) { Write-Host "FAIL: $($f.Name): $m"; $bad++ }
    }
    return $bad
}

$policyDir = Join-Path $Root "image/rootfs/usr/share/dbus-1/system.d"
$apiDir = Join-Path $Root "api/dbus"
$publicDoors = Get-PublicDoors (Join-Path $Root "image/security-baseline.json") $apiDir
$bad = 0
foreach ($m in $publicDoors.Problems) { Write-Host "FAIL: $m"; $bad++ }
$bad += Test-BusPolicies $policyDir $apiDir $publicDoors.Doors
if ($bad -eq 0) { Write-Host "ok: bus policies are deny-by-default (public doors: $(@($publicDoors.Doors.Keys) -join ', '))" }

if ($SelfTest) {
    $good = @'
<busconfig>
  <policy user="root"><allow own="org.x.A1"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/></policy>
  <policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/><deny send_destination="org.x.A1" send_member="Put"/></policy>
  <policy user="ruya-link"><allow send_destination="org.x.A1" send_member="Ping"/></policy>
  <policy context="default"><deny own="org.x.A1"/><deny send_destination="org.x.A1"/><deny receive_sender="org.x.A1" receive_type="signal"/><allow send_destination="org.x.A1" send_interface="org.x.A1.Pub" send_type="method_call"/><allow receive_sender="org.x.A1" receive_interface="org.x.A1.Pub" receive_type="signal"/></policy>
</busconfig>
'@
    # The contract of org.x.A1: Put is root only, Get is not; org.x.A1.Pub is public (tagged), the door the
    # fixture opens to every user (security-baseline.json public_bus_doors, ADR-022).
    $api = '<node><interface name="org.x.A1"><method name="Put"><annotation name="org.ruyaos.Caller" value="root"/></method><method name="Get"/></interface><interface name="org.x.A1.Pub"><method name="Hi"><annotation name="org.ruyaos.Stability" value="experimental"/></method></interface></node>'
    $doorAllow = '<allow send_destination="org.x.A1" send_interface="org.x.A1.Pub" send_type="method_call"/>'
    $doorRecv = '<allow receive_sender="org.x.A1" receive_interface="org.x.A1.Pub" receive_type="signal"/>'
    $cases = @(
        @{ Name = "the good fixture (control)"; From = ""; To = ""; Expect = 0 },
        @{ Name = "a missing default deny"; From = '<deny send_destination="org.x.A1"/>'; To = ""; Expect = 1 },
        @{ Name = "a missing default deny own"; From = '<deny own="org.x.A1"/>'; To = ""; Expect = 1 },
        @{ Name = "a default deny own for another name"; From = '<deny own="org.x.A1"/>'; To = '<deny own="org.x.B1"/>'; Expect = 1 },
        @{ Name = "an allow in the default context"; From = '<deny send_destination="org.x.A1"/>'; To = '<deny send_destination="org.x.A1"/><allow send_destination="org.x.A1"/>'; Expect = 1 },
        @{ Name = "a missing default deny receive_sender"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = ""; Expect = 1 },
        @{ Name = "a default deny receive_sender without receive_type"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1"/>'; Expect = 1 },
        @{ Name = "no receive allow for ruya-shell"; From = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; To = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/>'; Expect = 1 },
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
        @{ Name = "ruya-link owning a name"; From = '<allow send_destination="org.x.A1" send_member="Ping"/>'; To = '<allow own="org.x.A1"/>'; Expect = 1 },
        @{ Name = "a root-only member not denied to ruya-shell"; From = '<deny send_destination="org.x.A1" send_member="Put"/>'; To = ""; Expect = 1 },
        @{ Name = "a root-only member denied for another member"; From = 'send_member="Put"/></policy>'; To = 'send_member="Get"/></policy>'; Expect = 1 },
        @{ Name = "a door's allow before its default deny"; From = '<deny send_destination="org.x.A1"/><deny receive_sender'; To = $doorAllow.Replace('/>', '/><deny send_destination="org.x.A1"/><deny receive_sender'); Expect = 1 },
        @{ Name = "a door's send allow narrowed to a member (another shape)"; From = $doorAllow; To = $doorAllow.Replace('send_type=', 'send_member="Hi" send_type='); Expect = 1 },
        @{ Name = "a door's send allow without send_type"; From = $doorAllow; To = $doorAllow.Replace(' send_type="method_call"', ''); Expect = 1 },
        @{ Name = "a door's allow of a non-public interface"; From = $doorAllow; To = $doorAllow.Replace('org.x.A1.Pub', 'org.x.A1'); Expect = 1 },
        @{ Name = "a door's receive allow of a non-public interface"; From = $doorRecv; To = $doorRecv.Replace('org.x.A1.Pub', 'org.x.A1'); Expect = 1 },
        @{ Name = "a door's receive allow without receive_type"; From = $doorRecv; To = $doorRecv.Replace(' receive_type="signal"', ''); Expect = 1 },
        @{ Name = "a door's allow for a name that is not a door"; From = ""; To = ""; NoDoor = $true; Expect = 1 },
        @{ Name = "a root-only deny before the allow it should override"; From = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/><deny send_destination="org.x.A1" send_member="Put"/>'; To = '<policy user="ruya-shell"><deny send_destination="org.x.A1" send_member="Put"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; Expect = 1 }
    )
    foreach ($c in $cases) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-bus-" + [guid]::NewGuid().ToString("N"))
        $pd = Join-Path $dir "image/rootfs/usr/share/dbus-1/system.d"
        New-Item -ItemType Directory -Force $pd | Out-Null
        $text = if ($c.From) { $good.Replace($c.From, $c.To) } else { $good }
        if ($c.From -and $text -eq $good) { Write-Host "FAIL: self-test fixture for $($c.Name) did not change"; $bad++ }
        [IO.File]::WriteAllText((Join-Path $pd "org.x.A1.conf"), $text)
        $ad = Join-Path $dir "api/dbus"
        New-Item -ItemType Directory -Force $ad | Out-Null
        [IO.File]::WriteAllText((Join-Path $ad "org.x.A1.xml"), $api)
        $doors = if ($c.NoDoor) { @{} } else { @{ "org.x.A1" = @("org.x.A1.Pub") } }
        $n = Test-BusPolicies $pd $ad $doors 6>&1 | Where-Object { $_ -is [int] } | Select-Object -Last 1
        $failed = [bool]($n -gt 0)
        $want = ($c.Expect -gt 0)
        if ($failed -ne $want) { Write-Host "FAIL: self-test: lint $(if ($want) {'accepted'} else {'refused'}) $($c.Name)"; $bad++ }
        Remove-Item -Recurse -Force $dir
    }
    # The door list itself: a listed interface with an untagged element, or one the XML lacks, is refused.
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-door-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir "org.x.A1.xml"), $api)
    foreach ($d in @(
        @{ Name = "a door whose interface is all tagged (control)"; Json = '{"public_bus_doors": {"org.x.A1": ["org.x.A1.Pub"]}}'; Expect = 0 },
        @{ Name = "a door listing an untagged interface"; Json = '{"public_bus_doors": {"org.x.A1": ["org.x.A1"]}}'; Expect = 1 },
        @{ Name = "a door listing an interface the XML lacks"; Json = '{"public_bus_doors": {"org.x.A1": ["org.x.A1.Nope"]}}'; Expect = 1 },
        @{ Name = "a door without a contract"; Json = '{"public_bus_doors": {"org.x.B1": ["org.x.B1.Pub"]}}'; Expect = 1 })) {
        $bp = Join-Path $dir "baseline.json"
        [IO.File]::WriteAllText($bp, $d.Json)
        $got = @((Get-PublicDoors $bp $dir).Problems).Count
        if (($got -gt 0) -ne ($d.Expect -gt 0)) { Write-Host "FAIL: self-test: door list $(if ($d.Expect) {'accepted'} else {'refused'}) $($d.Name)"; $bad++ }
    }
    Remove-Item -Recurse -Force $dir
    if ($bad -eq 0) { Write-Host "ok: each bus policy rule refuses its fixture" }
}
if ($bad -gt 0) { exit 1 }
exit 0
