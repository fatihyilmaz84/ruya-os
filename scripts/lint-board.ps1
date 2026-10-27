# Board lint: docs/STATUS.md and the task files agree (docs/tasks/README.md, "Lifecycle").
#   - every board row links an existing task file, and its status equals the file's "Status:" header;
#   - the board lists only open work (todo, in-progress, blocked): done tasks live in their file;
#   - every task file whose status is not done has a board row;
#   - "NEXT -> T-nnn" names a task on the board.
#
# Used by dev.ps1 (test) and by the CI workflow. Works on Windows PowerShell 5.1 and on pwsh.
# Exit code 0 = consistent, 1 = findings.
#
#   .\scripts\lint-board.ps1
$Repo = Split-Path -Parent $PSScriptRoot
$Docs = Join-Path $Repo "docs"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$open = 'todo', 'in-progress', 'blocked'
$problems = New-Object System.Collections.Generic.List[string]

# Task files and their header status ("Status: todo, then the phase and so on").
$tasks = @{}
foreach ($f in Get-ChildItem (Join-Path $Docs "tasks") -Filter "T-*.md") {
    $m = [regex]::Match([IO.File]::ReadAllText($f.FullName, $Utf8), '(?m)^Status:\s*([a-z-]+)')
    if (-not $m.Success) { $problems.Add("$($f.Name): no 'Status:' header line"); continue }
    $tasks[$f.Name] = $m.Groups[1].Value
}

$status = [IO.File]::ReadAllText((Join-Path $Docs "STATUS.md"), $Utf8)
$rows = [regex]::Matches($status, '(?m)^\|\s*\[(T-\d+)\]\(tasks/([^)]+)\)\s*\|[^|]*\|\s*([a-z-]+)\s*\|')
$onBoard = @{}
foreach ($r in $rows) {
    $id = $r.Groups[1].Value; $file = $r.Groups[2].Value; $st = $r.Groups[3].Value
    $onBoard[$file] = $true
    if (-not $tasks.ContainsKey($file)) { $problems.Add("board row $id links a missing file tasks/$file"); continue }
    if ($open -notcontains $st) { $problems.Add("board row $id has status '$st'; the board lists only $($open -join ', ')") }
    elseif ($tasks[$file] -ne $st) { $problems.Add("$id is '$st' on the board but '$($tasks[$file])' in its file") }
}
foreach ($file in $tasks.Keys) {
    if ($open -contains $tasks[$file] -and -not $onBoard.ContainsKey($file)) {
        $problems.Add("$file is '$($tasks[$file])' but has no row on the STATUS board")
    }
    elseif ($tasks[$file] -notmatch '^(todo|in-progress|blocked|done)$') {
        $problems.Add("$file has an unknown status '$($tasks[$file])'")
    }
}
$next = [regex]::Match($status, '\*\*NEXT\s+\S+\s+(T-\d+)')
if ($next.Success) {
    if (-not ($rows | Where-Object { $_.Groups[1].Value -eq $next.Groups[1].Value })) {
        $problems.Add("NEXT names $($next.Groups[1].Value), which is not on the board")
    }
}
else { $problems.Add("STATUS.md has no '**NEXT -> T-nnn**' line") }

foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
if ($problems.Count -gt 0) { exit 1 }
exit 0
