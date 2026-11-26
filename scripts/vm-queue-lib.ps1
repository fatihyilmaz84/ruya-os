# The rules of scripts\vm-queue.ps1 that a host test can reach (RUY-860). Dot-source it:
#   . (Join-Path $PSScriptRoot "vm-queue-lib.ps1")
#
# Modes. Every scripts\vm-*.sh carries one machine-readable line, `# modes: check helper verify`
# (`# modes: none` when it takes no mode). The queue reads that line, nothing else. The lint
# (lint-vm-checks.ps1) compares it with what the script dispatches, so the line cannot drift.
#
# Needs. A script whose modes need a signed-in profile says so next to it, `# needs: profile check sample`
# (or `# needs: profile all`); vm-queue.ps1 runs vm-goto.ps1 home once when a queued check needs one.
# The lint checks every named mode is in `# modes:`. It does not guess a need from the script text.
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

# The mode a bare call of the script runs: the default of its first `${1:-mode}` (the one form
# Get-VmDispatchedModes accepts, below); $null when it has none.
function Get-VmDefaultMode([string]$Path) {
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -match '^\s*#') { continue }
        if ($l -match '\$\{1:?-([A-Za-z][\w-]*)\}') { return $Matches[1] }
    }
    return $null
}

# The preconditions a script declares in its header, one `# needs: <keyword> <mode>... | all` line each
# (RUY-1163). The only keyword is `profile`: the queue signs a profile in (vm-goto.ps1 home) before it runs
# a check that lists its mode, or `all`. A line that cannot be read is not guessed at: its entry carries
# `error`, and the lint fails on it. Returns an array of
# @{ keyword; modes = <listed modes>; all = <bool>; error = <text or $null> } (wrap the call in @()).
$script:VmNeedKeywords = @("profile")
function Get-VmNeeds([string]$Path) {
    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -notmatch '^#\s*needs:\s*(.*?)\s*$') { continue }
        $t = @($Matches[1] -split '\s+' | Where-Object { $_ })
        $n = @{ keyword = ""; modes = @(); all = $false; error = $null }
        if ($t.Count -eq 0) { $n.error = "no keyword (want '# needs: profile <mode> ...' or '# needs: profile all')" }
        else {
            $n.keyword = $t[0]
            $rest = @($t | Select-Object -Skip 1)
            if ($n.keyword -notin $script:VmNeedKeywords) { $n.error = "unknown need '$($n.keyword)' (known: $($script:VmNeedKeywords -join ' '))" }
            elseif ($seen.ContainsKey($n.keyword)) { $n.error = "'$($n.keyword)' is declared twice" }
            elseif ($rest.Count -eq 0) { $n.error = "'$($n.keyword)' lists no mode (name the modes, or 'all')" }
            elseif ('all' -in $rest -and $rest.Count -gt 1) { $n.error = "'all' cannot be combined with modes" }
            elseif ($rest.Count -eq 1 -and $rest[0] -eq 'all') { $n.all = $true }
            else { $n.modes = $rest }
            $seen[$n.keyword] = $true
        }
        $found.Add($n)
    }
    return $found.ToArray()
}

# What is wrong with a script's `# needs:` lines (the lint's side): a line that cannot be read, a mode it
# names that the script's `# modes:` line does not list. Returns the messages (none: fine).
function Get-VmNeedsProblems([string]$Path) {
    $listed = Get-VmModes $Path
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in @(Get-VmNeeds $Path)) {
        if ($n.error) { $out.Add("'# needs:' line: $($n.error)"); continue }
        $unlisted = @($n.modes | Where-Object { $null -eq $listed -or $_ -notin $listed })
        if ($unlisted) { $out.Add("'# needs: $($n.keyword)' names a mode that '# modes:' does not list: $($unlisted -join ' ')") }
    }
    return $out.ToArray()
}

# Does this check need a signed-in profile? $Check is "<script> [mode ...]". A bare call runs the script's
# default mode. The one place the queue decides it: the script's own `# needs: profile` line.
function Get-CheckNeedsProfile([string]$Check, [string]$ScriptsDir) {
    $parts = @($Check -split "\s+" | Where-Object { $_ })
    $path = Join-Path $ScriptsDir $parts[0]
    if (-not $parts[0].EndsWith(".sh") -or -not (Test-Path $path)) { return $false }
    $need = @(Get-VmNeeds $path | Where-Object { $_.keyword -eq "profile" -and -not $_.error }) | Select-Object -First 1
    if (-not $need) { return $false }
    if ($need.all) { return $true }
    $mode = if ($parts.Count -ge 2) { $parts[1] } else { Get-VmDefaultMode $path }
    return [bool]$mode -and ($mode -in $need.modes)
}

