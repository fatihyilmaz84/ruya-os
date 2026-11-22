# Duplicate-code lint (RUY-889, owner 2026-11-19: "no hacks, no duplicate code"). A block of MinTokens or more
# tokens that appears twice (in two files or twice in one file) under shell/qml, shell/src, services/*/src
# or scripts/*.sh|*.ps1 fails, unless the pair of files is on the baseline scripts/lint-duplicates.baseline.txt.
#
# How it works: every file is cut into tokens (comments and whitespace dropped; strings are one token;
# identifiers and numbers are compared as written, so a copy with renamed variables is NOT found), a rolling
# hash covers each window of MinTokens tokens, and equal windows are merged into runs. A window made only of
# a few distinct tokens (a run of closing braces, a table of zeros) is not a copy. The scanner is C# compiled
# with Add-Type (PowerShell 5.1 and pwsh both have it; no install): a PowerShell loop over a million tokens
# takes minutes. Inline #[cfg(test)] modules in services/*/src ARE scanned. Left out: test folders (shell/tests, tests dirs), generated files, *.ts translations,
# api/**/*.xml and Cargo.lock (generated or data, not logic), docs, and everything outside the four areas.
# In a shell backend header (shell/src/**/DBus*Backend.h, Mock*Backend.h) a pure override declaration
# (`void stop(const QString &instance) override;`) is no token: both transports declare the same interface,
# which is no copy to share (RUY-1051). Inline override bodies and everything else in them are still scanned.
#
# Baseline: one line per pair of files with duplicated tokens:   fileA | fileB | tokens   # reason
# (a file pair, A sorted before B; the same file twice for a copy inside one file). `tokens` is the number
# of duplicated tokens between the pair. The lint fails for a pair that is not listed, a pair that grew
# (a new copy), a pair that shrank or vanished (lower or remove the line: the baseline only shrinks).
# Every line is debt: remove a copy by sharing the code, never by adding a line.
#
#   .\scripts\lint-duplicates.ps1 [-MinTokens N] [-Measure] [-WriteBaseline] [-SelfTest]
# Exit code 0 = clean, 1 = findings. Works on Windows PowerShell 5.1 and pwsh (Linux); used by dev.ps1 (test) and CI.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Baseline = (Join-Path $PSScriptRoot "lint-duplicates.baseline.txt"),
    [int]$MinTokens = 80,
    [int]$MinDistinct = 0,       # 0 = MinTokens / 4
    [switch]$WriteBaseline,
    [switch]$Measure,            # print the number of baseline pairs for several MinTokens, change nothing
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$areas = @("shell/qml", "shell/src", "services/*/src", "scripts")
$extensions = @(".qml", ".js", ".cpp", ".h", ".hpp", ".rs", ".sh", ".ps1")

