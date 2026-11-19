# The rules of scripts\vm-queue.ps1 that a host test can reach (RUY-860). Dot-source it:
#   . (Join-Path $PSScriptRoot "vm-queue-lib.ps1")
#
# Modes. Every scripts\vm-*.sh carries one machine-readable line, `# modes: check helper verify`
# (`# modes: none` when it takes no mode). The queue reads that line, nothing else. The lint
# (lint-vm-checks.ps1) compares it with what the script dispatches, so the line cannot drift.
#
# The .play files. vm-play-check.sh and vm-library-check.sh play need the sample package and
# ruya-pack on the guest (scripts/play-vm-files.sh builds both into output\play-vm).

$script:PlayCommand = "bash scripts/play-vm-files.sh   (WSL: wsl -d FedoraLinux-44 -- bash scripts/play-vm-files.sh)"

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

# The modes a script dispatches: the default of `${1:-x}`, the labels of a `case "${1:-..}" in` / `case "$mode" in` block (also `$part`; the
# labels at the block's first indentation, so a nested case does not count) and the
# `[ "${1:-..}" = mode ]` / `[ "$mode" = mode ]` tests. This is the lint's side of the line
# above; the queue never guesses.
function Get-VmDispatchedModes([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path)
    $found = New-Object System.Collections.Generic.HashSet[string]
    $sel = '"(\$\{1(?::-[^}]*)?\}|\$mode|\$part)"'
    $label = '^"?([\w-]+)"?(\|"?[\w-]+"?)*\)'
    $add = {
        param($text)
        foreach ($p in (($text -replace '\).*$', '') -split '\|')) {
            $p = $p.Trim('"')
            if ($p -and $p -ne '*') { [void]$found.Add($p) }
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*#') { continue }
        if ($l -match "^(\s*)case $sel in\s*(.*)$") {
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
        foreach ($t in [regex]::Matches($l, "\[ $sel ==? `"?(-{0,2}[A-Za-z][\w-]*)`"? \]")) { [void]$found.Add($t.Groups[2].Value) }
    }
    return @($found | Sort-Object)
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
