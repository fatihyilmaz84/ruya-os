# What a green marker (output\last-green-test.txt, written by `dev.ps1 test` only when it ended
# ALL GREEN on a clean tree whose HEAD did not move during the run) proves about a commit.
# Dot-sourced by push-main.ps1 and merge-gate.ps1:
#   . (Join-Path $PSScriptRoot "green-marker.ps1")
#   $proof = Read-GreenMarker -Marker <file> -Head <sha> -Git <git.exe>
# $proof.Mode: "same" (no file differs), "docs" (only docs\*.md differ: `dev.ps1 docs` must still
# run) or $null (run the full `dev.ps1 test`); $proof.Why says why; $proof.Commit names the commit.
# A marker older than 24 hours, or naming a commit this repository lacks, proves nothing.

function Read-GreenMarker([string]$Marker, [string]$Head, [string]$Git, [int]$MaxAgeHours = 24) {
    function Proof($Mode, [string]$Why, [string]$Commit = "") {
        return [pscustomobject]@{ Mode = $Mode; Why = $Why; Commit = $Commit }
    }
    if (-not (Test-Path -LiteralPath $Marker)) { return (Proof $null "no green marker ($Marker)") }
    $fields = @{}
    foreach ($line in [IO.File]::ReadAllLines($Marker)) {
        if ($line -match '^(\w+) (\S+)$') { $fields[$Matches[1]] = $Matches[2] }
    }
    $sha = $fields["commit"]
    if (-not ($sha -match '^[0-9a-f]{40}$')) { return (Proof $null "the green marker names no commit") }
    $when = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParse($fields["time"], [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when)) {
        return (Proof $null "the green marker has no valid time")
    }
    $age = ((Get-Date).ToUniversalTime() - $when).TotalHours
    if ($age -lt 0 -or $age -gt $MaxAgeHours) { return (Proof $null "the green marker is older than $MaxAgeHours hours ($($fields['time']))") }
    & $Git cat-file -e "$sha^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { return (Proof $null "the green marker's commit $sha is not in this repository") }
    $changed = @(& $Git diff --name-only --no-renames $sha $Head)
    if ($LASTEXITCODE -ne 0) { return (Proof $null "git diff from the marker's commit failed") }
    $short = $sha.Substring(0, 10)
    if ($changed.Count -eq 0) { return (Proof "same" "$short passed dev.ps1 test at $($fields['time']) and HEAD has the same content" $sha) }
    $other = @($changed | Where-Object { $_ -notmatch '^docs/.+\.md$' })
    if ($other.Count -eq 0) {
        return (Proof "docs" "$short passed dev.ps1 test at $($fields['time']); since then only docs\*.md changed ($($changed.Count) files)" $sha)
    }
    return (Proof $null "since the green $short, $($other.Count) files outside docs\*.md changed (first: $($other[0]))")
}