if (-not ("DupScan" -as [type])) {
    # C# 5 only (Windows PowerShell 5.1 compiles with the .NET Framework compiler).
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public class DupRegion
{
    public string A; public int LineA; public string B; public int LineB; public int Tokens;
}

public static class DupScan
{
    class Doc { public string Path; public int[] Ids; public int[] Lines; }

    static bool IsWord(char c) { return c == '_' || c == '$' || char.IsLetterOrDigit(c); }

    // A shell backend header (DBus*Backend.h, Mock*Backend.h): its pure override declarations are not tokens.
    public static bool IsBackendHeader(string rel)
    {
        string name = Path.GetFileName(rel);
        return rel.StartsWith("shell/src/", StringComparison.Ordinal) && name.EndsWith("Backend.h", StringComparison.Ordinal)
               && (name.StartsWith("DBus", StringComparison.Ordinal) || name.StartsWith("Mock", StringComparison.Ordinal));
    }

    // Drops every statement that ends in `override ;` (a declaration, no body). A statement starts after
    // `;`, `{`, `}` or an access label (`public:`, `private:`, `protected:`, `signals:`, `slots:`).
    static void DropOverrideDecls(List<string> toks, List<int> lines)
    {
        var keepT = new List<string>(); var keepL = new List<int>();
        int start = 0;
        for (int k = 0; k < toks.Count; k++)
        {
            string t = toks[k];
            bool label = t == ":" && k > 0 && (toks[k - 1] == "public" || toks[k - 1] == "private" || toks[k - 1] == "protected"
                                               || toks[k - 1] == "signals" || toks[k - 1] == "slots")
                         && (k + 1 >= toks.Count || toks[k + 1] != ":");
            if (t == ";" || t == "{" || t == "}" || label)
            {
                bool decl = t == ";" && k > start && toks[k - 1] == "override";
                if (!decl) for (int m = start; m <= k; m++) { keepT.Add(toks[m]); keepL.Add(lines[m]); }
                start = k + 1;
            }
        }
        for (int m = start; m < toks.Count; m++) { keepT.Add(toks[m]); keepL.Add(lines[m]); }
        toks.Clear(); toks.AddRange(keepT); lines.Clear(); lines.AddRange(keepL);
    }

    // lang: "c" (qml, js, cpp, rust: // and /* */), "sh" (#), "ps" (# and <# #>, here-strings).
    static void Tokenize(string s, string lang, bool rust, bool backendHeader, Dictionary<string, int> intern, List<int> ids, List<int> lines)
    {
        var toks = new List<string>(); var tokLines = new List<int>();
        int n = s.Length, i = 0, line = 1;
        while (i < n)
        {
            char c = s[i];
            if (c == '\n') { line++; i++; continue; }
            if (char.IsWhiteSpace(c)) { i++; continue; }
            if (lang == "c" && c == '/' && i + 1 < n && s[i + 1] == '/') { while (i < n && s[i] != '\n') i++; continue; }
            if ((lang == "c" && c == '/' && i + 1 < n && s[i + 1] == '*') || (lang == "ps" && c == '<' && i + 1 < n && s[i + 1] == '#'))
            {
                string end = lang == "c" ? "*/" : "#>";
                int e = s.IndexOf(end, i + 2, StringComparison.Ordinal);
                int stop = e < 0 ? n : e + 2;
                for (int k = i; k < stop; k++) if (s[k] == '\n') line++;
                i = stop; continue;
            }
            if (lang != "c" && c == '#')
            {
                char p = i == 0 ? ' ' : s[i - 1];
                if (char.IsWhiteSpace(p) || p == ';' || p == '|' || p == '&') { while (i < n && s[i] != '\n') i++; continue; }
            }
            int start = i, startLine = line;
            string tok;
            if (lang == "ps" && c == '@' && i + 1 < n && (s[i + 1] == '\'' || s[i + 1] == '"'))
            {
                string close = "\n" + s[i + 1] + "@";
                int e = s.IndexOf(close, i + 2, StringComparison.Ordinal);
                int stop = e < 0 ? n : e + 3;
                for (int k = i; k < stop; k++) if (s[k] == '\n') line++;
                tok = s.Substring(i, stop - i); i = stop;
            }
            else if (c == '"' || c == '\'' || (c == '`' && lang == "c"))
            {
                if (rust && c == '\'')
                {
                    // a char literal ('x', '\n') is a string token; a lifetime ('a) is a plain punctuation token
                    if (i + 1 < n && s[i + 1] == '\\') { int e = s.IndexOf('\'', i + 2); i = e < 0 ? n : e + 1; }
                    else if (i + 2 < n && s[i + 2] == '\'') i += 3;
                    else i++;
                }
                else
                {
                    i++;
                    while (i < n && s[i] != c)
                    {
                        if (s[i] == '\n') line++;
                        bool esc = (lang == "c" || (lang == "sh" && c == '"') ) && s[i] == '\\';
                        bool psEsc = lang == "ps" && c == '"' && s[i] == '`';
                        i += (esc || psEsc) ? 2 : 1;
                    }
                    i = Math.Min(n, i + 1);
                }
                tok = s.Substring(start, i - start);
            }
            else if (IsWord(c)) { while (i < n && IsWord(s[i])) i++; tok = s.Substring(start, i - start); }
            else { i++; tok = c.ToString(); }
            toks.Add(tok); tokLines.Add(startLine);
        }
        if (backendHeader) DropOverrideDecls(toks, tokLines);
        for (int k = 0; k < toks.Count; k++)
        {
            int id;
            if (!intern.TryGetValue(toks[k], out id)) { id = intern.Count + 1; intern[toks[k]] = id; }
            ids.Add(id); lines.Add(tokLines[k]);
        }
    }

    public static List<DupRegion> Run(string root, string[] relFiles, int minTokens, int minDistinct)
    {
        var intern = new Dictionary<string, int>();
        var docs = new List<Doc>();
        foreach (string rel in relFiles)
        {
            string ext = Path.GetExtension(rel).ToLowerInvariant();
            string lang = ext == ".sh" ? "sh" : ext == ".ps1" ? "ps" : "c";
            string text = File.ReadAllText(Path.Combine(root, rel), Encoding.UTF8);
            var ids = new List<int>(); var lines = new List<int>();
            Tokenize(text, lang, ext == ".rs", IsBackendHeader(rel), intern, ids, lines);
            docs.Add(new Doc { Path = rel, Ids = ids.ToArray(), Lines = lines.ToArray() });
        }

        ulong pow = 1; const ulong B = 1099511628211UL;
        for (int k = 0; k < minTokens; k++) pow = unchecked(pow * B);

        // matches: each window is paired with the previous equal window (a chain, so many copies stay linear)
        var last = new Dictionary<ulong, long>();
        var matches = new List<long[]>();
        var seen = new HashSet<int>();
        for (int f = 0; f < docs.Count; f++)
        {
            int[] a = docs[f].Ids;
            if (a.Length < minTokens) continue;
            var pre = new ulong[a.Length + 1];
            for (int k = 0; k < a.Length; k++) pre[k + 1] = unchecked(pre[k] * B + (ulong)a[k]);
            for (int p = 0; p + minTokens <= a.Length; p++)
            {
                ulong h = unchecked(pre[p + minTokens] - pre[p] * pow);
                long prev;
                if (last.TryGetValue(h, out prev))
                {
                    int pf = (int)(prev >> 32), pp = (int)(prev & 0xFFFFFFFFL);
                    if (pf == f && p - pp < minTokens) continue;      // overlapping itself: not a copy
                    seen.Clear();
                    for (int k = 0; k < minTokens; k++) seen.Add(a[p + k]);
                    if (seen.Count < minDistinct) continue;
                    matches.Add(new long[] { pf, pp, f, p });
                }
                last[h] = ((long)f << 32) | (uint)p;
            }
        }

        // merge consecutive windows (same two files, same offset) into one region
        matches.Sort(delegate (long[] x, long[] y)
        {
            int c = x[0].CompareTo(y[0]); if (c != 0) return c;
            c = x[2].CompareTo(y[2]); if (c != 0) return c;
            c = (x[3] - x[1]).CompareTo(y[3] - y[1]); if (c != 0) return c;
            return x[1].CompareTo(y[1]);
        });
        var regions = new List<DupRegion>();
        int i = 0;
        while (i < matches.Count)
        {
            long[] m = matches[i]; int j = i;
            while (j + 1 < matches.Count && matches[j + 1][0] == m[0] && matches[j + 1][2] == m[2]
                   && matches[j + 1][3] - matches[j + 1][1] == m[3] - m[1] && matches[j + 1][1] == matches[j][1] + 1) j++;
            Doc da = docs[(int)m[0]], db = docs[(int)m[2]];
            regions.Add(new DupRegion { A = da.Path, LineA = da.Lines[(int)m[1]], B = db.Path, LineB = db.Lines[(int)m[3]], Tokens = (j - i) + minTokens });
            i = j + 1;
        }
        return regions;
    }
}
'@
}

