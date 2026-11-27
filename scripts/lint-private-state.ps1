# Private state lint (RUY-1130, ADR-022 decision 4): a state directory that only one service may read
# (image/security-baseline.json "private_state": the PIN store /var/lib/ruyaos/profiles of
# ruya-profiles.service) stays hidden from every other ruya-* system unit that could read it, but the
# exceptions the entry names with their reason.
# Root reads any file whatever its mode, and ProtectSystem=strict leaves /var readable, so a mode alone
# hides nothing from a root service; only a hidden directory holds (a hidden file is undone by the
# owner's tmp + rename). For each entry, under image/rootfs/usr/lib:
#   1. tmpfiles.d makes the directory `d <path> 0700 root root` (at boot, before any unit starts: a
#      missing InaccessiblePaths= path fails the unit);
#   2. every systemd/system/ruya-*.service but the owner that can read it (it runs as root: no User=,
#      User=root or 0, no DynamicUser=yes; or its AmbientCapabilities= hold CAP_DAC_OVERRIDE,
#      CAP_DAC_READ_SEARCH, CAP_SYS_ADMIN or CAP_SYS_PTRACE, a `~` list holding all it does not name):
#      - when its CapabilityBoundingSet= (none = every capability) holds CAP_SYS_ADMIN (it can unmount
#        the cover) or CAP_SYS_PTRACE (it can read the owner's /proc/<pid>/root even though the owner is
#        not dumpable), it must be one of the entry's "exceptions", and an exception must still hold one
#        (else it is stale: hide the path instead);
#      - otherwise it lists the path and every one of the entry's "aliases" (/sysroot: /var is a bind of
#        /sysroot/ostree/deploy/<stateroot>/var), or a folder above each, in InaccessiblePaths= of
#        [Service], drop-ins (<unit>.d/*.conf) included; an empty assignment clears the list, and a
#        `-` path (ignored when missing) does not count; and when its bounding set holds
#        CAP_DAC_READ_SEARCH (open_by_handle_at opens a file by handle past any mount hiding), its
#        SystemCallFilter= is an allow list naming neither @privileged nor open_by_handle_at (as
#        written; the VM check reads systemd's expansion of the groups);
#   3. no unit but the owner has a BindPaths= or BindReadOnlyPaths= source at, above or below the path
#      or an alias (a bind would show the directory somewhere else);
#   4. the owner unit exists and does not hide it.
# A new root unit is covered without a list to edit: it fails here until it carries the line.
# -SelfTest proves each rule on a temporary tree.
#
#   .\scripts\lint-private-state.ps1 [-SelfTest]
# Exit code 0 = fine, 1 = findings.
param([switch]$SelfTest, [string]$Root = "")
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = $Repo }

$ReadingCaps = @("CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_SYS_ADMIN", "CAP_SYS_PTRACE")
$UnhidingCaps = @("CAP_SYS_ADMIN", "CAP_SYS_PTRACE")

# The [Service] assignments of a unit and its drop-ins, in the order systemd reads them: key -> values.
function Get-ServiceSettings([string]$unitFile) {
    $files = @($unitFile)
    $dropins = $unitFile + ".d"
    if (Test-Path $dropins) { $files += @(Get-ChildItem $dropins -Filter "*.conf" | Sort-Object Name | ForEach-Object { $_.FullName }) }
    $settings = @{}
    foreach ($f in $files) {
        $section = ""
        foreach ($raw in [IO.File]::ReadAllLines($f)) {
            $line = $raw.Trim()
            if ($line -eq "" -or $line.StartsWith("#") -or $line.StartsWith(";")) { continue }
            if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
            if ($section -ne "Service" -or $line -notmatch '^([A-Za-z]+)\s*=\s*(.*)$') { continue }
            $key = $Matches[1]; $value = $Matches[2].Trim()
            if (-not $settings.ContainsKey($key)) { $settings[$key] = New-Object System.Collections.Generic.List[string] }
            $settings[$key].Add($value)
        }
    }
    return $settings
}

# The last assignment of a key ("" when none).
function Get-Last($settings, [string]$key) {
    if (-not $settings.ContainsKey($key) -or $settings[$key].Count -eq 0) { return "" }
    return $settings[$key][$settings[$key].Count - 1]
}

