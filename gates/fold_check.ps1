#!/usr/bin/env pwsh
# fold_check — every clause changed in this ship carries a resolving provenance pin.
#
# Generic, MODE-BLIND gate (works identically for Mode A external tracker and Mode B
# on-disk backlog). Enforces the fold-on-ship invariant at ship time: every spec clause
# touched by this change is pinned (§X per <unit-id>, YYYY-MM-DD) and the unit-id resolves.
#
# Resolution of <unit-id>:
#   * Mode B (default): under foldCheck.backlogRoot, a file or dir named <unit-id>*, or a
#     heading / anchor (id=, name=, {#..}) naming the unit inside any file. backlogRoot may
#     also name a single backlog file (one heading per item).
#   * Mode A: if foldCheck.resolveCmd is set ({unit} substituted) it is run; exit 0 = resolves.
#   * Neither a resolver nor backlogRoot on disk -> "syntactically valid unit-id" + a NOTE.
#
# A clause is its DEFINITION SPAN: from the line that defines it (an id="X.N" / name= /
# {#X.N} anchor, or a Markdown heading / list / table / bold line that starts with the id)
# up to the next definition or heading. A clause-id merely cited in prose defines nothing.
# A clause is checked when its span overlaps a line changed since baseRef (git diff -U0),
# and one pin anywhere in the span covers it. A shard with no definitions at all falls
# back to every clause-id line (pin on it or the next line), with a NOTE.
#
# FAIL CLOSED if git present but base unresolvable (exit 2). git-absent -> all clauses of
# all shards + NOTE. Exit 0 PASS, 1 FAIL, 2 config/usage error.
#
# -Strict: when a resolver IS configured (foldCheck.resolveCmd) but ERRORS or returns
# non-zero, treat the unit as UNRESOLVED (FAIL) instead of degrading to "syntactic pin +
# NOTE". CI MUST run with -Strict so an offline/broken resolver cannot fail open. Without
# -Strict the current degrade-with-NOTE convenience is kept (local/offline). The
# "no resolver configured at all" syntactic-only path is unchanged in both modes.
#
# Usage:  pwsh gates/fold_check.ps1 [-Config gates/gates.config.json] [-Base <ref>] [-Strict]

