# The one Find-Bash (RUY-1231): the bash the host scripts run shell code with. Dot-source it:
#   . (Join-Path $PSScriptRoot "lib-bash.ps1")
# Used by lint-vm-checks.ps1, lint-dev-docs.ps1 and revert-check.ps1 (-Mode vmchecks); dev.ps1's `docs` self-check
# proves the rule below on a fake PATH.
#
# Git for Windows' bash first (the one the scripts are written and tested for), then a bash on PATH that is not
# the WSL launcher: System32\bash.exe (and the WindowsApps stubs) would run the code in a WSL distribution, which
# a host script must never do (root CLAUDE.md, Hard rules, Host: builders run nothing in WSL). Returns the full
# path, or $null when there is none; the caller says what it could not check.
function Find-Bash {
    foreach ($p in "$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") {
        if ($p -and (Test-Path $p)) { return $p }
    }
    # -All: without it Get-Command returns only the first bash on PATH, so a System32 one in front would hide the rest.
    $c = Get-Command bash -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch 'System32|WindowsApps' } | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}
