# Scans the tracked files and the whole git history for secrets before a push. Exit 1 on a hit.
#   .\scripts\scan-secrets.ps1
# Looks for private keys, common token formats, and image/bib/config.toml (the dev SSH key file,
# git-ignored) ever being tracked. A hit names the pattern and where; nothing is printed of the
# secret beyond the matching line's start.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
# An MSYS2 git earlier on PATH (devkitPro) brace-expands the patterns' {n} quantifiers: prefer Git for Windows.
$gitCmd = Join-Path $env:ProgramFiles "Git\cmd"
if (Test-Path (Join-Path $gitCmd "git.exe")) { $env:PATH = "$gitCmd;$env:PATH" }

$patterns = [ordered]@{
    "private key"          = "-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "GitHub token"         = "(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}"
    "AWS access key"       = "AKIA[0-9A-Z]{16}"
    "Anthropic API key"    = "sk-ant-[A-Za-z0-9_-]{20,}"
    "OpenAI-style API key" = "sk-[A-Za-z0-9]{40,}"
    "Slack token"          = "xox[abprs]-[A-Za-z0-9-]{10,}"
}
$fail = $false

$tracked = git ls-files "image/bib/config.toml"
$history = git log --all --format=%h -- "image/bib/config.toml"
if ($tracked -or $history) {
    Write-Host "FAIL: image/bib/config.toml is or was tracked ($($history -join ' '))"
    $fail = $true
}

foreach ($name in $patterns.Keys) {
    $rx = $patterns[$name]
    # Tracked files at HEAD (git grep: 0 = hit, 1 = none, anything else is an error).
    $now = git grep -I -n -E -e $rx HEAD -- . ":(exclude)scripts/scan-secrets.ps1"
    if ($LASTEXITCODE -gt 1) { Write-Host "FAIL: git grep failed for $name"; $fail = $true }
    # Every added or removed line in the history of every ref.
    $past = git log --all -p -E -G $rx --format="commit %h" -- . ":(exclude)scripts/scan-secrets.ps1" |
        Select-String -Pattern $rx | Select-Object -First 5
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: git log failed for $name"; $fail = $true }
    if ($now -or $past) {
        Write-Host "FAIL: $name"
        $now | Select-Object -First 5 | ForEach-Object { Write-Host ("  " + $_.Substring(0, [Math]::Min(80, $_.Length))) }
        $past | ForEach-Object { Write-Host ("  history: " + $_.Line.Substring(0, [Math]::Min(60, $_.Line.Length))) }
        $fail = $true
    }
}

if ($fail) { Write-Host "SECRETS FOUND: do not push"; exit 1 }
Write-Host "ok: no secrets in tracked files or history"
