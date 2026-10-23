# Shared helper for the VM scripts (vm-screenshot.ps1, vm-keys.ps1): talks to QEMU's human
# monitor, which smoke-test.ps1 and run-vm.ps1 expose on 127.0.0.1:4444 (never a public address;
# use 127.0.0.1, not localhost, which resolves to IPv6 on this host).
# Dot-source it:  . (Join-Path $PSScriptRoot "vm-lib.ps1")

$script:MonitorPrompt = "(qemu) "

function Send-VmMonitor {
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [int]$Port = 4444,
        [int]$TimeoutSec = 15
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect("127.0.0.1", $Port)
    } catch {
        throw "cannot reach the QEMU monitor on 127.0.0.1:$Port. Is the VM running (smoke-test.ps1 -Keep)? $_"
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutSec * 1000
    $enc = [System.Text.Encoding]::ASCII

    # Reads until the monitor prints its prompt again, i.e. the command finished.
    function Read-UntilPrompt {
        $sb = New-Object System.Text.StringBuilder
        $buf = New-Object byte[] 4096
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void]$sb.Append($enc.GetString($buf, 0, $n))
            if ($sb.ToString().EndsWith($script:MonitorPrompt)) { break }
        }
        return $sb.ToString()
    }

    $out = @()
    try {
        [void](Read-UntilPrompt)              # banner
        foreach ($c in $Command) {
            $bytes = $enc.GetBytes($c + "`r`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $out += Read-UntilPrompt
        }
    } finally {
        $client.Close()
    }
    return $out
}

# Writes a P6 PPM (what QEMU's screendump produces) as a PNG, with System.Drawing only.
function Convert-PpmToPng {
    param([Parameter(Mandatory)][string]$Ppm, [Parameter(Mandatory)][string]$Png)
    Add-Type -AssemblyName System.Drawing
    $bytes = [System.IO.File]::ReadAllBytes($Ppm)
    # Header: "P6", width, height, maxval, each separated by whitespace, then one whitespace byte.
    $pos = 0
    $tokens = @()
    while ($tokens.Count -lt 4) {
        while ($bytes[$pos] -le 32) { $pos++ }
        $start = $pos
        while ($bytes[$pos] -gt 32) { $pos++ }
        $tokens += [System.Text.Encoding]::ASCII.GetString($bytes, $start, $pos - $start)
    }
    $pos++                                   # the single whitespace byte after maxval
    if ($tokens[0] -ne "P6") { throw "not a P6 PPM: $Ppm" }
    $w = [int]$tokens[1]; $h = [int]$tokens[2]

    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    try {
        $row = New-Object byte[] ($w * 3)
        for ($y = 0; $y -lt $h; $y++) {
            $src = $pos + $y * $w * 3
            for ($x = 0; $x -lt $w; $x++) {      # RGB -> BGR
                $row[$x * 3] = $bytes[$src + $x * 3 + 2]
                $row[$x * 3 + 1] = $bytes[$src + $x * 3 + 1]
                $row[$x * 3 + 2] = $bytes[$src + $x * 3]
            }
            [System.Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row.Length)
        }
    } finally {
        $bmp.UnlockBits($data)
    }
    $bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