# The words a list setting holds after every assignment (an empty one clears it).
function Get-PathList($settings, [string]$key) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not $settings.ContainsKey($key)) { return $list }
    foreach ($value in $settings[$key]) {
        if ($value -eq "") { $list.Clear(); continue }
        foreach ($p in ($value -split '\s+')) { if ($p) { $list.Add($p) } }
    }
    return $list
}

# True when the unit's capability set `key` holds `cap`. Unset is every capability for
# CapabilityBoundingSet= and none for AmbientCapabilities= (`unsetIsAll`); "" empties the set;
# "~A B" is every capability but those; a plain list after the first assignment adds to the set
# (systemd.exec(5)).
function Test-HasCap($settings, [string]$cap, [string]$key = "CapabilityBoundingSet", [bool]$unsetIsAll = $true) {
    $all = $unsetIsAll; $set = New-Object System.Collections.Generic.List[string]; $first = $true
    if ($settings.ContainsKey($key)) {
        foreach ($value in $settings[$key]) {
            if ($value -eq "") { $all = $false; $set.Clear(); $first = $false; continue }
            if ($value.StartsWith("~")) {
                $all = $true; $set.Clear()
                foreach ($c in ($value.Substring(1) -split '\s+')) { if ($c) { $set.Add($c) } }
            } else {
                if ($first -or $all) { $all = $false; $set.Clear() }
                foreach ($c in ($value -split '\s+')) { if ($c) { $set.Add($c) } }
            }
            $first = $false
        }
    }
    if ($all) { return -not ($set -contains $cap) }
    return ($set -contains $cap)
}

# True when `path` is `dir` or below it.
function Test-Covers([string]$dir, [string]$path) {
    $d = $dir.TrimEnd('/')
    if ($d -eq "") { return $true }
    return ($path -ceq $d -or $path.StartsWith($d + "/", [StringComparison]::Ordinal))
}

# Why the unit can read root's 0700 directory ("" when it cannot).
function Get-ReadReason($settings) {
    $user = Get-Last $settings "User"
    $dynamic = (Get-Last $settings "DynamicUser") -match '^(yes|true|1|on)$'
    if (-not $dynamic -and ($user -eq "" -or $user -eq "root" -or $user -eq "0")) { return "runs as root" }
    foreach ($c in $ReadingCaps) { if (Test-HasCap $settings $c "AmbientCapabilities" $false) { return "holds $c" } }
    return ""
}

# Why the unit's SystemCallFilter= may let open_by_handle_at through ("" when it cannot): only an
# allow list without @privileged and without the call itself holds. Names as written: whether a group
# such as @system-service holds the call is systemd's expansion, which the VM check reads
# (vm-profiles-check.sh private, `systemctl show -p SystemCallFilter`).
function Get-HandleOpenReason($settings) {
    if (-not $settings.ContainsKey("SystemCallFilter")) { return "has no SystemCallFilter=" }
    $allowed = New-Object System.Collections.Generic.List[string]; $allowList = $null
    foreach ($value in $settings["SystemCallFilter"]) {
        if ($value -eq "") { $allowed.Clear(); $allowList = $null; continue }
        $deny = $value.StartsWith("~")
        $names = @(($value.TrimStart('~') -split '\s+') | Where-Object { $_ })
        if ($null -eq $allowList) { $allowList = -not $deny }
        if ($deny) { foreach ($n in $names) { [void]$allowed.Remove($n) } } else { foreach ($n in $names) { $allowed.Add($n) } }
    }
    if ($null -eq $allowList) { return "has an empty SystemCallFilter= (every call)" }
    if (-not $allowList) { return "has a deny-list SystemCallFilter= (it allows every call it does not name)" }
    foreach ($n in "@privileged", "open_by_handle_at") { if ($allowed -contains $n) { return "allows $n in SystemCallFilter=" } }
    return ""
}

