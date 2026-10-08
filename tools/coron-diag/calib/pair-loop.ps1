# Pair test (2026-10-09, leader's request "左も組み合わせた試験を考えといて"): add the partner's
# comings and goings of a real keymap update (the other half vanishing into its bootloader, coming
# back, or booting at the same time) to the boots. Every lab loop so far had the partner running
# steadily. Each cycle runs three procedures with checks between them:
#   S1 sequential : write R, dwell, write L, dwell
#   S2 overlap a  : 'b' to L (L vanishes), write R at once (R boots without L), write L (L comes
#                   back to a running R), dwell
#   S3 overlap b  : 'b' to R, write L at once, write R, dwell
# Images: each half alternates its two images (test image with the overhead assert on, partner image
# with it off), so the four combinations come around. Writes go through calib-flash.ps1 -Expect prod
# (-AllowOtherBootloaders in S2/S3 where both halves can be in their bootloaders).
# Checks: the written half's crumb (pv=1 pst=10 st=10, seq advanced by one from its last known seq);
# the other half's crumb after the dwell (seq unchanged = it did not reboot, st=10); the right's
# 'ZDIAG now count' after the dwell (split_conn=1; host_conn logged). Any failed check STOPS the loop
# without further device operation.
# usage: pair-loop.ps1 -RunDir <dir> -RA <uf2> -RAmd5 <md5> -RB <uf2> -RBmd5 <md5> -LA <uf2> -LAmd5 <md5> -LB <uf2> -LBmd5 <md5>
#        [-Cycles 40] [-DwellSec 60] [-FirstR A|B] [-FirstL A|B] [-SerialR ..] [-SerialL ..]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$RA, [Parameter(Mandatory = $true)][string]$RAmd5,
    [Parameter(Mandatory = $true)][string]$RB, [Parameter(Mandatory = $true)][string]$RBmd5,
    [Parameter(Mandatory = $true)][string]$LA, [Parameter(Mandatory = $true)][string]$LAmd5,
    [Parameter(Mandatory = $true)][string]$LB, [Parameter(Mandatory = $true)][string]$LBmd5,
    [int]$Cycles = 40,
    [int]$DwellSec = 60,
    [ValidateSet('A', 'B')][string]$FirstR = 'A',
    [ValidateSet('A', 'B')][string]$FirstL = 'A',
    [string]$SerialR = 'B17318CDBE9A61B1',
    [string]$SerialL = '743A486E04021F9D'
)
$ErrorActionPreference = 'Stop'
$flash = Join-Path $PSScriptRoot 'calib-flash.ps1'
$halfio = Join-Path $PSScriptRoot 'half-io.ps1'
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$script:Summary = Join-Path $RunDir 'summary.log'
function Log([string]$m) {
    $line = (Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m
    $written = $false
    for ($k = 0; $k -lt 10 -and -not $written; $k++) {
        try { Add-Content -LiteralPath $script:Summary -Value $line -Encoding UTF8; $written = $true }
        catch { Start-Sleep -Milliseconds 200 }
    }
    Write-Host $line
}
# Run a child powershell script, return @{rc; out} (rc -1 when unreadable; never a pass).
function Run-Child([string[]]$argv, [int]$timeoutMs, [string]$outFile, [string]$errFile) {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $argv) -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutMs)) { return @{ rc = -2; out = ''; pid = $p.Id } }
    $rc = $p.ExitCode; if ($null -eq $rc) { $rc = -1 }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
    return @{ rc = $rc; out = ($out -replace "`r`n", "`n") }
}
function Parse-Crumb([string]$text) {
    $line = ($text -split "`n" | Where-Object { $_ -cmatch '^ZDIAG crumb ' } | Select-Object -First 1)
    if (-not $line) { return $null }
    if ($line -cmatch 'pv=(\d+) pseq=(\d+) pst=(\d+) prst=(0x[0-9a-f]+) pint=(0x[0-9a-f]+) piser1=(0x[0-9a-f]+) seq=(\d+) st=(\d+)') {
        return @{ line = $line; pv = [int]$Matches[1]; pseq = [int]$Matches[2]; pst = [int]$Matches[3]; prst = $Matches[4]; pint = $Matches[5]; seq = [int]$Matches[7]; st = [int]$Matches[8] }
    }
    return @{ line = $line }
}
function Parse-Now([string]$text) {
    $line = ($text -split "`n" | Where-Object { $_ -cmatch '^ZDIAG now count ' } | Select-Object -First 1)
    if ($line -and $line -cmatch 'host_conn=(\d+) host_disc=(\d+) split_conn=(\d+) split_disc=(\d+)') {
        return @{ line = $line; host = [int]$Matches[1]; split = [int]$Matches[3] }
    }
    return @{ line = "$line" }
}
$imgs = @{
    R = @{ A = @{ Name = 'A'; Uf2 = $RA; Md5 = $RAmd5 }; B = @{ Name = 'B'; Uf2 = $RB; Md5 = $RBmd5 } }
    L = @{ A = @{ Name = 'A'; Uf2 = $LA; Md5 = $LAmd5 }; B = @{ Name = 'B'; Uf2 = $LB; Md5 = $LBmd5 } }
}
$serial = @{ R = $SerialR; L = $SerialL }
$next = @{ R = $FirstR; L = $FirstL }
$seqKnown = @{ R = $null; L = $null }   # last seq seen on each half
$script:stop = ''
$script:stepDir = ''
$script:nR = 0; $script:nL = 0
function Fail([string]$why) { $script:stop = $why; throw 'PAIR-STOP' }

