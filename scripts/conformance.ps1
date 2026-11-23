# The Platform API conformance run from Windows (RUY-158): a thin wrapper of scripts/conformance.sh,
# the one engine, which needs Linux (the mock reads /proc and a session bus that passes ProcessFD).
# Without -Wsl it runs nothing and says NOT RUN (builders run nothing in WSL, root CLAUDE.md); with
# -Wsl it runs the script in the Fedora WSL distribution (the lead's, docs/dev-setup.md).
# On Windows `dev.ps1 test` checks the coverage (a case for every public element) without a bus.
#
#   .\scripts\conformance.ps1 [-Wsl] [-SelfTest] [-Distro FedoraLinux-44]
# Exit codes are the script's: 0 passed, 1 failed, 2 not run.
param(
    [switch]$Wsl,
    [switch]$SelfTest,
    [string]$Distro = "FedoraLinux-44"
)
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Wsl) {
    Write-Host "CONFORMANCE: NOT RUN (Linux only: scripts/conformance.sh; pass -Wsl to run it in the $Distro WSL distribution)"
    exit 2
}
$scriptArgs = @("scripts/conformance.sh")
if ($SelfTest) { $scriptArgs += "--self-test" }
# A Linux target directory of its own: services\target is the Windows build's.
& wsl.exe -d $Distro --cd $Root -- env CARGO_TARGET_DIR=/var/tmp/ruya-conformance-target bash @scriptArgs
exit $LASTEXITCODE
