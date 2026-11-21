# The lead's cleanup after a builder branch is merged and its merge gate is green (docs/LEAD.md 4b
# step 6). A Rust lane's worktree holds 10-26 GB (services\target, shell\build-win); D: reached 0 GB
# twice when merged worktrees and folders of removed worktrees were left behind (RUY-862).
#   .\scripts\worktree-done.ps1 -Worktree D:\dev\RuyaOS-worktrees\RUY-123
#   .\scripts\worktree-done.ps1 -Leftovers            # list folders under RuyaOS-worktrees git no longer knows
#   .\scripts\worktree-done.ps1 -Leftovers -Remove    # and delete them
# It refuses a worktree with uncommitted changes or whose HEAD is not in main. Junctions inside the
# worktree (a lead may link output\qcow2 to main's VM disk) are removed as links first, never followed.
# Git runs as Git for Windows (devkitPro's git writes /d/... paths the other git cannot read, T-163).
param([string]$Worktree = "", [switch]$Leftovers, [switch]$Remove)

$ErrorActionPreference = "Continue"
$Repo = Split-Path -Parent $PSScriptRoot
$Root = Join-Path (Split-Path -Parent $Repo) "RuyaOS-worktrees"
$git = Join-Path $env:ProgramFiles "Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }

function Say([string]$Text) { Write-Host "worktree-done: $Text" }
function FreeGB { [math]::Round((Get-PSDrive (Split-Path -Qualifier $Root).TrimEnd(':')).Free / 1GB, 1) }

# Removes every junction or symbolic link below $Dir as a link (Directory.Delete without recursion
# deletes the reparse point, not what it points to), so the recursive delete after it cannot follow one.
function Remove-Links([string]$Dir) {
    $links = @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
    foreach ($l in ($links | Sort-Object { $_.FullName.Length } -Descending)) {
        if ($l.PSIsContainer) { [System.IO.Directory]::Delete($l.FullName, $false) } else { [System.IO.File]::Delete($l.FullName) }
        Say "removed link $($l.FullName)"
    }
}

function Registered {
    $paths = @()
    foreach ($line in (& $git -C $Repo worktree list --porcelain)) {
        if ($line -like "worktree *") { $paths += [System.IO.Path]::GetFullPath($line.Substring(9).Replace('/', '\')).TrimEnd('\') }
    }
    return $paths
}

if ($Leftovers) {
    $known = Registered
    $found = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.FullName.TrimEnd('\') })
    if ($found.Count -eq 0) { Say "no leftover folders under $Root"; exit 0 }
    foreach ($f in $found) {
        if ($Remove) { Remove-Links $f.FullName; Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction SilentlyContinue; Say "removed leftover $($f.Name)" }
        else { Say "leftover (not a worktree): $($f.FullName)" }
    }
    Say "D: $(FreeGB) GB free"
    exit 0
}

if (-not $Worktree) { Say "FAIL: give -Worktree <path> or -Leftovers"; exit 1 }
$wt = [System.IO.Path]::GetFullPath($Worktree).TrimEnd('\')
if (-not $wt.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { Say "FAIL: $wt is not under $Root"; exit 1 }
if ((Registered) -notcontains $wt) { Say "FAIL: $wt is not a registered worktree (use -Leftovers)"; exit 1 }
if (& $git -C $wt status --porcelain) { Say "FAIL: $wt has uncommitted changes"; exit 1 }
$branch = "$(& $git -C $wt rev-parse --abbrev-ref HEAD)".Trim()
$tip = "$(& $git -C $wt rev-parse HEAD)".Trim()
& $git -C $Repo merge-base --is-ancestor $tip main
if ($LASTEXITCODE -ne 0) { Say "FAIL: $branch ($($tip.Substring(0, 8))) is not merged into main"; exit 1 }

$before = FreeGB
Remove-Links $wt
& $git -C $Repo worktree remove --force $wt
if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $wt) { Say "FAIL: could not delete $wt"; exit 1 }
& $git -C $Repo worktree prune
if ($branch -and $branch -ne "HEAD") { & $git -C $Repo branch -d $branch | Out-Null; Say "deleted branch $branch" }
Say "removed $wt; D: $before -> $(FreeGB) GB free"
exit 0
