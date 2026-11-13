# Runs the lead's VM queue in one go (docs/LEAD.md "Lead efficiency"): boots a fresh work disk with
# sound, waits for RUYA_BOOT_OK, runs each check, stops the VM and writes a short summary.
#   .\scripts\vm-queue.ps1 [-Checks "vm-session-check.sh check","vm-devices-check.sh bluetooth",...] [-NoFresh]
# A check is "<script> [mode]". *.sh scripts run in the guest over SSH (all vm-* helper files are
# copied to /root first); vm-reboot-check.ps1 and vm-storage-check.ps1 run on the host against the
# VM. A check whose script or mode does not exist is SKIPPED (the reason is in the summary).
# Output: output\vm-queue\<script>-<mode>.log (full), output\vm-queue\summary.txt (at most 15 lines).
# Exits 0 when nothing FAILED. Run it only when no other QEMU is running; never builds an image.
param(
    [string[]]$Checks = @(
        "vm-session-check.sh check", "vm-session-check.sh display", "vm-session-check.sh restart", "vm-x11-check.sh",
        "vm-sounds-check.sh",
        "vm-security-check.sh", "vm-swap-check.sh",
        "vm-devices-check.sh bluetooth", "vm-devices-check.sh twopads", "vm-devices-check.sh inputd", "vm-devices-check.sh system",
        "vm-audio-check.sh",
        "vm-storage-check.ps1 scan",
        "vm-reboot-check.ps1 -SavedOutput"
    ),
    [switch]$NoFresh,
    [int]$TimeoutSec = 600,
    [string]$Key = (Join-Path $env:USERPROFILE ".ssh\ruyaos_dev")
)
$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
Set-Location $Repo
$outDir = Join-Path $Repo "output\vm-queue"
New-Item -ItemType Directory -Force $outDir | Out-Null
Get-ChildItem $outDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
$KnownHosts = Join-Path $Repo "output\vm-known_hosts"
Remove-Item $KnownHosts -ErrorAction SilentlyContinue   # every fresh disk has a new host key
$o = @("-i", $Key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$KnownHosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10")
$workDisk = "output\qcow2\work.qcow2"
$lines = New-Object System.Collections.Generic.List[string]
$failed = 0
$t0 = Get-Date

function Stop-Vm { Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force }
function Keyline([string[]]$Text) {
    $t = @($Text | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if (-not $t) { return "(no output)" }
    $k = $t | Where-Object { $_ -match "ALL CHECKS PASSED|SOME CHECKS FAILED|ALL PASS|PASSED|FAILED|_OK" } | Select-Object -Last 1
    if (-not $k) { $k = $t[-1] }
    $nfail = @($t | Where-Object { $_ -cmatch "^FAIL\b" }).Count
    $s = if ($nfail) { "$nfail FAIL line(s); $k" } else { $k }
    if ($s.Length -gt 110) { $s = $s.Substring(0, 110) }
    return $s
}
function Write-Summary {
    $lines | Set-Content -Encoding UTF8 (Join-Path $outDir "summary.txt")
    $lines | ForEach-Object { Write-Host $_ }
}

# ---- boot
if (Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue) { throw "a QEMU is already running" }
if (-not $NoFresh) { Remove-Item (Join-Path $Repo $workDisk) -ErrorAction SilentlyContinue }
$bootStart = Get-Date
$bootOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "smoke-test.ps1") -Work -Audio -Keep -TimeoutSec $TimeoutSec *>&1 | ForEach-Object { "$_" }
$bootCode = $LASTEXITCODE
$bootOut | Set-Content -Encoding UTF8 (Join-Path $outDir "boot.log")
$bootRes = @($bootOut | Where-Object { $_ -match "^result:" }) | Select-Object -Last 1
$secs = [int]((Get-Date) - $bootStart).TotalSeconds
if ($bootCode -ne 0) {
    $lines.Add("FAIL boot ($secs s): $bootRes")
    Write-Summary
    Stop-Vm
    exit 1
}
$lines.Add("PASS boot ($secs s): $bootRes")

# ---- copy the helper files once (the checks expect them in /root)
$scp = @($o + @("-P", "2222"))
$files = Get-ChildItem $PSScriptRoot -Include "vm-*.sh", "vm-*.qml", "vm-*.py" -Recurse | ForEach-Object { $_.FullName }
$files += (Join-Path $Repo "image\security-baseline.json")   # vm-security-check.sh reads it next to itself
& scp @scp @files "root@127.0.0.1:/root/" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $lines.Add("FAIL copy helper files to the guest (scp exit $LASTEXITCODE)"); $failed++ }

# ---- run
foreach ($c in $Checks) {
    $parts = @($c -split "\s+" | Where-Object { $_ })
    $script = $parts[0]
    $rest = @($parts | Select-Object -Skip 1)
    $name = ($script -replace "^vm-", "" -replace "\.(sh|ps1)$", "") + $(if ($rest) { " " + ($rest -join " ") } else { "" })
    $logName = (($script -replace "\.(sh|ps1)$", "") + $(if ($rest) { "-" + ($rest -join "-") } else { "" })) -replace "[^\w.-]", ""
    $log = Join-Path $outDir "$logName.log"
    $path = Join-Path $PSScriptRoot $script
    if (-not (Test-Path $path)) { $lines.Add("SKIPPED $name : $script does not exist"); continue }
    $isSh = $script.EndsWith(".sh")
    if ($isSh -and $rest.Count -ge 1 -and -not (Select-String -Path $path -Quiet -Pattern ("^\s*([\w-]+\|)*" + [regex]::Escape($rest[0]) + "(\|[\w-]+)*\)"))) {
        $lines.Add("SKIPPED $name : mode '$($rest[0])' not in $script"); continue
    }
    $ts = Get-Date
    Write-Host "== $name"
    if ($isSh) {
        $out = & ssh @o -p 2222 root@127.0.0.1 "bash /root/$script $($rest -join ' ')" 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } elseif ($script -eq "vm-reboot-check.ps1") {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path -Disk $workDisk @rest *>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } else {
        # vm-storage-check.ps1 has no mode: it runs all its steps (scan is one of them).
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path *>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    $out | Set-Content -Encoding UTF8 $log
    $dt = [int]((Get-Date) - $ts).TotalSeconds
    $res = "PASS"
    if ($code -ne 0) { $res = "FAIL"; $failed++ }
    $lines.Add("$res $name (${dt}s, exit $code): $(Keyline $out)")
}

# ---- finish
Stop-Vm
$tot = [int]((Get-Date) - $t0).TotalMinutes
if ($lines.Count -gt 14) { $lines = [System.Collections.Generic.List[string]]($lines | Select-Object -First 14) }
$lines.Add("QUEUE $(if ($failed) { 'FAILED' } else { 'OK' }) in $tot min; logs: output\vm-queue")
Write-Summary
exit $(if ($failed) { 1 } else { 0 })
