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
#      - a service user (ruya-library, ruya-input) may `allow own`, plus one declared signal allow per entry of
#        image/security-baseline.json "service_signals" (ADR-045 amendment, owner 2026-11-25, RUY-1196): exactly the
#        attributes send_destination, send_type="signal", send_path, send_interface, send_member, all exact (no
#        wildcard, none empty), equal to an entry of that user, and the member is a <signal> of that interface in
#        api/dbus/<interface>.xml. Nothing else, never a method_call.
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
#      The annotation value is exactly "root" or an error naming the interface and member (RUY-1206): `Root`, `admin`
#      or an empty value would otherwise drop the required deny silently.
#   Every compare of a policy value (user, context, names, interface, member, send_type, receive_type) is
#   case-sensitive (-c*), as dbus-broker's: `user="Root"` is not root. A rule element is exactly `allow` or `deny`
#   (RUY-1199). The table of public doors is ordinal too: two doors differing only in case are two doors (RUY-1206).
param([string]$Root, [switch]$SelfTest)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = $Repo }
$ownerOnlyUsers = @("ruya-library", "ruya-input")

# The attributes that narrow a receive rule in dbus-daemon(1): with one of them the rule matches only some signals.
# Attribute names are matched case-insensitively here and in the receive-deny check on purpose: a rule that
# spells receive_* or eavesdrop in another case is still flagged (the strict direction); every VALUE compare
# in this file is case-sensitive (-c*), because dbus-broker matches values exactly (RUY-1199).
function Get-RecvNarrowing($Rule) {
    foreach ($a in $Rule.Attributes) {
        if (($a.Name -like "receive_*" -and $a.Name -notin @("receive_sender", "receive_type")) -or $a.Name -eq "eavesdrop") { $a.Name }
    }
}

# The methods api/dbus/<name>.xml marks root only (org.ruyaos.Caller = root), and the annotations it cannot read
# (a value that is not exactly "root"): { Members; Problems }, both empty without that file.
function Get-RootOnlyMembers([string]$ApiDir, [string]$Name) {
    $members = @(); $problems = @()
    if ($Name -cnotmatch '^[A-Za-z0-9_.]+$') { return @{ Members = $members; Problems = $problems } }   # a wildcard or empty name (refused by rule 2)
    $xml = Join-Path $ApiDir "$Name.xml"
    if (-not (Test-Path $xml)) { return @{ Members = $members; Problems = $problems } }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $reader = [System.Xml.XmlReader]::Create($xml, $settings)
    try { $doc.Load($reader) } finally { $reader.Dispose() }
    foreach ($m in $doc.SelectNodes("//interface/method")) {
        foreach ($an in $m.SelectNodes("annotation")) {
            # The annotation NAME is matched case-insensitively (the strict direction: a marker spelled in another case is
            # still read, never skipped). Its VALUE is exactly "root" or an error: a value this lint cannot read exactly
            # (`Root`, `admin`, empty) would otherwise drop the required ruya-shell deny without a word (RUY-1206).
            if ($an.GetAttribute("name") -ne "org.ruyaos.Caller") { continue }
            $value = $an.GetAttribute("value")
            if ($value -ceq "root") { $members += $m.GetAttribute("name") }
            else { $problems += "${xml}: $($m.ParentNode.GetAttribute('name')).$($m.GetAttribute('name')) has org.ruyaos.Caller value `"$value`", which is not exactly `"root`"" }
        }
    }
    return @{ Members = $members; Problems = $problems }
}

# The table of public doors, keyed by bus name. Ordinal: a PowerShell `@{}` ignores case, so two doors that differ
# only in case would merge into one key (the later list replacing the first) and one would answer for the other;
# dbus-broker matches names exactly (RUY-1206).
function New-DoorTable { return (New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)) }