function Get-SourceFiles([string]$base) {
    $found = New-Object System.Collections.Generic.List[string]
    $skip = '[\\/](build[^\\/]*|target|node_modules|tests?|\.git)[\\/]'
    foreach ($area in $areas) {
        $parts = $area.Split("/")
        $dirs = @($base)
        foreach ($p in $parts) {
            $next = @()
            foreach ($d in $dirs) {
                if ($p.Contains("*")) { $next += @(Get-ChildItem -LiteralPath $d -Directory -Filter $p -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
                else { $q = Join-Path $d $p; if (Test-Path -LiteralPath $q -PathType Container) { $next += $q } }
            }
            $dirs = $next
        }
        foreach ($d in $dirs) {
            $isScripts = ($area -eq "scripts")
            $opt = if ($isScripts) { @{} } else { @{ Recurse = $true } }
            foreach ($f in (Get-ChildItem -LiteralPath $d -File @opt)) {
                if ($extensions -notcontains $f.Extension.ToLowerInvariant()) { continue }
                if ($isScripts -and $f.Extension -notin @(".sh", ".ps1")) { continue }
                if ($f.FullName.Substring($base.Length) -match $skip) { continue }
                $found.Add($f.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/'))
            }
        }
    }
    # Ordinal, never culture-aware: PowerShell 5.1 (NLS) ignores '-' when sorting, pwsh/ICU does not, and the
    # order decides each pair's key (A before B) and which copy a window chains to.
    $sorted = [string[]]@($found | Select-Object -Unique)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

# Pairs of files with their duplicated token counts and the regions behind them.
function Get-DuplicatePairs([string]$base, [int]$min, [int]$distinct) {
    if ($distinct -le 0) { $distinct = [Math]::Max(2, [int]($min / 4)) }
    $files = Get-SourceFiles $base
    $regions = [DupScan]::Run($base, [string[]]$files, $min, $distinct)
    $pairs = [ordered]@{}
    foreach ($r in $regions) {
        $key = "$($r.A) | $($r.B)"
        if (-not $pairs.Contains($key)) { $pairs[$key] = [pscustomobject]@{ Tokens = 0; Regions = @() } }
        $pairs[$key].Tokens += $r.Tokens
        $pairs[$key].Regions += $r
    }
    return $pairs
}

function Read-Baseline([string]$path) {
    $known = @{}; $reasons = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ($line.TrimStart().StartsWith("#")) { continue }
            $reason = ""
            if ($line -match '#\s*(.*)$') { $reason = $Matches[1] }
            $t = ($line -replace '#.*$', '').Trim()
            if ($t.Length -eq 0) { continue }
            $f = $t -split '\s*\|\s*'
            if ($f.Count -ne 3) { throw "baseline line is not 'fileA | fileB | tokens': $line" }
            $known["$($f[0]) | $($f[1])"] = [int]$f[2]
            $reasons["$($f[0]) | $($f[1])"] = $reason
        }
    }
    return @{ Known = $known; Reasons = $reasons }
}

# Returns the number of findings and prints them.
function Invoke-Lint([string]$base, [string]$baselinePath, [int]$min, [int]$distinct) {
    $pairs = Get-DuplicatePairs $base $min $distinct
    $bl = (Read-Baseline $baselinePath).Known
    $findings = 0
    foreach ($key in $pairs.Keys) {
        $p = $pairs[$key]
        if (-not $bl.ContainsKey($key) -or $p.Tokens -gt $bl[$key]) {
            $what = if ($bl.ContainsKey($key)) { "grew from $($bl[$key]) to $($p.Tokens) duplicated tokens" } else { "$($p.Tokens) duplicated tokens, not on the baseline" }
            Write-Host "    ${key}: $what. Share the code instead of copying it:"
            foreach ($r in $p.Regions) { Write-Host "        $($r.A):$($r.LineA) == $($r.B):$($r.LineB)  ($($r.Tokens) tokens)" }
            $findings++
        }
        elseif ($p.Tokens -lt $bl[$key]) {
            Write-Host "    ${key}: only $($p.Tokens) duplicated tokens left, the baseline says $($bl[$key]): lower it ('lint-duplicates.ps1 -WriteBaseline'); the baseline only shrinks"
            $findings++
        }
    }
    foreach ($key in $bl.Keys) {
        if (-not $pairs.Contains($key)) {
            Write-Host "    ${key}: no longer duplicated, remove it from the baseline ('lint-duplicates.ps1 -WriteBaseline'); the baseline only shrinks"
            $findings++
        }
    }
    return $findings
}

function Invoke-SelfTest {
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("ruya-dup-fx-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path (Join-Path $fx "shell/qml") | Out-Null
    $min = 40
    $failed = @()
    $savedAreas = $script:areas
    try {
        $block = { param($k) (1..$k | ForEach-Object { "w$_" }) -join " " }
        $emptyBl = Join-Path $fx "empty.txt"; Set-Content -LiteralPath $emptyBl -Value "# none" -Encoding UTF8
        $write = {
            param($k)
            Set-Content -LiteralPath (Join-Path $fx "shell/qml/A.qml") -Value ("onlyA1 onlyA2`n// a comment`n" + (& $block $k) + "`nonlyA3 onlyA4") -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $fx "shell/qml/B.qml") -Value ("onlyB1 onlyB2 onlyB3`n" + ((& $block $k) -replace ' ', "   `n/* c */ ") + "`nonlyB4") -Encoding UTF8
        }
        $script:areas = @("shell/qml")
        $out = $null

        & $write $min          # a planted copy of exactly MinTokens tokens (whitespace and comments differ)
        $out = Invoke-Lint $fx $emptyBl $min 0 6>&1 | Out-String
        if ($out -notmatch 'shell/qml/A\.qml:3 == shell/qml/B\.qml:2') { $failed += "a planted copy was not reported with both file:line ($out)" }

        & $write ($min - 1)    # one token short of a copy
        $n = @(Invoke-Lint $fx $emptyBl $min 0 6>&1 | Where-Object { $_ -is [int] }) | Select-Object -Last 1
        if ($n -ne 0) { $failed += "a near-copy below MinTokens was reported" }

        & $write $min          # baseline: an exact entry passes, a stale one and a loose one fail
        $bl = Join-Path $fx "bl.txt"
        Set-Content -LiteralPath $bl -Value "shell/qml/A.qml | shell/qml/B.qml | $min  # test" -Encoding UTF8
        $n = @(Invoke-Lint $fx $bl $min 0 6>&1 | Where-Object { $_ -is [int] }) | Select-Object -Last 1
        if ($n -ne 0) { $failed += "an exact baseline entry did not pass" }
        Set-Content -LiteralPath $bl -Value "shell/qml/A.qml | shell/qml/B.qml | $($min + 5)" -Encoding UTF8
        $n = @(Invoke-Lint $fx $bl $min 0 6>&1 | Where-Object { $_ -is [int] }) | Select-Object -Last 1
        if ($n -ne 1) { $failed += "a baseline entry above the real count did not fail" }
        Set-Content -LiteralPath $bl -Value "shell/qml/A.qml | shell/qml/B.qml | $($min - 1)" -Encoding UTF8
        $out = Invoke-Lint $fx $bl $min 0 6>&1 | Out-String
        if ($out -notmatch 'grew from') { $failed += "a pair above its baseline count (a new copy) did not fail" }
        # file names that differ only around a '-': the pair key must be ordinal ('-' sorts before '.'), the same
        # on PowerShell 5.1 and pwsh, or a baseline written on one host fails on the other
        Remove-Item (Join-Path $fx "shell/qml/A.qml"), (Join-Path $fx "shell/qml/B.qml")
        $same = & $block $min
        Set-Content -LiteralPath (Join-Path $fx "shell/qml/p.qml") -Value "onlyP1 $same onlyP2" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $fx "shell/qml/p-q.qml") -Value "onlyQ1 $same onlyQ2" -Encoding UTF8
        $out = Invoke-Lint $fx $emptyBl $min 0 6>&1 | Out-String
        if ($out -notmatch 'shell/qml/p-q\.qml \| shell/qml/p\.qml') { $failed += "the pair key is not in ordinal file order ($out)" }
        Remove-Item (Join-Path $fx "shell/qml/p.qml"), (Join-Path $fx "shell/qml/p-q.qml")
        # backend headers (RUY-1051): a shared list of override declarations is no copy; real code still is
        $script:areas = @("shell/src")
        $hdir = Join-Path $fx "shell/src/x"
        New-Item -ItemType Directory -Path $hdir | Out-Null
        $decls = (1..8 | ForEach-Object { "    void call$_(const QString &instance, int n) override;" }) -join "`n"
        $header = { param($cls, $extra) "class $cls final : public XBackend`n{`npublic:`n    bool isMock() const override { return $cls; }`n$decls`n$extra`nprivate:`n    int m_$cls;`n};" }
        Set-Content -LiteralPath (Join-Path $hdir "DBusXBackend.h") -Value (& $header "DBusX" "") -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $hdir "MockXBackend.h") -Value (& $header "MockX" "") -Encoding UTF8
        $n = @(Invoke-Lint $fx $emptyBl $min 0 6>&1 | Where-Object { $_ -is [int] }) | Select-Object -Last 1
        if ($n -ne 0) { $failed += "a shared list of override declarations in backend headers was reported" }
        Set-Content -LiteralPath (Join-Path $hdir "PlainX.h") -Value (& $header "PlainX" "") -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $hdir "PlainY.h") -Value (& $header "PlainY" "") -Encoding UTF8
        $out = Invoke-Lint $fx $emptyBl $min 0 6>&1 | Out-String
        if ($out -notmatch 'PlainX\.h') { $failed += "override declarations outside a backend header were not reported ($out)" }
        Remove-Item (Join-Path $hdir "PlainX.h"), (Join-Path $hdir "PlainY.h")
        $code = "    void helper() { " + ((1..$min | ForEach-Object { "w$_ ;" }) -join " ") + " }"
        Set-Content -LiteralPath (Join-Path $hdir "DBusXBackend.h") -Value (& $header "DBusX" $code) -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $hdir "MockXBackend.h") -Value (& $header "MockX" $code) -Encoding UTF8
        $out = Invoke-Lint $fx $emptyBl $min 0 6>&1 | Out-String
        if ($out -notmatch 'DBusXBackend\.h:\d+ == shell/src/x/MockXBackend\.h') { $failed += "a planted copy of real code in backend headers was not reported ($out)" }
        Remove-Item -Recurse -Force $hdir
        $script:areas = @("shell/qml")
        & $write ($min - 1)    # the copy is gone: the entry is stale
        Set-Content -LiteralPath $bl -Value "shell/qml/A.qml | shell/qml/B.qml | $min" -Encoding UTF8
        $n = @(Invoke-Lint $fx $bl $min 0 6>&1 | Where-Object { $_ -is [int] }) | Select-Object -Last 1
        if ($n -ne 1) { $failed += "a stale baseline entry did not fail" }
    }
    finally { $script:areas = $savedAreas; Remove-Item -Recurse -Force $fx }
    foreach ($f in $failed) { Write-Host "    self-test: $f" }
    return $failed.Count
}