# What a script dispatches (the lint's side of the `# modes:` line; the queue never guesses):
# @{ modes = <sorted modes>; unreadable = <lines it could not read> }.
#
# One way to dispatch, enforced (RUY-890). A script whose `# modes:` is not `none` reads its mode
# with exactly one of
#   case "${1:-default}" in            (or ${1-default}; `[ "${1:-default}" = mode ]` is read too)
#   mode="${1:-default}"               at the top level, then `case "$mode" in` / `[ "$mode" = mode ]`
# and the lint reads the labels of that case (at the block's first indentation) and the tested modes.
# Outside function bodies (`name() {` ... `}` at the same indentation) ANY other reference to `$1`,
# `${1...}`, `$@`, `$*`, or to the selector variable in a test or branch, at any indent, is
# `unreadable`, and so is `set -- args`: the lint fails on it, never guessing a single mode. Inside a
# function `$1`, `$@` and `$*` are its own arguments; only the selector variable in a test or branch
# is still refused. The selector variable may be used inside a plain command line (`echo "mode $mode"`, `run "$mode"`).
# A `# modes: none` script has no canonical form: it may not use `$1`/`$@`/`$*` outside functions.
# Here-documents and multi-line single-quoted strings are text for another program: skipped.
function Get-VmDispatchedModes([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path)
    $found = New-Object System.Collections.Generic.HashSet[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    $listed = Get-VmModes $Path
    $none = ($null -ne $listed -and $listed.Count -eq 0)
    $first = '\$\{1:?-[^}]*\}'
    $assign = '^(\w+)="' + $first + '"\s*(#.*)?$'
    $names = New-Object System.Collections.Generic.List[string]
    if (-not $none) {
        foreach ($l in $lines) { if ($l -match $assign) { $names.Add([regex]::Escape($Matches[1])) } }
    }
    $selectors = @($(if ($none) { '(?!)' } else { $first })) + @($names | ForEach-Object { '\$' + $_ })
    $sel = '"(' + ($selectors -join '|') + ')"'
    $nameRef = '\$\{?(?:' + ((@('(?!)') + @($names)) -join '|') + ')\b'
    $argRef = '\$\{?[1@*]|\$[@*]'
    $label = '^"?([\w-]+)"?(\|"?[\w-]+"?)*\)'
    $add = {
        param($text)
        foreach ($p in (($text -replace '\).*$', '') -split '\|')) {
            $p = $p.Trim('"')
            if ($p -and $p -ne '*') { [void]$found.Add($p) }
        }
    }
    # the script's own functions that branch on their first argument (`case "$1"`, `[ "$1" ...`):
    # calling one with the selector is a dispatch, not a plain command
    $ownFuncs = @{}
    $fname = $null
    $branchOn1 = '\bcase\s+"?\$\{?1\b|\[\[?\s+"?\$\{?1\b'
    foreach ($fl in $lines) {
        if ($fl -match '^\s*(?:function\s+)?([\w-]+)\(\)\s*\{(.*)$') {
            $fname = $Matches[1]
            if ($Matches[2] -match $branchOn1) { $ownFuncs[$fname] = $true }
            if ($Matches[2] -match '\}\s*$') { $fname = $null }
            continue
        }
        if ($fname) {
            if ($fl -match $branchOn1) { $ownFuncs[$fname] = $true }
            if ($fl -match '^\}') { $fname = $null }
        }
    }
    $heredoc = $null
    $inSingle = $false     # inside a single-quoted string that spans lines (a python snippet)
    $funcIndent = -1       # the indentation of the function whose body we are in; -1: top level
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
        # function bodies: from `name() {` to the `}` at the same indentation
        $inFunc = $funcIndent -ne -1
        if ($inFunc) {
            if (-not $tail) {
                if ($funcIndent -eq -2) { if ($l -match '\}\s*$') { $funcIndent = -1 } }
                elseif ($l -match '^(\s*)\}' -and $Matches[1].Length -eq $funcIndent) { $funcIndent = -1; continue }
            }
        } elseif (-not $tail -and $left -match '^(\s*)(function\s+)?[\w-]+\(\)\s*\{(.*)$') {
            $inFunc = $true
            # `name() {` closes at a `}` at its own indentation; `name() { cmd ...` at the first line ending in `}`
            if ($Matches[3] -notmatch '\}\s*$') { $funcIndent = $(if ($Matches[3].Trim()) { -2 } else { $Matches[1].Length }) }
        }
        $top = -not $inFunc
        $canon = $top -and -not $tail     # a string's tail is the end of a command, not a dispatch line
        if ($canon -and $l -match "^(\s*)case $sel in\s*(.*)$") {
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
        if ($canon) {
            # the mode a bare call runs, and the tests of the canonical forms
            if (-not $none) { foreach ($t in [regex]::Matches($l, '\$\{1:?-([A-Za-z][\w-]*)\}')) { [void]$found.Add($t.Groups[1].Value) } }
            $test = "\[ $sel ==? `"?(-{0,2}[A-Za-z][\w-]*)`"? \]"
            foreach ($t in [regex]::Matches($l, $test)) { [void]$found.Add($t.Groups[2].Value) }
            $left = [regex]::Replace($left, $test, '')
            if (-not $none -and $l -match $assign) { $left = '' }
            if ($left -match '^\s*set -- \S') { $unreadable.Add("line $($i + 1): $($l.Trim())"); continue }
        }
        # the selector variable inside a plain command line (`echo "mode $mode"`, `python3 x "$mode"`,
        # with optional `VAR=value` prefixes) is not a dispatch; a call of the script's own function or
        # eval/exec/source with it is one (it dispatches on the value), so it stays refused
        if ($left -match '^\s*(\w+=\S* +)*(\w[\w.-]*) ' -and -not $ownFuncs.ContainsKey($Matches[2]) -and
            $Matches[2] -notin @('eval', 'exec', 'source') -and
            $left -notmatch '\b(case|if|elif|while|until|test)\b|\[|&&|\|\|') {
            $left = $left -replace $nameRef, ''
        }
        if (($top -and $left -match $argRef) -or $left -match $nameRef) { $unreadable.Add("line $($i + 1): $($l.Trim())") }
    }
    return @{ modes = @($found | Sort-Object); unreadable = @($unreadable) }
}

# The packages and ruya-pack the .play checks copy:
# @{ files = <paths that exist>; ready = <native sample and ruya-pack exist>; windows = <the Windows sample exists> }.
# The Windows sample (launch-windows, RUY-902) needs the MinGW cross compilers in WSL; without them
# play-vm-files.sh still writes the other two, so only launch-windows is skipped.
function Get-PlayVmFiles([string]$Repo) {
    $dir = Join-Path $Repo "output\play-vm"
    $need = @("hello-play-native.play.zip", "ruya-pack") | ForEach-Object { Join-Path $dir $_ }
    $wine = Join-Path $dir "hello-play-wine.play.zip"
    $have = @(($need + $wine) | Where-Object { Test-Path $_ })
    return @{ files = $have; ready = (@($need | Where-Object { Test-Path $_ }).Count -eq $need.Count); windows = (Test-Path $wine) }
}

# Is this check one of the .play checks that need the package and ruya-pack on the guest?
# (vm-runner-check.sh needs only ruya-pack, RUY-34; the two are built together.)
function Test-PlayCheck([string]$Script, [string]$Mode) {
    if ($Script -eq "vm-play-check.sh") { return (-not $Mode) -or ($Mode -in @("check", "helper", "verify", "perms", "remove", "launch", "launch-windows")) }
    if ($Script -eq "vm-library-check.sh") { return $Mode -eq "play" }
    if ($Script -eq "vm-runner-check.sh") { return $true }
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
    $play = Get-PlayVmFiles $Repo
    if ((Test-PlayCheck $name $mode) -and -not $play.ready) {
        return "build the sample first (output\play-vm\hello-play-native.play.zip and ruya-pack): $($script:PlayCommand)"
    }
    if ($name -eq "vm-play-check.sh" -and $mode -eq "launch-windows" -and -not $play.windows) {
        return "build the Windows sample first (output\play-vm\hello-play-wine.play.zip, needs mingw64-gcc and mingw32-gcc in WSL): $($script:PlayCommand)"
    }
    return $null
}