# Write the next image to half $h; verify its crumb; update seqKnown. Logs "write" and "result".
function Write-Half([string]$h, [bool]$allowOther) {
    $img = $imgs[$h][$next[$h]]
    $ld = Join-Path $script:stepDir "write-$h-$($img.Name)"
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    Log ("  write $h image=$($img.Name) (deadline 200s)")
    $argv = @($flash, '-Serial', $serial[$h], '-LogDir', $ld, '-Uf2', $img.Uf2, '-Md5', $img.Md5, '-Expect', 'prod')
    if ($allowOther) { $argv += '-AllowOtherBootloaders' }
    $r = Run-Child $argv 200000 (Join-Path $ld 'child.out') (Join-Path $ld 'child.err')
    if ($r.rc -eq -2) { Log ("  write $h child did not exit within 200 s (pid $($r.pid)); not killed"); Fail "write-$h-timeout" }
    $io = Get-ChildItem -LiteralPath $ld -Filter 'flash-prod-*-io*.out' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    $text = ''
    if ($io) { $text = ([string](Get-Content -LiteralPath $io.FullName -Raw)) -replace "`r`n", "`n" }
    $c = Parse-Crumb $text
    $ok = ($r.rc -eq 0 -and $null -ne $c -and $c.ContainsKey('seq') -and $c.pv -eq 1 -and $c.pst -eq 10 -and $c.st -eq 10 -and $c.seq -eq ($c.pseq + 1))
    if ($ok -and $null -ne $seqKnown[$h] -and $c.pseq -ne $seqKnown[$h]) { $ok = $false }
    $cl = ''; if ($c) { $cl = $c.line }
    Log ("  result write $h image=$($img.Name) rc=$($r.rc) crumb=`"$cl`" ok=$ok")
    if (-not $ok) { Fail "write-$h-check rc=$($r.rc)" }
    $seqKnown[$h] = $c.seq
    $next[$h] = $(if ($next[$h] -ceq 'A') { 'B' } else { 'A' })
    if ($h -ceq 'R') { $script:nR++ } else { $script:nL++ }
}
# Read half $h's dump; require crumb seq unchanged and st=10 (it did not reboot in the meantime).
# For R also parse the connection counters. Returns the parsed 'now' table.
function Check-Half([string]$h, [string]$what) {
    $ld = Join-Path $script:stepDir "read-$h-$what"
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    $r = Run-Child @($halfio, '-Serial', $serial[$h], '-LogDir', $ld) 60000 (Join-Path $ld 'child.out') (Join-Path $ld 'child.err')
    if ($r.rc -eq -2) { Log ("  read $h child did not exit within 60 s (pid $($r.pid)); not killed"); Fail "read-$h-timeout" }
    $c = Parse-Crumb $r.out
    $n = Parse-Now $r.out
    $ok = ($r.rc -eq 0 -and $null -ne $c -and $c.ContainsKey('seq') -and $c.st -eq 10 -and $c.seq -eq $seqKnown[$h])
    $cl = ''; if ($c) { $cl = $c.line }
    Log ("  check $h ($what) rc=$($r.rc) crumb=`"$cl`" now=`"$($n.line)`" unchanged=$ok")
    if (-not $ok) { Fail "check-$h-$what" }
    return $n
}
function Require-Split($n, [string]$what) {
    if (-not $n.ContainsKey('split')) { Log "  split state unreadable ($what)"; Fail "split-unreadable-$what" }
    if ($n.split -ne 1) { Log "  split not connected after the dwell ($what): $($n.line)"; Fail "split-not-connected-$what" }
    if ($n.host -ne 1) { Log "  note: host (PC) not connected after the dwell ($what): $($n.line)" }
}
function Enter-Bootloader([string]$h) {
    $ld = Join-Path $script:stepDir "boot-$h"
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    Log ("  'b' to $h (deadline 60s)")
    $r = Run-Child @($halfio, '-Serial', $serial[$h], '-LogDir', $ld, '-Bootloader') 60000 (Join-Path $ld 'child.out') (Join-Path $ld 'child.err')
    if ($r.rc -ne 0) { Log ("  'b' to $h failed rc=$($r.rc)"); Fail "bootloader-$h rc=$($r.rc)" }
    # the crumb of the boot that received 'b' stays the previous record: seqKnown is unchanged
}
function Dwell([string]$what) { Log ("  dwell ${DwellSec}s after $what (deadline $($DwellSec + 30)s)"); Start-Sleep -Seconds $DwellSec }
function Step([int]$cy, [string]$name) { $script:stepDir = Join-Path $RunDir ('cycle-{0:d3}-{1}' -f $cy, $name); New-Item -ItemType Directory -Force -Path $script:stepDir | Out-Null; Log ("cycle $cy $name") }