if ($SelfTest) {
    $bad = Invoke-SelfTest
    if ($bad -gt 0) { exit 1 }
    Write-Host "lint-duplicates self-test ok"
    exit 0
}

if ($Measure) {
    foreach ($n in 30, 50, 80, 120, 200, 400) {
        $pairs = Get-DuplicatePairs $Root $n $MinDistinct
        $tok = 0; foreach ($k in $pairs.Keys) { $tok += $pairs[$k].Tokens }
        Write-Host ("MinTokens {0,4}: {1,4} file pairs, {2,6} duplicated tokens" -f $n, $pairs.Count, $tok)
    }
    exit 0
}

if ($WriteBaseline) {
    $old = (Read-Baseline $Baseline).Reasons
    $pairs = Get-DuplicatePairs $Root $MinTokens $MinDistinct
    $lines = @("# Pairs of files that share MinTokens=$MinTokens or more tokens (lint-duplicates.ps1, RUY-889). Each line is debt:",
               "# share the code and delete the line. Never add a line to get a new copy through; the baseline only shrinks.",
               "# fileA | fileB | duplicated tokens   # reason")
    foreach ($key in $pairs.Keys) {
        $why = if ($old.ContainsKey($key) -and $old[$key]) { $old[$key] } else { "debt" }
        $lines += ("{0} | {1}  # {2}" -f $key, $pairs[$key].Tokens, $why)
    }
    [IO.File]::WriteAllLines($Baseline, $lines, (New-Object Text.UTF8Encoding($false)))
    Write-Host "wrote $($pairs.Count) baseline entries to $Baseline"
    exit 0
}

if ((Invoke-Lint $Root $Baseline $MinTokens $MinDistinct) -gt 0) { exit 1 }
exit 0
