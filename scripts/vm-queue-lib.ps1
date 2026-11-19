# The rules of scripts\vm-queue.ps1 that a host test can reach (RUY-860). Dot-source it:
#   . (Join-Path $PSScriptRoot "vm-queue-lib.ps1")
#
# Modes. Every scripts\vm-*.sh carries one machine-readable line, `# modes: check helper verify`
# (`# modes: none` when it takes no mode). The queue reads that line, nothing else. The lint
# (lint-vm-checks.ps1) compares it with what the script dispatches, so the line cannot drift.
#
# The .play files. vm-play-check.sh and vm-library-check.sh play need the sample package and
# ruya-pack on the guest (scripts/play-vm-files.sh builds both into output\play-vm).

# The one command that builds them (root: its podman and dnf steps need it). docs/dev-setup.md quotes
# this string, and lint-vm-checks.ps1 checks that it does.
$script:PlayCommand = "wsl -d FedoraLinux-44 -u root bash /mnt/d/dev/RuyaOS/scripts/play-vm-files.sh"

# The modes a script lists in its `# modes:` line; $null when it has no such line.
function Get-VmModes([string]$Path) {
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -match '^#\s*modes:\s*(.*?)\s*$') {
            $m = @($Matches[1] -split '\s+' | Where-Object { $_ })
            if ($m.Count -eq 1 -and $m[0] -eq "none") { return ,@() }
            return ,$m
        }
    }
    return $null
}

# What a script dispatches (the lint's side of the `# modes:` line; the queue never guesses):
# @{ modes = <sorted modes>; unreadable = <lines it could not read> }.
# Modes: the default of `${1:-x}`, the labels of a `case <selector> in` block (the labels at the
# block's first indentation, so a nested case does not count) and the `[ <selector> = mode ]` tests.
# A selector is `${1...}`, `$1` (top level only) or a variable the script assigns from them at its top level
# (`mode="${1:-check}"`, `what=$1`). A top-level `case`/`if`/`elif`/`while`/`[` that uses `$1` in
# any other way is `unreadable`: the lint fails on it instead of treating the script as having
# only the default mode (RUY-890).
function Get-VmDispatchedModes([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path)
    $found = New-Object System.Collections.Generic.HashSet[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l -match '^(\w+)="?\$(\{1(:-[^}]*)?\}|1)"?\s*(#.*)?$') { $names.Add([regex]::Escape('$' + $Matches[1])) }
    }
    # `$1` alone is a selector only at the top level: inside a function it is that function's argument.
    $selectors = @('\$\{1(?::-[^}]*)?\}') + $names
    $selNested = '"(' + ($selectors -join '|') + ')"'
    $selTop = '"(' + ((@($selectors) + '\$1') -join '|') + ')"'
    $label = '^"?([\w-]+)"?(\|"?[\w-]+"?)*\)'
    $add = {
        param($text)
        foreach ($p in (($text -replace '\).*$', '') -split '\|')) {
            $p = $p.Trim('"')
            if ($p -and $p -ne '*') { [void]$found.Add($p) }
        }
    }
    $heredoc = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        # a here-document is text for another program (a shim, a python script), not this script's dispatch
        if ($heredoc) { if ($l.Trim() -eq $heredoc) { $heredoc = $null }; continue }
        if ($l -match '(?<!<)<<-?\s*[''"]?([A-Za-z_]\w*)[''"]?') { $heredoc = $Matches[1] }
        if ($l -match '^\s*#') { continue }
        $read = $false
        $sel = if ($l -match '^\S') { $selTop } else { $selNested }
        if ($l -match "^(\s*)case $sel in\s*(.*)$") {
            $read = $true
            $indent = $Matches[1].Length
            $rest = $Matches[3]
            if ($rest -match $label) { & $add $Matches[0]; continue }   # `case .. in a|b) ;; *) ..` on one line
            $labelIndent = -1
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $c = $lines[$j]
                if ($c -match '^\s*#' -or $c -match '^\s*$') { continue }
                $ci = $c.Length - $c.TrimStart().Length
                if ($c -match '^\s*esac\b' -and $ci -eq $indent) { break }
                if ($labelIndent -lt 0) { $labelIndent = $ci }
                if ($ci -eq $labelIndent -and $c.TrimStart() -match $label) { & $add $Matches[0] }
            }
        }
        # the mode a bare call runs: ${1:-check}
        foreach ($t in [regex]::Matches($l, '\$\{1:-([A-Za-z][\w-]*)\}')) { [void]$found.Add($t.Groups[1].Value) }
        foreach ($t in [regex]::Matches($l, "\[ $sel ==? `"?(-{0,2}[A-Za-z][\w-]*)`"? \]")) { [void]$found.Add($t.Groups[2].Value); $read = $true }
        # a top-level dispatch on $1 that no rule above read
        if (-not $read -and $l -match '^(case|if|elif|while|\[)\b' -and ($l -replace "'[^']*'", '') -match '\$\{?1\b') {
            $unreadable.Add("line $($i + 1): $($l.Trim())")
        }
    }
    return @{ modes = @($found | Sort-Object); unreadable = @($unreadable) }
}

# The package and ruya-pack the .play checks copy: @{ files = <paths>; ready = <both exist> }.
function Get-PlayVmFiles([string]$Repo) {
    $dir = Join-Path $Repo "output\play-vm"
    $files = @("hello-play-native.play.zip", "ruya-pack") | ForEach-Object { Join-Path $dir $_ }
    $have = @($files | Where-Object { Test-Path $_ })
    return @{ files = $have; ready = ($have.Count -eq $files.Count) }
}

# Is this check one of the .play checks that need the package and ruya-pack on the guest?
function Test-PlayCheck([string]$Script, [string]$Mode) {
    if ($Script -eq "vm-play-check.sh") { return (-not $Mode) -or ($Mode -in @("check", "helper", "verify", "perms")) }
    if ($Script -eq "vm-library-check.sh") { return $Mode -eq "play" }
    return $false
}

# Why a check cannot run, or $null when it can. $Check is "<script> [mode ...]".
function Get-CheckSkip([string]$Check, [string]$ScriptsDir, [string]$Repo) {
    $parts = @($Check -split "\s+" | Where-Object { $_ })
    $name = $parts[0]
    $mode = if ($parts.Count -ge 2) { $parts[1] } else { "" }
    $path = Join-Path $ScriptsDir $name
    if (-not (Test-Path $path)) { return "$name does not exist" }
    if ($name.EndsWith(".sh") -and $mode) {
        $modes = Get-VmModes $path
        if ($null -eq $modes) { return "$name has no '# modes:' line" }
        if ($mode -notin $modes) { return "mode '$mode' not in $name (modes: $($modes -join ' '))" }
    }
    if ((Test-PlayCheck $name $mode) -and -not (Get-PlayVmFiles $Repo).ready) {
        return "build the sample first (output\play-vm\hello-play-native.play.zip and ruya-pack): $($script:PlayCommand)"
    }
    return $null
}