[CmdletBinding()]
param(
    [string]$Config = 'gates/gates.config.json',
    [string]$Base,
    [switch]$Strict
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$cfg = Read-Config $Config 'fold_check'
$base = $Base
if (-not $base) { $base = Get-CfgValue $cfg 'baseRef' 'main' }

$gitAvailable = [bool](Get-Command git -ErrorAction SilentlyContinue)

# base_state: ('absent') if git missing; else whether base resolves.
if ($gitAvailable) {
    git rev-parse --verify --quiet "$base^{commit}" 2>&1 | Out-Null
    $baseOk = ($LASTEXITCODE -eq 0)
    if (-not $baseOk) {
        Write-Output "FAIL fold_check: baseRef '$base' does not resolve - set baseRef to the ship base."
        exit 2
    }
}

$specGlob = 'spec/**/*.body.md'
if ($cfg.PSObject.Properties.Name -contains 'paths' -and $cfg.paths -and ($cfg.paths.PSObject.Properties.Name -contains 'spec') -and $cfg.paths.spec) {
    $specGlob = $cfg.paths.spec
}
$clausePattern = Get-CfgValue $cfg 'clauseIdRegex' '\b[A-Z]{2,}\.\d+\b'
$unitPattern   = Get-CfgValue $cfg 'unitIdRegex' '\b[A-Z]+-\d+\b'
$clauseRe = [regex]$clausePattern
$clauseFullRe = [regex]('^(?:' + $clausePattern + ')$')
$pinRe = [regex]('\bper\s+(?<unit>' + $unitPattern + ')\s*,\s*(?<date>\d{4}-\d{2}-\d{2})')
# Definition forms: id= / name= anchors, {#..}, or a heading / list / table / bold line led by the id.
$anchorRes = @([regex]'(?:id|name)\s*=\s*(?:"([^"]*)"|''([^'']*)'')', [regex]'\{#([^}\s]+)\}')
$leadRe = [regex]('^[ \t]*(?:#+[ \t]+|[-*+][ \t]+|[0-9]+[.)][ \t]+|\|[ \t]*)?[*_]*(?<id>' + $clausePattern + ')')
$headingRe = [regex]'^[ \t]*#+[ \t]|<[hH][1-6][ \t>]'

function Get-NormPath([string]$p) { return ($p -replace '\\', '/') }

$allShardsList = Expand-Globs $specGlob
$allShards = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($s in $allShardsList) { [void]$allShards.Add((Get-NormPath $s)) }

function Invoke-GitDiff([string[]]$gitArgs) {
    # Returns the stdout lines on success, or $null if git errored / is absent.
    $out = & git @gitArgs 2>$null
    if ($LASTEXITCODE -eq 0) { return ,@($out) }
    return $null
}

# changed_lines: path -> HashSet[int] of new-side lines changed vs base (git diff -U0).
# A pure deletion marks the lines on both sides of the cut. Git absent -> ALL.
$allMode = $false
$changed = @{}
$diffOut = $null
if ($gitAvailable) {
    $diffArgs = @('-c', 'core.quotePath=false', 'diff', '-U0', '--no-color', '--no-ext-diff', '--src-prefix=a/', '--dst-prefix=b/')
    $diffOut = Invoke-GitDiff ($diffArgs + "$base...HEAD")
    if ($null -eq $diffOut) { $diffOut = Invoke-GitDiff ($diffArgs + "$base") }
}
if ($null -eq $diffOut) {
    Write-Output "NOTE fold_check: git unavailable - checking ALL spec shards."
    $allMode = $true
} else {
    $cur = ''
    foreach ($raw in $diffOut) {
        $line = [string]$raw
        if ($line.StartsWith('+++ ')) {
            $cur = $line.Substring(4) -replace "`t$", '' -replace '^"', '' -replace '"$', ''
            if ($cur -eq '/dev/null') { $cur = '' } else { $cur = $cur -replace '^b/', '' }
            continue
        }
        if ($cur -and $line.StartsWith('@@ ')) {
            $hm = [regex]::Match($line, '\+(\d+)(?:,(\d+))?')
            if (-not $hm.Success) { continue }
            $c = [int]$hm.Groups[1].Value
            $d = if ($hm.Groups[2].Success) { [int]$hm.Groups[2].Value } else { 1 }
            if (-not $changed.ContainsKey($cur)) { $changed[$cur] = New-Object 'System.Collections.Generic.HashSet[int]' }
            if ($d -eq 0) { [void]$changed[$cur].Add($c); [void]$changed[$cur].Add($c + 1) }
            else { for ($k = $c; $k -lt $c + $d; $k++) { [void]$changed[$cur].Add($k) } }
        }
    }
}

if ($allMode) {
    $files = @($allShards | Sort-Object)
} else {
    $files = @($changed.Keys | Where-Object { $allShards.Contains($_) } | Sort-Object)
}

if ($files.Count -eq 0) {
    Write-Output "PASS fold_check: no spec shards changed this ship."
    exit 0
}

# Get-Defs: clause-ids this line DEFINES (anchors, then a leading id), in order, deduped.
function Get-Defs([string]$line) {
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($re in $anchorRes) {
        foreach ($m in $re.Matches($line)) {
            $v = ''
            for ($g = 1; $g -lt $m.Groups.Count; $g++) { if ($m.Groups[$g].Success) { $v = $m.Groups[$g].Value; break } }
            if ($clauseFullRe.IsMatch($v) -and -not $ids.Contains($v)) { $ids.Add($v) }
        }
    }
    $lm = $leadRe.Match($line)
    if ($lm.Success) {
        $v = $lm.Groups['id'].Value
        if (-not $ids.Contains($v)) { $ids.Add($v) }
    }
    return ,$ids
}

$unpinned = New-Object System.Collections.Generic.List[object]
$seenUnits = New-Object 'System.Collections.Generic.HashSet[string]'
$fallbacks = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
    $lines = @(Read-FileLines $f)
    # Read-FileLines yields a trailing '' for a final newline; drop it so line counts match awk.
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
    $n = $lines.Count
    $cl = $null
    if (-not $allMode) { $cl = $changed[$f] }
    $defs = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $n; $i++) {
        $ids = Get-Defs $lines[$i]
        if ($ids.Count -gt 0) { $defs.Add([pscustomobject]@{ line = $i + 1; ids = $ids }) }
    }
    $fb = $false
    if ($defs.Count -eq 0) {
        for ($i = 0; $i -lt $n; $i++) {
            $ids = New-Object System.Collections.Generic.List[string]
            foreach ($m in $clauseRe.Matches($lines[$i])) { if (-not $ids.Contains($m.Value)) { $ids.Add($m.Value) } }
            if ($ids.Count -gt 0) { $defs.Add([pscustomobject]@{ line = $i + 1; ids = $ids }); $fb = $true }
        }
        if ($fb) { $fallbacks.Add($f) }
    }
    $reported = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($k = 0; $k -lt $defs.Count; $k++) {
        $s = $defs[$k].line
        if ($fb) {
            $e = [Math]::Min($s + 1, $n)
        } else {
            $e = if ($k + 1 -lt $defs.Count) { $defs[$k + 1].line - 1 } else { $n }
            for ($j = $s + 1; $j -le $e; $j++) { if ($headingRe.IsMatch($lines[$j - 1])) { $e = $j - 1; break } }
        }
        $touched = $allMode
        for ($j = $s; $j -le $e -and -not $touched; $j++) { if ($cl.Contains($j)) { $touched = $true } }
        if (-not $touched) { continue }
        $text = ($lines[($s - 1)..($e - 1)]) -join ' '
        $best = ''; $bunit = ''
        foreach ($pm in $pinRe.Matches($text)) {
            $dt = $pm.Groups['date'].Value
            if ($best -eq '' -or [string]::CompareOrdinal($dt, $best) -ge 0) { $best = $dt; $bunit = $pm.Groups['unit'].Value }
        }
        foreach ($cid in $defs[$k].ids) {
            if ($bunit) { [void]$seenUnits.Add($bunit) }
            elseif ($reported.Add($cid)) { $unpinned.Add([pscustomobject]@{ file = $f; cid = $cid }) }
        }
    }
}

