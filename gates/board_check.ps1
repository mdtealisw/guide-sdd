#!/usr/bin/env pwsh
# board_check - the stage board (board.file) and the Mode B backlog agree.
#
# The backlog is the item store; the board holds only sprint membership, GUIDE stage and owner
# (board/README.md). Drift = a board item that is not in the backlog, an open board item whose backlog
# item is shipped, or a done board item whose backlog item is still open. board/board.mjs `done` closes
# both in one run; this gate catches every other path (a hand edit, a renumbered row, a lost write).
#
# Backlog (foldCheck.backlogRoot, or board.store.root): a DIRECTORY holds one file per item - key = the
# first unit-id in the file name, closed = a `shipped:` line. A FILE holds one item per row - a ##-####
# heading or a top-level "- " bullet led by the unit-id (after any * _ [ ( ); a bullet runs over its
# indented lines, a heading to the next heading or row; closed = a `shipped:` line in the row, or the
# row sits in board.store.closed. The first occurrence of a key wins. Same rules as board.mjs.
#
# -Ship <KEY>: also require KEY on the board as done AND closed in the backlog (the record-ship step).
#
# OPTIONAL: board.file unset PASSes with "not configured" (Mode A: the tracker is the board).
# Exit 0 PASS, 1 FAIL (drift), 2 config error.
# Usage:  pwsh gates/board_check.ps1 [-Config gates/gates.config.json] [-Ship <KEY>]

[CmdletBinding()]
param(
    [string]$Config = 'gates/gates.config.json',
    [string]$Ship = ''
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$cfg = Read-Config $Config 'board_check'
$b = Get-CfgValue $cfg 'board' $null
$board = if ($b) { Get-CfgValue $b 'file' '' } else { '' }
if (-not $board) {
    Write-Output 'PASS board_check: not configured (board.file unset).'
    exit 0
}
if (-not (Test-Path -LiteralPath $board -PathType Leaf)) {
    Write-Output "FAIL board_check: board.file $board does not exist - run: node sdd/board/board.mjs init"
    exit 2
}
$store = if ($b) { Get-CfgValue $b 'store' $null } else { $null }
$root = if ($store) { Get-CfgValue $store 'root' '' } else { '' }
if (-not $root) {
    $fc = Get-CfgValue $cfg 'foldCheck' $null
    $root = if ($fc) { Get-CfgValue $fc 'backlogRoot' 'backlog' } else { 'backlog' }
}
$closed = if ($store) { Get-CfgValue $store 'closed' '' } else { '' }
$unitPattern = Get-CfgValue $cfg 'unitIdRegex' '\b[A-Z]{2,}-\d+\b'
if (-not (Test-PortableRegex 'board_check' 'unitIdRegex' $unitPattern)) { exit 2 }
$unitRe = [regex]$unitPattern
$rowRe = [regex]('^(?:##|###|####|-)[ \t]+[*_\[( \t]*')
$shippedRe = [regex]'(?i)^[ \t]*[-*]?[ \t]*shipped[: \t]'

try { $bj = Get-Content -LiteralPath $board -Raw | ConvertFrom-Json } catch {
    Write-Output "FAIL board_check: $board is not valid board JSON"
    exit 2
}
$items = @(if ($bj.items) { $bj.items })

# Store: key -> 'open' | 'closed', first occurrence wins.
$st = [ordered]@{}
function Add-Row([string]$k, [string]$state) { if ($k -and -not $st.Contains($k)) { $st[$k] = $state } }
function Get-Rows([string]$file, [bool]$allClosed) {
    $cur = ''; $kind = ''; $shipped = $false
    foreach ($line in (Read-FileLines $file)) {
        $m = $rowRe.Match($line)
        if ($m.Success) {
            $um = $unitRe.Match($line.Substring($m.Length))
            if ($um.Success -and $um.Index -eq 0) {
                if ($cur) { Add-Row $cur $(if ($shipped -or $allClosed) { 'closed' } else { 'open' }) }
                $cur = $um.Value; $kind = if ($line.StartsWith('#')) { 'h' } else { 'b' }; $shipped = $false
                continue
            }
        }
        if ($line.StartsWith('#')) {
            if ($cur) { Add-Row $cur $(if ($shipped -or $allClosed) { 'closed' } else { 'open' }) }
            $cur = ''; continue
        }
        if ($cur) {
            if ($kind -eq 'b' -and $line -notmatch '^[ \t]+[^ \t]') {
                Add-Row $cur $(if ($shipped -or $allClosed) { 'closed' } else { 'open' })
                $cur = ''; continue
            }
            if ($shippedRe.IsMatch($line)) { $shipped = $true }
        }
    }
    if ($cur) { Add-Row $cur $(if ($shipped -or $allClosed) { 'closed' } else { 'open' }) }
}

if (Test-Path -LiteralPath $root -PathType Container) {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.md' -File | Sort-Object Name)) {
        $um = $unitRe.Match($f.Name)
        if (-not $um.Success) { continue }
        $isShipped = @(Read-FileLines $f.FullName | Where-Object { $shippedRe.IsMatch($_) }).Count -gt 0
        Add-Row $um.Value $(if ($isShipped) { 'closed' } else { 'open' })
    }
} elseif (Test-Path -LiteralPath $root -PathType Leaf) {
    Get-Rows $root $false
    if ($closed -and (Test-Path -LiteralPath $closed -PathType Leaf)) { Get-Rows $closed $true }
} else {
    Write-Output "FAIL board_check: no backlog at $root (board.store.root / foldCheck.backlogRoot)"
    exit 2
}

$drift = New-Object System.Collections.Generic.List[string]
function Add-Drift([string]$line) { if (-not $drift.Contains($line)) { $drift.Add($line) } }
$onBoard = @{}
foreach ($i in $items) {
    $k = [string]$i.k; $done = ([string]$i.stage -eq 'done'); $onBoard[$k] = [string]$i.stage
    if (-not $st.Contains($k)) { Add-Drift "$k`ton board but not in the backlog -> board.mjs remove $k" }
    elseif (-not $done -and $st[$k] -eq 'closed') { Add-Drift "$k`tboard-open but shipped in the backlog -> board.mjs check --fix" }
    elseif ($done -and $st[$k] -eq 'open') { Add-Drift "$k`tboard-done but the backlog item is still open -> board.mjs done $k `"<note>`"" }
}
if ($Ship) {
    if (-not $onBoard.ContainsKey($Ship)) { Add-Drift "$Ship`tshipped item not on the board -> board.mjs done $Ship `"<note>`"" }
    elseif ($onBoard[$Ship] -ne 'done') { Add-Drift "$Ship`tshipped item not done on the board (stage $($onBoard[$Ship])) -> board.mjs done $Ship `"<note>`"" }
    if ($st.Contains($Ship) -and $st[$Ship] -eq 'open') { Add-Drift "$Ship`tshipped item still open in the backlog -> board.mjs done $Ship `"<note>`"" }
    elseif (-not $st.Contains($Ship)) { Add-Drift "$Ship`tshipped item not in the backlog" }
}

if ($drift.Count -eq 0) {
    if ($Ship) { Write-Output "PASS board_check: $($items.Count) board item(s), no drift; $Ship done on the board and closed in the backlog." }
    else { Write-Output "PASS board_check: $($items.Count) board item(s), no drift." }
    exit 0
}
Write-Output "FAIL board_check: $($drift.Count) drift between $board and the backlog."
foreach ($d in $drift) {
    $k, $why = $d -split "`t", 2
    Write-Output "  DRIFT $k  $why"
}
exit 1