# The public doors (image/security-baseline.json "public_bus_doors"): bus name -> the interfaces a
# default-context allow may open. Each listed interface must exist in api/dbus/<name>.xml with every
# method, signal and property tagged org.ruyaos.Stability (a public element, ADR-022).
function Get-PublicDoors([string]$BaselinePath, [string]$ApiDir) {
    $doors = New-DoorTable; $problems = @()
    if (-not (Test-Path $BaselinePath)) { return @{ Doors = $doors; Problems = @("no $BaselinePath") } }
    $json = Get-Content -Raw $BaselinePath | ConvertFrom-Json
    if ($null -eq $json.public_bus_doors) { return @{ Doors = $doors; Problems = $problems } }
    foreach ($p in $json.public_bus_doors.PSObject.Properties) {
        if ($p.Name -clike "_*") { continue }
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

# The declared service signals (image/security-baseline.json "service_signals", RUY-1196): a list of
# {user, destination, path, interface, member}: the one signal a service user may send to another service.
function Get-ServiceSignals([string]$BaselinePath) {
    $list = @()
    if (-not (Test-Path $BaselinePath)) { return $list }
    $json = Get-Content -Raw $BaselinePath | ConvertFrom-Json
    if ($null -eq $json.service_signals) { return $list }
    foreach ($s in @($json.service_signals)) {
        $list += @{ user = [string]$s.user; destination = [string]$s.destination; path = [string]$s.path; interface = [string]$s.interface; member = [string]$s.member; reason = [string]$s.reason }
    }
    return $list
}

# Why a "service_signals" entry itself is refused: an empty field or a wildcard, or no reason (every baseline entry has one).
function Test-ServiceSignalList($Signals) {
    foreach ($s in $Signals) {
        $who = "service_signals $($s.user) -> $($s.destination) $($s.interface).$($s.member)"
        foreach ($k in "user", "destination", "path", "interface", "member") {
            if ([string]::IsNullOrWhiteSpace($s[$k]) -or $s[$k].Contains("*")) { "${who}: $k must be exact, not empty or a wildcard" }
        }
        if ([string]::IsNullOrWhiteSpace($s.reason)) { "${who}: no reason" }
    }
}

# Why a service user's allow is refused, or nothing when it is a declared service signal (rule 2).
function Test-ServiceSignalAllow($Rule, [string]$User, $Signals, [string]$ApiDir) {
    $attrs = (@($Rule.Attributes | ForEach-Object { $_.Name } | Sort-Object)) -join ","
    # Every compare here is case-sensitive (-c*): dbus-broker matches names and types exactly.
    if ($attrs -cne "send_destination,send_interface,send_member,send_path,send_type") {
        return "may only allow own or a declared signal (send_destination, send_type, send_path, send_interface, send_member and nothing else)"
    }
    if ($Rule.GetAttribute("send_type") -cne "signal") { return "may only send a signal: send_type must be `"signal`"" }
    foreach ($a in "send_destination", "send_path", "send_interface", "send_member") {
        $v = $Rule.GetAttribute($a)
        if ([string]::IsNullOrWhiteSpace($v) -or $v.Contains("*")) { return "needs an exact $a, not empty or a wildcard" }
    }
    $dest = $Rule.GetAttribute("send_destination"); $path = $Rule.GetAttribute("send_path")
    $iface = $Rule.GetAttribute("send_interface"); $member = $Rule.GetAttribute("send_member")
    $declared = @($Signals | Where-Object { $_.user -ceq $User -and $_.destination -ceq $dest -and $_.path -ceq $path -and $_.interface -ceq $iface -and $_.member -ceq $member })
    if ($declared.Count -eq 0) { return "is not declared in security-baseline.json service_signals" }
    $xml = Join-Path $ApiDir "$iface.xml"
    if (-not (Test-Path $xml)) { return "sends $iface.$member, but there is no $xml" }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $reader = [System.Xml.XmlReader]::Create($xml, $settings)
    try { $doc.Load($reader) } finally { $reader.Dispose() }
    if ($null -eq $doc.SelectSingleNode("//interface[@name='$iface']/signal[@name='$member']")) { return "sends $member, which is not a <signal> of $iface in $xml" }
    return $null
}

# Why a default-context allow is refused, or nothing when it is a public door's allow: exactly
# send_destination + send_interface (+ send_type="method_call"), or receive_sender + receive_interface +
# receive_type="signal", for a listed name and interface, after that name's deny in the same policy.
function Test-DoorAllow($Rule, $Doors, $DeniedNames, $DeniedRecv) {
    $attrs = @($Rule.Attributes | ForEach-Object { $_.Name } | Sort-Object)
    if ($Rule.HasAttribute("send_destination")) {
        $name = $Rule.GetAttribute("send_destination"); $iface = $Rule.GetAttribute("send_interface")
        $shape = (($attrs -join ",") -ceq "send_destination,send_interface,send_type" -and $Rule.GetAttribute("send_type") -ceq "method_call")
        $denied = $DeniedNames.Contains($name)
    } elseif ($Rule.HasAttribute("receive_sender")) {
        $name = $Rule.GetAttribute("receive_sender"); $iface = $Rule.GetAttribute("receive_interface")
        $shape = (($attrs -join ",") -ceq "receive_interface,receive_sender,receive_type" -and $Rule.GetAttribute("receive_type") -ceq "signal")
        $denied = $DeniedRecv.Contains($name)
    } else { return "is not a public door's send or receive" }
    # Compare the door names (the keys) with -ccontains whatever table the caller built (New-DoorTable is ordinal).
    if (@($Doors.Keys) -cnotcontains $name) { return "is for $name, which is not a public door (security-baseline.json public_bus_doors)" }
    if (-not $shape) { return "is not exactly a door's shape (send_destination + send_interface + send_type=method_call, or receive_sender + receive_interface + receive_type=signal)" }
    if (@($Doors[$name]) -cnotcontains $iface) { return "opens $iface, which is not a public interface of $name" }
    if (-not $denied) { return "comes before the default deny of $name (the last matching rule wins: the allow must follow it)" }
    return $null
}

function Test-BusPolicyFile([string]$Path, [string]$ApiDir, $Doors, $Signals) {
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
        # A rule element is exactly allow or deny: the compares below are case-sensitive, so `<Allow .../>` would
        # otherwise be neither and slip past every check (dbus-broker does not know it either).
        foreach ($r in $rules) {
            if ($r.LocalName -cnotin @("allow", "deny")) { $errs.Add("a policy rule must be exactly allow or deny ($($r.OuterXml))") }
        }
        if ($ctx -ceq "default") {
            foreach ($r in $rules) {
                if ($r.LocalName -ceq "allow") {
                    $why = Test-DoorAllow $r $Doors $deniedNames $deniedRecv
                    if ($why) { $errs.Add("default context has an allow that $why ($($r.OuterXml))") }
                }
                elseif ($r.LocalName -ceq "deny" -and $r.HasAttribute("send_destination")) { [void]$deniedNames.Add($r.GetAttribute("send_destination")) }
                elseif ($r.LocalName -ceq "deny" -and $r.HasAttribute("own")) { [void]$deniedOwn.Add($r.GetAttribute("own")) }
                elseif ($r.LocalName -ceq "deny" -and $r.HasAttribute("receive_sender")) {
                    $narrow = @(Get-RecvNarrowing $r)
                    if ($narrow.Count -gt 0) { $errs.Add("a narrowed receive deny does not close the default: it also names $($narrow -join ', ') ($($r.OuterXml))") }
                    elseif ($r.GetAttribute("receive_type") -ceq "signal") { [void]$deniedRecv.Add($r.GetAttribute("receive_sender")) }
                    else { $errs.Add("a receive deny must name receive_type=signal ($($r.OuterXml))") }
                }
            }
            continue
        }
        if ($ctx -or ($user -cnotin @("root", "ruya-shell", "ruya-link") -and $user -cnotin $ownerOnlyUsers)) {
            $errs.Add("policy kind not allowed: $($p.OuterXml.Substring(0, [Math]::Min(60, $p.OuterXml.Length)))")
            continue
        }
        foreach ($r in $rules) {
            if ($r.LocalName -ceq "deny" -and $user -cin @("root", "ruya-shell") -and (@($r.Attributes | Where-Object { $_.Name -like "receive_*" }).Count -gt 0)) {
                $errs.Add("a receive deny in the $user policy would cut it off from the service's signals ($($r.OuterXml))")
            }
            if ($r.LocalName -cne "allow") { continue }
            foreach ($a in "own", "send_destination") { if ($r.HasAttribute($a)) { [void]$allowedNames.Add($r.GetAttribute($a)) } }
            if ($r.HasAttribute("receive_sender") -and $user -cin @("root", "ruya-shell")) {
                if ($r.GetAttribute("receive_type") -ceq "signal") { [void]$allowedRecv.Add("$user|$($r.GetAttribute('receive_sender'))") }
                else { $errs.Add("a receive allow must name receive_type=signal ($($r.OuterXml))") }
            }
            if ($user -ceq "ruya-link") {
                if ($r.HasAttribute("own")) { $errs.Add("ruya-link may not own a name ($($r.OuterXml))") }
                if (-not ($r.HasAttribute("send_destination") -and $r.HasAttribute("send_member"))) { $errs.Add("ruya-link allow needs send_destination and send_member ($($r.OuterXml))") }
                foreach ($a in "send_destination", "send_member") {
                    $v = $r.GetAttribute($a)
                    if ($r.HasAttribute($a) -and ([string]::IsNullOrWhiteSpace($v) -or $v.Contains("*"))) { $errs.Add("ruya-link $a must be an exact name, not empty or a wildcard ($($r.OuterXml))") }
                }
            } elseif ($user -cin $ownerOnlyUsers) {
                if ($r.HasAttribute("own")) {
                    if ($r.Attributes.Count -ne 1) { $errs.Add("$user may only allow own ($($r.OuterXml))") }
                } else {
                    $why = Test-ServiceSignalAllow $r $user $Signals $ApiDir
                    if ($why) { $errs.Add("$user $why ($($r.OuterXml))") }
                }
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
        if ($p.GetAttribute("user") -ceq "ruya-shell") { $shellRules += @($p.ChildNodes | Where-Object { $_.NodeType -eq "Element" }) }
    }
    foreach ($n in $allowedNames) {
        $callers = Get-RootOnlyMembers $ApiDir $n
        foreach ($why in $callers.Problems) { $errs.Add($why) }
        foreach ($member in $callers.Members) {
            $lastAllow = -1; $deny = -1
            for ($i = 0; $i -lt $shellRules.Count; $i++) {
                $r = $shellRules[$i]
                if ($r.GetAttribute("send_destination") -cne $n) { continue }
                if ($r.LocalName -ceq "allow") { $lastAllow = $i }
                elseif ($r.LocalName -ceq "deny" -and $r.GetAttribute("send_member") -ceq $member) { $deny = $i }
            }
            if ($deny -lt 0) { $errs.Add("$n.$member is root only (org.ruyaos.Caller) but ruya-shell has no deny send_member=`"$member`"") }
            elseif ($deny -lt $lastAllow) { $errs.Add("the ruya-shell deny of $n.$member comes before an allow of $n, which wins") }
        }
    }
    if ($allowedNames.Count -eq 0 -and $deniedNames.Count -eq 0) { $errs.Add("no policy rules found") }
    return $errs
}

function Test-BusPolicies([string]$Dir, [string]$ApiDir, $Doors, $Signals) {
    $files = @(Get-ChildItem -Path $Dir -Filter "*.conf" -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host "FAIL: no policy files in $Dir"; return 1 }
    $bad = 0
    foreach ($f in $files) {
        $e = @(Test-BusPolicyFile $f.FullName $ApiDir $Doors $Signals)
        foreach ($m in $e) { Write-Host "FAIL: $($f.Name): $m"; $bad++ }
    }
    return $bad
}

$policyDir = Join-Path $Root "image/rootfs/usr/share/dbus-1/system.d"
$apiDir = Join-Path $Root "api/dbus"
$publicDoors = Get-PublicDoors (Join-Path $Root "image/security-baseline.json") $apiDir
$serviceSignals = @(Get-ServiceSignals (Join-Path $Root "image/security-baseline.json"))
$bad = 0
foreach ($m in $publicDoors.Problems) { Write-Host "FAIL: $m"; $bad++ }
foreach ($m in @(Test-ServiceSignalList $serviceSignals)) { Write-Host "FAIL: $m"; $bad++ }
$bad += Test-BusPolicies $policyDir $apiDir $publicDoors.Doors $serviceSignals
if ($bad -eq 0) { Write-Host "ok: bus policies are deny-by-default (public doors: $(@($publicDoors.Doors.Keys) -join ', '); service signals: $($serviceSignals.Count))" }

if ($SelfTest) {
    $good = @'
<busconfig>
  <policy user="root"><allow own="org.x.A1"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/></policy>
  <policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/><deny send_destination="org.x.A1" send_member="Put"/></policy>
  <policy user="ruya-link"><allow send_destination="org.x.A1" send_member="Ping"/></policy>
  <policy user="ruya-library"><allow send_destination="org.x.A1" send_type="signal" send_path="/org/x/B1" send_interface="org.x.B1" send_member="Wanted"/></policy>
  <policy context="default"><deny own="org.x.A1"/><deny send_destination="org.x.A1"/><deny receive_sender="org.x.A1" receive_type="signal"/><allow send_destination="org.x.A1" send_interface="org.x.A1.Pub" send_type="method_call"/><allow receive_sender="org.x.A1" receive_interface="org.x.A1.Pub" receive_type="signal"/></policy>
</busconfig>
'@
    # The contract of org.x.A1: Put is root only, Get is not; org.x.A1.Pub is public (tagged), the door the
    # fixture opens to every user (security-baseline.json public_bus_doors, ADR-022).
    $api = '<node><interface name="org.x.A1"><method name="Put"><annotation name="org.ruyaos.Caller" value="root"/></method><method name="Get"/></interface><interface name="org.x.A1.Pub"><method name="Hi"><annotation name="org.ruyaos.Stability" value="experimental"/></method></interface></node>'
    # The signal a service user (ruya-library) may send to org.x.A1 (security-baseline.json service_signals, RUY-1196):
    # org.x.B1.Wanted is a <signal> of the contract api/dbus/org.x.B1.xml, org.x.B1.Call is a method.
    # org.x.B1 also declares a second signal (Other) and org.x.B2 declares the same Wanted, so a fixture can differ
    # from the baseline entry in exactly one of member or interface.
    $apiB = '<node><interface name="org.x.B1"><signal name="Wanted"/><signal name="Other"/><method name="Call"/></interface></node>'
    $apiB2 = '<node><interface name="org.x.B2"><signal name="Wanted"/></interface></node>'
    $sigAllow = '<allow send_destination="org.x.A1" send_type="signal" send_path="/org/x/B1" send_interface="org.x.B1" send_member="Wanted"/>'
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
        @{ Name = "a service signal without send_type"; From = $sigAllow; To = $sigAllow.Replace(' send_type="signal"', ''); Expect = 1 },
        @{ Name = "a service allow of a method_call"; From = $sigAllow; To = $sigAllow.Replace('send_type="signal"', 'send_type="method_call"'); Expect = 1 },
        @{ Name = "a service signal with a wildcard member"; From = $sigAllow; To = $sigAllow.Replace('send_member="Wanted"', 'send_member="*"'); SigMember = "*"; Expect = 1 },
        @{ Name = "a service signal with a wildcard path (declared the same in the baseline)"; From = $sigAllow; To = $sigAllow.Replace('/org/x/B1', '/org/x/*'); SigPath = "/org/x/*"; Expect = 1 },
        @{ Name = "a service signal with a further attribute"; From = $sigAllow; To = $sigAllow.Replace('/>', ' send_requested_reply="true"/>'); Expect = 1 },
        @{ Name = "a service signal the contract does not declare"; From = $sigAllow; To = $sigAllow.Replace('Wanted', 'Nope'); SigMember = "Nope"; Expect = 1 },
        @{ Name = "a service signal that is a method in the contract"; From = $sigAllow; To = $sigAllow.Replace('Wanted', 'Call'); SigMember = "Call"; Expect = 1 },
        @{ Name = "a service signal with no baseline entry"; From = ""; To = ""; NoSignals = $true; Expect = 1 },
        @{ Name = "a service signal in another case than the baseline's send_type"; From = $sigAllow; To = $sigAllow.Replace('send_type="signal"', 'send_type="SIGNAL"'); Expect = 1 },
        @{ Name = "a service signal in another case than the baseline's path"; From = $sigAllow; To = $sigAllow.Replace('/org/x/B1', '/ORG/x/B1'); Expect = 1 },
        @{ Name = "a service signal whose baseline entry is another user's"; From = ""; To = ""; SigUser = "ruya-input"; Expect = 1 },
        @{ Name = "a service signal whose baseline entry is for another destination"; From = ""; To = ""; SigDest = "org.x.Other"; Expect = 1 },
        @{ Name = "a service signal of another interface than the baseline entry's"; From = $sigAllow; To = $sigAllow.Replace('send_interface="org.x.B1"', 'send_interface="org.x.B2"'); Expect = 1 },
        @{ Name = "a service signal of another member than the baseline entry's"; From = $sigAllow; To = $sigAllow.Replace('send_member="Wanted"', 'send_member="Other"'); Expect = 1 },
        @{ Name = "a service signal on another path than the baseline's"; From = $sigAllow; To = $sigAllow.Replace('/org/x/B1', '/org/x/Other'); Expect = 1 },
        # RUY-1199: dbus-broker matches every value exactly, so a value in another case is another value. Each fixture
        # below is accepted if its compare ignores case; the others of the same family would still refuse it, so each
        # adds the odd policy beside the good ones.
        @{ Name = "a policy for user Root (another case than root)"; From = '<policy context="default">'; To = '<policy user="Root"><allow send_destination="org.x.A1"/></policy><policy context="default">'; Expect = 1 },
        @{ Name = "a service policy for user Ruya-Library (another case than ruya-library)"; From = '<policy context="default">'; To = '<policy user="Ruya-Library"><allow own="org.x.A1"/></policy><policy context="default">'; Expect = 1 },
        @{ Name = "a default context written Default"; From = '<policy context="default">'; To = '<policy context="Default">'; Expect = 1 },
        @{ Name = "a rule element written Allow (neither allow nor deny)"; From = $doorAllow; To = $doorAllow.Replace('<allow', '<Allow'); Expect = 1 },
        @{ Name = "a default receive deny whose receive_type is SIGNAL"; From = '<deny receive_sender="org.x.A1" receive_type="signal"/>'; To = '<deny receive_sender="org.x.A1" receive_type="SIGNAL"/>'; Expect = 1 },
        @{ Name = "a root receive allow whose receive_type is SIGNAL"; From = '<allow own="org.x.A1"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; To = '<allow own="org.x.A1"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="SIGNAL"/>'; Expect = 1 },
        @{ Name = "a door's send allow whose send_type is METHOD_CALL"; From = $doorAllow; To = $doorAllow.Replace('method_call', 'METHOD_CALL'); Expect = 1 },
        @{ Name = "a door's receive allow whose receive_type is SIGNAL"; From = $doorRecv; To = $doorRecv.Replace('"signal"', '"SIGNAL"'); Expect = 1 },
        @{ Name = "a door's allow of an interface in another case than the door list's"; From = $doorAllow; To = $doorAllow.Replace('org.x.A1.Pub', 'org.x.A1.PUB'); Expect = 1 },
        @{ Name = "a door's allow for a name in another case than the door list's"; From = ""; To = ""; DoorName = "ORG.x.A1"; Expect = 1 },
        @{ Name = "a root-only member denied in another case (send_member Put -> PUT)"; From = '<deny send_destination="org.x.A1" send_member="Put"/>'; To = '<deny send_destination="org.x.A1" send_member="PUT"/>'; Expect = 1 },
        @{ Name = "a root-only member denied for a destination in another case"; From = '<deny send_destination="org.x.A1" send_member="Put"/>'; To = '<deny send_destination="ORG.x.A1" send_member="Put"/>'; Expect = 1 },
        # RUY-1206: the annotation value is exactly "root" or an error; each fixture keeps the ruya-shell deny in place, so
        # only the refusal of the unreadable value (not a missing deny) can make the lint fail.
        @{ Name = "a Caller annotation with value Root (another case than root)"; From = ""; To = ""; Api = $api.Replace('value="root"', 'value="Root"'); Expect = 1 },
        @{ Name = "a Caller annotation with value admin"; From = ""; To = ""; Api = $api.Replace('value="root"', 'value="admin"'); Expect = 1 },
        @{ Name = "a Caller annotation with an empty value"; From = ""; To = ""; Api = $api.Replace('value="root"', 'value=""'); Expect = 1 },
        @{ Name = "a Caller annotation without a value"; From = ""; To = ""; Api = $api.Replace(' value="root"', ''); Expect = 1 },
        @{ Name = "a Caller annotation with value admin on a method that is not root only"; From = ""; To = ""; Api = $api.Replace('<method name="Get"/>', '<method name="Get"><annotation name="org.ruyaos.Caller" value="admin"/></method>'); Expect = 1 },
        # Two doors that differ only in case are two doors: the table keeps the first's interface list (a case-insensitive
        # `@{}` would let the second replace it and refuse the first's own allow).
        @{ Name = "two doors that differ only in case, each with its own interface list (control: accepted)"; From = ""; To = ""; DoorTwin = "org.x.a1"; Expect = 0 },
        @{ Name = "a root-only deny before the allow it should override"; From = '<policy user="ruya-shell"><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/><deny send_destination="org.x.A1" send_member="Put"/>'; To = '<policy user="ruya-shell"><deny send_destination="org.x.A1" send_member="Put"/><allow send_destination="org.x.A1"/><allow receive_sender="org.x.A1" receive_type="signal"/>'; Expect = 1 }
    )
    foreach ($c in $cases) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-bus-" + [guid]::NewGuid().ToString("N"))
        $pd = Join-Path $dir "image/rootfs/usr/share/dbus-1/system.d"
        New-Item -ItemType Directory -Force $pd | Out-Null
        $text = if ($c.From) { $good.Replace($c.From, $c.To) } else { $good }
        if ($c.From -and $text -ceq $good) { Write-Host "FAIL: self-test fixture for $($c.Name) did not change"; $bad++ }
        [IO.File]::WriteAllText((Join-Path $pd "org.x.A1.conf"), $text)
        $ad = Join-Path $dir "api/dbus"
        New-Item -ItemType Directory -Force $ad | Out-Null
        [IO.File]::WriteAllText((Join-Path $ad "org.x.A1.xml"), $(if ($c.Api) { $c.Api } else { $api }))
        [IO.File]::WriteAllText((Join-Path $ad "org.x.B1.xml"), $apiB)
        [IO.File]::WriteAllText((Join-Path $ad "org.x.B2.xml"), $apiB2)
        $doors = New-DoorTable
        if (-not $c.NoDoor) { $doors[$(if ($c.DoorName) { $c.DoorName } else { "org.x.A1" })] = @("org.x.A1.Pub") }
        if ($c.DoorTwin) { $doors[$c.DoorTwin] = @("org.x.A1") }   # a second door that differs only in case, listing another interface
        $member =if ($c.SigMember) { $c.SigMember } else { "Wanted" }
        $sigPath = if ($c.SigPath) { $c.SigPath } else { "/org/x/B1" }
        $sigUser = if ($c.SigUser) { $c.SigUser } else { "ruya-library" }
        $sigDest = if ($c.SigDest) { $c.SigDest } else { "org.x.A1" }
        $signals = if ($c.NoSignals) { @() } else { @(@{ user = $sigUser; destination = $sigDest; path = $sigPath; interface = "org.x.B1"; member = $member; reason = "fixture" }) }
        $n = Test-BusPolicies $pd $ad $doors $signals 6>&1 | Where-Object { $_ -is [int] } | Select-Object -Last 1
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
    # The service_signals list itself: every entry is exact and carries a reason.
    foreach ($t in @(
        @{ Name = "a service_signals entry with a reason (control)"; S = @{ user = "u"; destination = "d"; path = "/p"; interface = "i"; member = "m"; reason = "r" }; Expect = 0 },
        @{ Name = "a service_signals entry without a reason"; S = @{ user = "u"; destination = "d"; path = "/p"; interface = "i"; member = "m"; reason = "" }; Expect = 1 },
        @{ Name = "a service_signals entry with a wildcard member"; S = @{ user = "u"; destination = "d"; path = "/p"; interface = "i"; member = "*"; reason = "r" }; Expect = 1 },
        @{ Name = "a service_signals entry with an empty user"; S = @{ user = ""; destination = "d"; path = "/p"; interface = "i"; member = "m"; reason = "r" }; Expect = 1 })) {
        $got = @(Test-ServiceSignalList @($t.S)).Count
        if (($got -gt 0) -ne ($t.Expect -gt 0)) { Write-Host "FAIL: self-test: signal list $(if ($t.Expect) {'accepted'} else {'refused'}) $($t.Name)"; $bad++ }
    }
    if ($bad -eq 0) { Write-Host "ok: each bus policy rule refuses its fixture" }
}
if ($bad -gt 0) { exit 1 }
exit 0