Log "PAIR start cycles=$Cycles dwell=${DwellSec}s R=$SerialR L=$SerialL RA=$RA ($RAmd5) RB=$RB ($RBmd5) LA=$LA ($LAmd5) LB=$LB ($LBmd5) firstR=$FirstR firstL=$FirstL"
$done = 0
try {
    # baseline: both halves running, both crumbs readable (seqKnown learned here)
    Step 0 'baseline'
    foreach ($h in @('R', 'L')) {
        $ld = Join-Path $script:stepDir "read-$h"
        New-Item -ItemType Directory -Force -Path $ld | Out-Null
        $r = Run-Child @($halfio, '-Serial', $serial[$h], '-LogDir', $ld) 60000 (Join-Path $ld 'child.out') (Join-Path $ld 'child.err')
        $c = Parse-Crumb $r.out
        if ($r.rc -ne 0 -or $null -eq $c -or -not $c.ContainsKey('seq') -or $c.st -ne 10) { Log "  baseline $h unreadable rc=$($r.rc)"; Fail "baseline-$h" }
        $seqKnown[$h] = $c.seq
        Log ("  baseline $h crumb=`"$($c.line)`"")
    }
    for ($cy = 1; $cy -le $Cycles; $cy++) {
        Step $cy 'S1-sequential'
        Write-Half 'R' $false
        Dwell 'R'
        Check-Half 'L' 'after-R' | Out-Null
        $n = Check-Half 'R' 'after-R'; Require-Split $n 'S1 after R'
        Write-Half 'L' $false
        Dwell 'L'
        $n = Check-Half 'R' 'after-L'; Require-Split $n 'S1 after L'

        Step $cy 'S2-overlap-a'
        Enter-Bootloader 'L'
        Write-Half 'R' $true          # R boots while L sits in its bootloader
        Write-Half 'L' $true          # L comes back to a running R (L already in bootloader: no 'b')
        Dwell 'L'
        $n = Check-Half 'R' 'after-L'; Require-Split $n 'S2 after L'
        Check-Half 'L' 'after-dwell' | Out-Null

        Step $cy 'S3-overlap-b'
        Enter-Bootloader 'R'
        Write-Half 'L' $true          # L boots while R sits in its bootloader
        Write-Half 'R' $true          # R comes back to a running L
        Dwell 'R'
        Check-Half 'L' 'after-R' | Out-Null
        $n = Check-Half 'R' 'after-dwell'; Require-Split $n 'S3 after R'
        $done++
    }
} catch {
    if ($_.Exception.Message -cne 'PAIR-STOP') { $script:stop = "error: $($_.Exception.Message)" }
    Log ("STOP ($script:stop); no further device operation")
}
if (-not $script:stop) { $script:stop = 'all-cycles-done' }
Log "PAIR DONE cycles_ok=$done stop=$script:stop boots_R=$script:nR boots_L=$script:nL seqR=$($seqKnown.R) seqL=$($seqKnown.L) nextR=$($next.R) nextL=$($next.L)"
if ($script:stop -eq 'all-cycles-done') { exit 0 } else { exit 1 }