foreach ($f in $fallbacks) {
    Write-Output "NOTE fold_check: no clause definitions in $f - each clause-id line needs a pin on it or the next line."
}

# Test-NamesUnit: some file at/under $path has a heading or anchor naming $unit.
function Test-NamesUnit([string]$unit, [string]$path) {
    $wordRe = [regex]('(?<![A-Za-z0-9_])' + [regex]::Escape($unit) + '(?![A-Za-z0-9_])')
    $anchors = @("id=""$unit""", "id='$unit'", "name=""$unit""", "name='$unit'", "{#$unit}")
    foreach ($file in @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        foreach ($line in (Read-FileLines $file.FullName)) {
            if ($line -match '^[ \t]*#+[ \t]' -and $wordRe.IsMatch($line)) { return $true }
            foreach ($a in $anchors) { if ($line.Contains($a)) { return $true } }
        }
    }
    return $false
}

# resolve each seen unit-id: returns '' when it resolves, else the reason it did not.
function Resolve-Unit([string]$unit, $cfg, [bool]$strict) {
    $fc = Get-CfgValue $cfg 'foldCheck' $null
    $cmd = $null
    if ($fc) { $cmd = Get-CfgValue $fc 'resolveCmd' $null }
    if ($cmd) {
        $expanded = $cmd -replace '\{unit\}', $unit
        $rc = $null
        try {
            if ($env:ComSpec) {
                # Windows: run through cmd.exe (shell=True analogue).
                & $env:ComSpec /c $expanded 2>&1 | Out-Null
            } else {
                # POSIX pwsh: run through /bin/sh.
                & sh -c $expanded 2>&1 | Out-Null
            }
            $rc = $LASTEXITCODE
        } catch {
            # Resolver could not even be launched / threw — treat like a non-zero result.
            $rc = 1
        }
        if ($rc -eq 0) { return '' }
        # Configured resolver errored or returned non-zero.
        #   strict     -> UNRESOLVED (FAIL): a broken/offline resolver cannot pass open.
        #   non-strict -> degrade to the syntactic pin + NOTE (local/offline convenience).
        if ($strict) {
            [Console]::Out.WriteLine("FAIL fold_check: resolveCmd errored for $unit - strict mode treats this as unresolved.")
            return 'resolveCmd did not resolve it'
        }
        [Console]::Out.WriteLine("NOTE fold_check: resolveCmd failed for $unit - accepting syntactic pin.")
        return ''
    }
    $root = 'backlog'
    if ($fc) { $root = Get-CfgValue $fc 'backlogRoot' 'backlog' }
    if (Test-Path -LiteralPath $root -PathType Container) {
        # Mode B: a file/dir named <unit>* directly under backlogRoot, or a heading/anchor in a file.
        $hits = @(Get-ChildItem -LiteralPath $root -Filter "$unit*" -Force -ErrorAction SilentlyContinue)
        if ($hits.Count -gt 0 -or (Test-NamesUnit $unit $root)) { return '' }
        return "no $root/$unit* file and no heading or anchor naming it under $root/"
    }
    if (Test-Path -LiteralPath $root -PathType Leaf) {
        # Mode B, single-file backlog: a heading/anchor naming the unit inside backlogRoot.
        if (Test-NamesUnit $unit $root) { return '' }
        return "no heading or anchor naming it in $root"
    }
    [Console]::Out.WriteLine("NOTE fold_check: no resolver and no $root/ - accepting syntactic pin for $unit.")
    return ''
}

$unresolved = New-Object System.Collections.Generic.List[object]
foreach ($unit in ($seenUnits | Sort-Object)) {
    $why = Resolve-Unit $unit $cfg ([bool]$Strict)
    if ($why) { $unresolved.Add([pscustomobject]@{ unit = $unit; why = $why }) }
}

if ($unpinned.Count -eq 0 -and $unresolved.Count -eq 0) {
    Write-Output "PASS fold_check: $($files.Count) changed shard(s); all changed clauses pinned and resolved."
    exit 0
}

Write-Output "FAIL fold_check: $($unpinned.Count) unpinned clause(s), $($unresolved.Count) unresolved unit(s)."
foreach ($u in $unpinned) {
    Write-Output "  UNPINNED $($u.cid)  in $($u.file)  (add: (§... per <unit-id>, YYYY-MM-DD))"
}
foreach ($u in $unresolved) {
    Write-Output "  UNRESOLVED-UNIT $($u.unit)  ($($u.why))"
}
exit 1
