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
# One way to dispatch, enforced (RUY-890). The canonical forms, the only ones read:
#   case "${1:-default}" in            labels at one indentation, `esac` at the case's
#   [ "${1:-default}" = mode ]         also `==`
#   name="${1:-default}"               at the top level; then `case "$name" in` and `[ "$name" = mode ]`
# Any OTHER top-level (unindented) reference to `$1`, `${1...}` or to such a name (`$name`,
# `${name}`, `!=`, `[[ ]]`, unquoted, `mode=${1-x}`, an echo of it, ...) is `unreadable`: the lint
# fails on it, never guessing a single mode. Indented lines are function bodies, where `$1` is that
# function's own argument, and here-documents are text for another program: both are skipped.
function Get-VmDispatchedModes([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path)
    $found = New-Object System.Collections.Generic.HashSet[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    $assign = '^(\w+)="\$\{1:-[^}]*\}"\s*(#.*)?$'
    # A top-level `set --` rebinds $1: from there on `$1` is not the script's mode.
    $setAt = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^set --( |$)') { $setAt = $i; break } }
    $names = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $setAt; $i++) {
        if ($lines[$i] -match $assign) { $names.Add([regex]::Escape($Matches[1])) }
    }
    $selectors = @('\$\{1:-[^}]*\}') + @($names | ForEach-Object { '\$' + $_ })
    $sel = '"(' + ($selectors -join '|') + ')"'
    $quotedName = '"\$(?:' + ($names -join '|') + ')"'
    $refs ='\$\{?(' + ((@('1') + @($names)) -join '|') + ')\b'
    $label = '^"?([\w-]+)"?(\|"?[\w-]+"?)*\)'
    $add = {
        param($text)
        foreach ($p in (($text -replace '\).*$', '') -split '\|')) {
            $p = $p.Trim('"')
            if ($p -and $p -ne '*') { [void]$found.Add($p) }
        }
    }
    $heredoc = $null
    $inSingle = $false     # inside a single-quoted string that spans lines (a python snippet): text for another program
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        # a here-document is text for another program (a shim, a python script), not this script's dispatch
        if ($heredoc) { if ($l.Trim() -eq $heredoc) { $heredoc = $null }; continue }
        if ($l -match '(?<!<)<<-?\s*[''"]?([A-Za-z_]\w*)[''"]?') { $heredoc = $Matches[1] }
        if (-not $inSingle -and $l -match '^\s*#') { continue }
        # $left: the line without its single-quoted parts and its trailing comment. A quote left open
        # starts a string that spans lines; the line that closes it is the tail of that command.
        $tail = $inSingle
        $left = $l
        if ($inSingle) {
            $q = $left.IndexOf("'")
            if ($q -lt 0) { continue }
            $left = $left.Substring($q + 1)
            $inSingle = $false
        }
        $left = $left -replace "'[^']*'", ''
        $left = $left -replace '(^|\s)#.*$', ''
        $q = $left.IndexOf("'")
        # (an apostrophe inside a word, "don't", opens nothing; a string opens after a space, `=` or `(`)
        if ($q -ge 0 -and ($q -eq 0 -or $left[$q - 1] -match '[\s=(]')) { $inSingle = $true; $left = $left.Substring(0, $q) }
        if ($tail) { continue }
        if ($l -match "^(\s*)case $sel in\s*(.*)$") {
            $left = $left -replace "^\s*case $sel in", ''
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
        $test = "\[ $sel ==? `"?(-{0,2}[A-Za-z][\w-]*)`"? \]"
        foreach ($t in [regex]::Matches($l, $test)) { [void]$found.Add($t.Groups[2].Value) }
        $left = [regex]::Replace($left, $test, '')
        if ($l -match $assign) { $left = '' }
        # any top-level mention of $1 (or of a name assigned from it) the canonical forms did not consume
        # (a one-line function is a function body; a name may be passed on as a plain `"$name"` argument
        # of a command, which is not a dispatch)
        if ($l -match '^\S' -and $l -notmatch '^\w+\(\) \{' -and $i -lt $setAt) {
            if ($left -match '^\w[\w.-]* ' -and $left -notmatch '\b(case|if|elif|while|until|test)\b|\[|&&|\|\|') {
                $left = $left -replace $quotedName, ''
            }
            if ($left -match $refs) { $unreadable.Add("line $($i + 1): $($l.Trim())") }
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
