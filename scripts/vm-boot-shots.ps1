# Watches a VM's screen while it boots: one QEMU monitor connection, a screendump every
# -IntervalMs for -Seconds, each saved as output\boot-shots\<Tag>\<elapsed ms>.ppm (turn them into
# PNGs and a contact sheet with `python -I scripts/vm-boot-sheet.py <Tag>`). Optionally sends a key at a time
# (-Key esc -KeyFromMs 0 -KeyEveryMs 150 -KeyCount 10 -KeyBurst 5), which is how a player taps Esc at power-on.
# T-269: proves the screen shows only the splash (never console text) from the first frame on.
#   .\scripts\smoke-test.ps1 -Work -Keep ...   (or run-vm.ps1)  then immediately:
#   .\scripts\vm-boot-shots.ps1 -Tag cold -Seconds 90
# The monitor accepts a connection as soon as QEMU starts, so start this right after QEMU. The
# elapsed time counts from the moment this script connects.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Tag,
    [int]$Seconds = 60,
    [int]$IntervalMs = 500,
    [string]$Key,
    [int]$KeyFromMs = 0,
    [int]$KeyEveryMs = 150,
    [int]$KeyCount = 10,
    [int]$KeyBurst = 1,
    [int]$Port = 4444
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $Repo "output\boot-shots\$Tag"
New-Item -ItemType Directory -Force $dir | Out-Null
Get-ChildItem $dir -ErrorAction SilentlyContinue | Remove-Item -Force

$client = New-Object System.Net.Sockets.TcpClient
$deadline = (Get-Date).AddSeconds(60)
while ($true) {
    try { $client.Connect("127.0.0.1", $Port); break } catch {
        if ((Get-Date) -gt $deadline) { throw "no QEMU monitor on 127.0.0.1:$Port" }
        $client.Close(); $client = New-Object System.Net.Sockets.TcpClient
        Start-Sleep -Milliseconds 200
    }
}
$stream = $client.GetStream()
$stream.ReadTimeout = 15000
$enc = [System.Text.Encoding]::ASCII
function Read-UntilPrompt {
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 4096
    while ($true) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        [void]$sb.Append($enc.GetString($buf, 0, $n))
        if ($sb.ToString().EndsWith("(qemu) ")) { break }
    }
    return $sb.ToString()
}
function Send-Cmd([string]$c) {
    $bytes = $enc.GetBytes($c + "`r`n")
    $stream.Write($bytes, 0, $bytes.Length)
    [void](Read-UntilPrompt)
}
[void](Read-UntilPrompt)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$keysSent = 0
$nextKey = $KeyFromMs
$n = 0
try {
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ($Key -and $keysSent -lt $KeyCount -and $sw.ElapsedMilliseconds -ge $nextKey) {
            for ($b = 0; $b -lt $KeyBurst; $b++) { Send-Cmd "sendkey $Key"; Start-Sleep -Milliseconds 60 }
            $keysSent++
            $nextKey = $sw.ElapsedMilliseconds + $KeyEveryMs
            Write-Host ("key {0} at {1} ms" -f $Key, $sw.ElapsedMilliseconds)
        }
        $t = $sw.ElapsedMilliseconds
        $ppm = Join-Path $dir ("{0:D6}.ppm" -f $t)
        Send-Cmd ("screendump " + ($ppm -replace '\\', '/'))
        $n++
        $wait = $IntervalMs - ($sw.ElapsedMilliseconds - $t)
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
} catch {
    Write-Host "monitor closed after $($sw.ElapsedMilliseconds) ms ($n shots): $($_.Exception.Message)"
} finally {
    $client.Close()
}
Write-Host "$n screendumps in $dir"
