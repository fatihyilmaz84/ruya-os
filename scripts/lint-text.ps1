# Text lint: every tracked text file is valid UTF-8 and has no stray control characters.
# Catches the two ways host tools have corrupted files before (root CLAUDE.md, pitfalls):
# Python writing cp1252 ("§" became a lone 0xA7 byte, T-107) and backslash escapes turned
# into control characters by heredocs or string literals ("\v", "\t", "\r", T-121).
# Flags: invalid UTF-8, any C0 control character other than LF and the CR of a CRLF, DEL,
# and tabs. Files git treats as binary are skipped.
#
# Used by dev.ps1 (test) and by the CI workflow. Works on Windows PowerShell 5.1 and on
# pwsh (Linux). Exit code 0 = clean, 1 = findings.
#
#   .\scripts\lint-text.ps1
$Repo = Split-Path -Parent $PSScriptRoot
$strict = New-Object System.Text.UTF8Encoding($false, $true)
$bad = '[\x00-\x09\x0B\x0C\x0E-\x1F\x7F]|\r(?!\n)'
$names = @{ 9 = 'tab'; 11 = '\v'; 12 = '\f'; 13 = 'lone \r'; 127 = 'DEL' }

# "git ls-files --eol" prints "i/<info> w/<info> attr/<attrs> <TAB><path>"; i/-text = binary.
$files = @(git -C $Repo ls-files --eol | Where-Object { $_ -notmatch '^i/-text' } |
    ForEach-Object { ($_ -split "`t", 2)[1] })
$findings = 0
foreach ($f in $files) {
    $path = Join-Path $Repo $f
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    try { $text = $strict.GetString($bytes) }
    catch {
        Write-Host "    ${f}: not valid UTF-8 (a cp1252 write? pass encoding=`"utf-8`")" -ForegroundColor Yellow
        $findings++
        continue
    }
    $line = 1
    $last = 0
    foreach ($m in [regex]::Matches($text, $bad)) {
        $line += ([regex]::Matches($text.Substring($last, $m.Index - $last), "`n")).Count
        $last = $m.Index
        $code = [int][char]$m.Value
        $what = if ($names.ContainsKey($code)) { $names[$code] } else { '0x{0:X2}' -f $code }
        Write-Host "    ${f}:${line}: control character $what" -ForegroundColor Yellow
        $findings++
    }
}
if ($findings -gt 0) {
    Write-Host "    Fix these bytes. Write text with backslashes through the Write/Edit tools, not heredocs or sed."
    exit 1
}
exit 0