function Find-PrivateStateProblems([string]$root) {
    $out = New-Object System.Collections.Generic.List[string]
    $baseline = Join-Path $root "image/security-baseline.json"
    $entries = @()
    if (Test-Path $baseline) {
        $json = [IO.File]::ReadAllText($baseline) | ConvertFrom-Json
        if ($null -ne $json.private_state) { $entries = @($json.private_state) }
    }
    if ($entries.Count -eq 0) { $out.Add("image/security-baseline.json: no private_state entry (the PIN store, RUY-1130)"); return $out }
    $lib = Join-Path $root "image/rootfs/usr/lib"
    $unitDir = Join-Path $lib "systemd/system"
    $units = @(Get-ChildItem $unitDir -Filter "ruya-*.service" -File | Sort-Object Name)
    $tmpfiles = @()
    $tmpDir = Join-Path $lib "tmpfiles.d"
    if (Test-Path $tmpDir) { foreach ($f in Get-ChildItem $tmpDir -Filter "*.conf" -File) { $tmpfiles += [IO.File]::ReadAllLines($f.FullName) } }
    foreach ($e in $entries) {
        $path = [string]$e.path; $owner = [string]$e.owner
        $aliases = @(); if ($null -ne $e.aliases) { $aliases = @($e.aliases | ForEach-Object { [string]$_ }) }
        $exceptions = @{}
        if ($null -ne $e.exceptions) { foreach ($x in @($e.exceptions)) { $exceptions[[string]$x.unit] = [string]$x.reason } }
        foreach ($x in $exceptions.Keys) {
            if (-not $exceptions[$x]) { $out.Add("image/security-baseline.json: the exception $x for $path has no reason") }
            if (-not ($units | Where-Object { $_.Name -eq $x })) { $out.Add("image/security-baseline.json: the exception $x for $path is not in systemd/system") }
        }
        $made = @($tmpfiles | Where-Object { ($_.Trim() -split '\s+') -join ' ' -like "d $path 0700 root root*" })
        if ($made.Count -eq 0) { $out.Add("tmpfiles.d: no 'd $path 0700 root root' line (InaccessiblePaths= of a missing path fails the unit)") }
        if (-not ($units | Where-Object { $_.Name -eq $owner })) { $out.Add("$($owner): the owner of $path is not in systemd/system") }
        foreach ($u in $units) {
            $settings = Get-ServiceSettings $u.FullName
            $hidden = @(Get-PathList $settings "InaccessiblePaths")
            $isOwner = ($u.Name -eq $owner)
            if ($isOwner) {
                if (@($hidden | Where-Object { Test-Covers $_.TrimStart('-').TrimStart('+') $path }).Count -gt 0) { $out.Add("$($u.Name): hides its own private state $path") }
                continue
            }
            foreach ($key in "BindPaths", "BindReadOnlyPaths") {
                foreach ($b in @(Get-PathList $settings $key)) {
                    $src = ($b.TrimStart('-').TrimStart('+') -split ':')[0]
                    foreach ($p in @($path) + $aliases) {
                        if ((Test-Covers $src $p) -or (Test-Covers $p $src)) { $out.Add("$($u.Name): $key=$b shows $p somewhere else ($owner's alone)") }
                    }
                }
            }
            $why = Get-ReadReason $settings
            if ($why -eq "") { continue }
            $unhiding = @($UnhidingCaps | Where-Object { Test-HasCap $settings $_ })
            if ($exceptions.ContainsKey($u.Name)) {
                if ($unhiding.Count -eq 0) { $out.Add("$($u.Name): listed as an exception for $path but holds neither CAP_SYS_ADMIN nor CAP_SYS_PTRACE any more: hide the path and drop the exception") }
                continue
            }
            if ($unhiding.Count -gt 0) {
                $out.Add("$($u.Name): $why with $($unhiding -join ' and ') in its CapabilityBoundingSet (none set = all), which undoes the hide of $($path): drop the capability or name the unit, with its reason, in private_state exceptions")
                continue
            }
            # CAP_DAC_READ_SEARCH opens any file by handle (open_by_handle_at), past every mount hiding.
            if (Test-HasCap $settings "CAP_DAC_READ_SEARCH") {
                $open = Get-HandleOpenReason $settings
                if ($open) { $out.Add("$($u.Name): holds CAP_DAC_READ_SEARCH and $open, so open_by_handle_at reaches $path past the hiding: use an allow list without @privileged and open_by_handle_at") }
            }
            foreach ($p in @($path) + $aliases) {
                if (@($hidden | Where-Object { Test-Covers $_.TrimStart('+') $p }).Count -gt 0) { continue }
                if (@($hidden | Where-Object { $_.StartsWith("-") -and (Test-Covers $_.TrimStart('-').TrimStart('+') $p) }).Count -gt 0) {
                    $out.Add("$($u.Name): $why and hides $p only when it exists ('-' prefix); write InaccessiblePaths=$p")
                } else {
                    $out.Add("$($u.Name): $why and can read $path ($owner's alone) through $($p): add $p to InaccessiblePaths=")
                }
            }
        }
    }
    return $out
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ruya-lint-private-" + [guid]::NewGuid().ToString("N"))
    $sys = Join-Path $tmp "image/rootfs/usr/lib/systemd/system"
    $tmpd = Join-Path $tmp "image/rootfs/usr/lib/tmpfiles.d"
    New-Item -ItemType Directory -Force $sys, $tmpd, (Join-Path $sys "ruya-reset.service.d") | Out-Null
    $failed = $false
    $baselineText = '{ "private_state": [ { "path": "/var/lib/x/secret", "aliases": ["/sysroot"], "owner": "ruya-owner.service", "reason": "fixture", "exceptions": [ { "unit": "ruya-admin.service", "reason": "fixture" }, { "unit": "ruya-stale.service", "reason": "fixture" } ] } ] }'
    try {
        [IO.File]::WriteAllText((Join-Path $tmp "image/security-baseline.json"), $baselineText)
        [IO.File]::WriteAllLines((Join-Path $tmpd "x.conf"), @("d /var/lib/x 0755 root root -", "d /var/lib/x/secret 0700 root root -"))
        $hide = "InaccessiblePaths=/var/lib/x/secret /sysroot"
        $unit = { param($name, [string[]]$service) [IO.File]::WriteAllLines((Join-Path $sys $name), (@("[Unit]", "Description=fixture", "InaccessiblePaths=/var/lib/x/secret /sysroot", "[Service]", "ExecStart=/bin/true") + $service)) }
        & $unit "ruya-owner.service" @("StateDirectory=x", "CapabilityBoundingSet=CAP_DAC_OVERRIDE")
        & $unit "ruya-good.service" @("CapabilityBoundingSet=", "InaccessiblePaths=/run/dbus", $hide)
        & $unit "ruya-above.service" @("CapabilityBoundingSet=CAP_CHOWN", "InaccessiblePaths=/var/lib/x /sysroot")
        & $unit "ruya-user.service" @("User=ruya-user")
        & $unit "ruya-dynamic.service" @("DynamicUser=yes")
        & $unit "ruya-admin.service" @("CapabilityBoundingSet=CAP_SYS_ADMIN")
        # Each of these must be reported (the [Unit] line of the fixture does not count).
        & $unit "ruya-root.service" @("CapabilityBoundingSet=", "ProtectSystem=strict")
        & $unit "ruya-rootuser.service" @("User=root", "CapabilityBoundingSet=", "InaccessiblePaths=/var/lib/x/secretx /sysroot")
        & $unit "ruya-caps.service" @("User=ruya-caps", "AmbientCapabilities=CAP_DAC_READ_SEARCH", "CapabilityBoundingSet=CAP_DAC_READ_SEARCH")
        & $unit "ruya-optional.service" @("CapabilityBoundingSet=", "InaccessiblePaths=-/var/lib/x/secret /sysroot")
        & $unit "ruya-reset.service" @("CapabilityBoundingSet=", $hide)
        [IO.File]::WriteAllLines((Join-Path $sys "ruya-reset.service.d/10-reset.conf"), @("[Service]", "InaccessiblePaths="))
        & $unit "ruya-noalias.service" @("CapabilityBoundingSet=", "InaccessiblePaths=/var/lib/x/secret")
        & $unit "ruya-allcaps.service" @($hide)
        & $unit "ruya-ptrace.service" @("CapabilityBoundingSet=CAP_SYS_PTRACE", $hide)
        & $unit "ruya-inverted.service" @("CapabilityBoundingSet=~CAP_SYS_ADMIN", $hide)
        & $unit "ruya-stale.service" @("CapabilityBoundingSet=", $hide)
        & $unit "ruya-bind.service" @("User=ruya-bind", "BindReadOnlyPaths=/var/lib/x:/mnt/x")
        # Ambient capabilities: CAP_SYS_PTRACE reads (and, in the bounding set, is unlisted); "~" holds all it does not name.
        & $unit "ruya-ambptrace.service" @("User=ruya-a", "AmbientCapabilities=CAP_SYS_PTRACE", "CapabilityBoundingSet=CAP_SYS_PTRACE")
        & $unit "ruya-ambtilde.service" @("User=ruya-a", "AmbientCapabilities=~CAP_CHOWN", "CapabilityBoundingSet=")
        & $unit "ruya-ambnone.service" @("User=ruya-a", "AmbientCapabilities=~CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_SYS_ADMIN CAP_SYS_PTRACE", "CapabilityBoundingSet=")
        # CAP_DAC_READ_SEARCH: the syscall filter must be an allow list without @privileged and open_by_handle_at.
        & $unit "ruya-dacok.service" @("CapabilityBoundingSet=CAP_DAC_READ_SEARCH", $hide, "SystemCallFilter=@system-service")
        & $unit "ruya-dacremoved.service" @("CapabilityBoundingSet=CAP_DAC_READ_SEARCH", $hide, "SystemCallFilter=@system-service open_by_handle_at", "SystemCallFilter=~open_by_handle_at")
        & $unit "ruya-dacnofilter.service" @("CapabilityBoundingSet=CAP_DAC_READ_SEARCH", $hide)
        & $unit "ruya-dacpriv.service" @("CapabilityBoundingSet=CAP_DAC_READ_SEARCH", $hide, "SystemCallFilter=@system-service @privileged")
        & $unit "ruya-dacobh.service" @("CapabilityBoundingSet=CAP_DAC_READ_SEARCH", $hide, "SystemCallFilter=@system-service open_by_handle_at")
        & $unit "ruya-dacdeny.service" @("CapabilityBoundingSet=CAP_DAC_READ_SEARCH", $hide, "SystemCallFilter=~@mount")
        $want = @("ruya-allcaps.service", "ruya-bind.service", "ruya-caps.service", "ruya-caps.service", "ruya-caps.service", "ruya-inverted.service", "ruya-noalias.service", "ruya-optional.service", "ruya-ptrace.service", "ruya-reset.service", "ruya-reset.service", "ruya-root.service", "ruya-root.service", "ruya-rootuser.service", "ruya-stale.service",
            "ruya-ambptrace.service", "ruya-ambtilde.service", "ruya-ambtilde.service", "ruya-dacnofilter.service", "ruya-dacpriv.service", "ruya-dacobh.service", "ruya-dacdeny.service") | Sort-Object
        $hits = @(Find-PrivateStateProblems $tmp)
        $got = @($hits | ForEach-Object { ($_ -split ':')[0] } | Sort-Object)
        $ok = (($got -join ',') -eq ($want -join ','))
        Write-Host ("    self-test units (root, User=root, a reading capability, ambient CAP_SYS_PTRACE and a '~' ambient list, '-' path, a reset drop-in, no /sysroot, all or CAP_SYS_PTRACE or ~CAP_SYS_ADMIN caps unlisted, a stale exception, a bind above, CAP_DAC_READ_SEARCH without a filter or with @privileged, open_by_handle_at or a deny list; not a folder above, another user, DynamicUser, a '~' ambient list without a reading cap, the owner, a listed exception, a filter that takes the call out again): {0}" -f $(if ($ok) { "ok" } else { "WRONG: " + ($hits -join ' | ') }))
        if (-not $ok) { $failed = $true }

        # The owner hiding its own state, a wrong tmpfiles mode, a missing owner and an exception that names no unit.
        & $unit "ruya-owner.service" @("InaccessiblePaths=/var/lib/x/secret")
        [IO.File]::WriteAllLines((Join-Path $tmpd "x.conf"), @("d /var/lib/x/secret 0755 root root -"))
        Remove-Item (Join-Path $sys "ruya-admin.service")
        $hits = @(Find-PrivateStateProblems $tmp)
        $ok = (@($hits | Where-Object { $_ -like "ruya-owner.service: hides its own*" }).Count -eq 1) -and (@($hits | Where-Object { $_ -like "tmpfiles.d:*" }).Count -eq 1) -and (@($hits | Where-Object { $_ -like "*exception ruya-admin.service * is not in systemd/system" }).Count -eq 1)
        Remove-Item (Join-Path $sys "ruya-owner.service")
        $hits2 = @(Find-PrivateStateProblems $tmp)
        $ok = $ok -and (@($hits2 | Where-Object { $_ -like "ruya-owner.service: the owner*" }).Count -eq 1)
        Write-Host ("    self-test owner, tmpfiles and exceptions (the owner hides it, mode 0755, no owner unit, an exception with no unit): {0}" -f $(if ($ok) { "ok" } else { "WRONG: " + (($hits + $hits2) -join ' | ') }))
        if (-not $ok) { $failed = $true }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    if ($failed) { exit 1 }
}

$problems = @(Find-PrivateStateProblems $Root)
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
    exit 1
}
Write-Host "    private state lint: ok"
exit 0
