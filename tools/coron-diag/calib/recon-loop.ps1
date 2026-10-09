# Reconnect stimulus for the one-shot lab measurement (2026-10-09, v2 after the Codex review): no
# flash writes at all. Every cycle sends 'x' on the right half's console (the firmware drops the PC
# connection once; the PC reconnects within seconds), waits, then reads the console dump and
# checks:
#   - the breadcrumb seq is unchanged (no reboot) and the stage is still RUNNING,
#   - the lab record's crash count is unchanged,
#   - the 'x' was acknowledged (drop-host rc=0) and the PC reconnected (host_conn grew); if not,
#     the dump is re-read a few times (read-only) and the loop STOPS without sending another 'x'.
# A crash (seq advanced or crashes grew) STOPS the loop: the crash record is already in the dump
# that detected it (the lab image keeps it in RAM across the reboot), nothing else is sent.
# At the baseline and at the end the LEFT half's dump is read too (its own crash records).
# Every summary line carries PC wall time; every saved dump carries the device's up_ms.
# v3 (lab image v3, assert off): a late prepare is a record WITHOUT a reboot ('marks' and the per-ticker
# 'over' counters grow). -StopOnRecord 0 keeps cycling through those and stops only on a reboot
# (seq advanced) or a stage change; every cycle logs marks and the split/PC lateness counters.
# usage: recon-loop.ps1 -RunDir <dir> [-Cycles 200] [-WaitSec 30] [-Serial B17318CDBE9A61B1] [-LeftSerial 743A486E04021F9D] [-StopOnRecord 0]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [int]$Cycles = 200,
    [int]$WaitSec = 30,
    [string]$Serial = 'B17318CDBE9A61B1',
    [string]$LeftSerial = '743A486E04021F9D',
    [int]$StopOnRecord = 1   # int, not bool: 'powershell -File' passes every argument as a string
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$script:Serial = $Serial
$script:LogFile = Join-Path $RunDir 'recon.log'
$script:Scn = $null
$script:DumpSeconds = 60   # the v3/v4 dump with 3 records is ~70 KB; 30 s cut it off (2026-10-09 19:41)
$summary = Join-Path $RunDir 'summary.log'
function SLog([string]$m) {
    $line = (Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m
    for ($k = 0; $k -lt 10; $k++) { try { Add-Content -LiteralPath $summary -Value $line -Encoding UTF8; break } catch { Start-Sleep -Milliseconds 200 } }
    Write-Host $line
}
function Parse([string]$t) {
    $r = @{ seq = $null; st = $null; host = $null; crashes = $null; dropped = $null; max = $null; up = $null; ok = $false; trunc = $false; marks = 0; over5 = ''; over6 = '' }
    if ($null -eq $t) { return $r }
    if ($t -cmatch 'ZDIAG begin version=\S+ up_ms=(\d+)') { $r.up = [int]$Matches[1] }
    if ($t -cmatch 'ZDIAG crumb .* seq=(\d+) st=(\d+)') { $r.seq = [int]$Matches[1]; $r.st = [int]$Matches[2] }
    if ($t -cmatch 'ZDIAG now count host_conn=(\d+)') { $r.host = [int]$Matches[1] }
    if ($t -cmatch 'ZDIAG lab live .* max=(\d+)@\d+ .* crashes=(\d+) dropped=(\d+)') { $r.max = [int]$Matches[1]; $r.crashes = [int]$Matches[2]; $r.dropped = [int]$Matches[3] }
    if ($t -cmatch 'ZDIAG lab live v\d+ .* marks=(\d+)') { $r.marks = [int]$Matches[1] }
    # per-ticker lateness counters: id 5 = PC connection (handle 0), id 6 = split connection (handle 1)
    if ($t -cmatch 'ZDIAG lab liveprepstat id=5 n=(\d+) max_late=(\d+) last_late=\d+ over=(\d+)') { $r.over5 = "n=$($Matches[1]) max=$($Matches[2]) over=$($Matches[3])" }
    if ($t -cmatch 'ZDIAG lab liveprepstat id=6 n=(\d+) max_late=(\d+) last_late=\d+ over=(\d+)') { $r.over6 = "n=$($Matches[1]) max=$($Matches[2]) over=$($Matches[3])" }
    $r.trunc = ($t -cmatch '#TRUNC')
    $r.ok = ($null -ne $r.seq -and $null -ne $r.crashes -and ($t -cmatch '(?m)^ZDIAG lab end') -and ($t -cmatch '(?m)^ZDIAG end') -and -not $r.trunc)
    return $r
}
function Read-Left([string]$label) {
    $save = $script:Serial
    $script:Serial = $LeftSerial
    $t = Exchange '' 0
    $script:Serial = $save
    $p = Parse $t
    SLog ("left {0}: seq={1} st={2} crashes={3} dropped={4} marks={7} max={5} complete={6} split[{8}]" -f $label, $p.seq, $p.st, $p.crashes, $p.dropped, $p.max, $p.ok, $p.marks, $p.over6)
    return $p
}
SLog "RECON start cycles=$Cycles wait=${WaitSec}s serial=$Serial left=$LeftSerial"
$t0 = Exchange '' 0
$base = Parse $t0
if (-not $base.ok) { SLog "baseline dump incomplete or truncated; STOP"; exit 1 }
SLog ("baseline seq={0} st={1} host_conn={2} crashes={3} dropped={4} max={5} up_ms={6}" -f $base.seq, $base.st, $base.host, $base.crashes, $base.dropped, $base.max, $base.up)
if ($base.st -ne 10) { SLog "baseline stage is not RUNNING; STOP"; exit 1 }
$leftBase = Read-Left 'baseline'
$seq = $base.seq; $crashes = $base.crashes; $hostc = $base.host
$done = 0; $stop = ''
for ($i = 1; $i -le $Cycles; $i++) {
    SLog ("cycle {0} send x (deadline {1}s)" -f $i, ($WaitSec + 60))
    $tx = $null
    try { $tx = Send-Cmd 'x' 3 } catch { SLog ("cycle {0} 'x' not written ({1}); STOP" -f $i, $_.Exception.Message); $stop = 'send-failed'; break }
    $rc = '?'
    if ($null -ne $tx -and ($tx -cmatch 'ZDIAG drop-host rc=(-?\d+)')) { $rc = $Matches[1] }
    SLog ("cycle {0} drop-host rc={1}" -f $i, $rc)
    if ($rc -ne '0') { $stop = "drop-host rc=$rc"; SLog ("cycle {0} STOP ({1}); the stimulus did not happen, nothing more is sent" -f $i, $stop); break }
    Start-Sleep -Seconds $WaitSec
    $p = $null
    for ($k = 0; $k -lt 4; $k++) {
        $t = Exchange '' 0
        $p = Parse $t
        if ($p.ok -and $p.host -gt $hostc) { break }
        if ($p.ok -and ($p.seq -ne $seq -or $p.crashes -ne $crashes)) { break }
        SLog ("cycle {0} re-read {1}: seq={2} host_conn={3} crashes={4} complete={5} (waiting for the PC to reconnect)" -f $i, ($k + 1), $p.seq, $p.host, $p.crashes, $p.ok)
        Start-Sleep -Seconds 15
    }
    SLog ("cycle {0} result seq={1} st={2} host_conn={3} crashes={4} dropped={5} marks={9} max={6} up_ms={7} complete={8} pc[{10}] split[{11}]" -f $i, $p.seq, $p.st, $p.host, $p.crashes, $p.dropped, $p.max, $p.up, $p.ok, $p.marks, $p.over5, $p.over6)
    if (-not $p.ok) { $stop = 'dump-incomplete'; SLog ("cycle {0} STOP ({1}); no further device operation" -f $i, $stop); break }
    if ($p.seq -ne $seq) { $stop = "reboot seq=$seq->$($p.seq) crashes=$crashes->$($p.crashes)"; SLog ("cycle {0} STOP ({1}); the record is in this cycle's dump" -f $i, $stop); break }
    if ($p.crashes -ne $crashes) {
        if ($StopOnRecord -ne 0) { $stop = "record crashes=$crashes->$($p.crashes)"; SLog ("cycle {0} STOP ({1}); the record is in this cycle's dump" -f $i, $stop); break }
        SLog ("cycle {0} record(s) taken: crashes={1}->{2} (continuing: -StopOnRecord is off)" -f $i, $crashes, $p.crashes)
        $crashes = $p.crashes
    }
    if ($p.st -ne 10) { $stop = "stage=$($p.st)"; SLog ("cycle {0} STOP ({1})" -f $i, $stop); break }
    if ($p.host -le $hostc) { $stop = 'no-reconnect'; SLog ("cycle {0} STOP ({1}): host_conn stayed {2}; nothing more is sent" -f $i, $stop, $p.host); break }
    $hostc = $p.host
    $done++
}
if (-not $stop) { $stop = 'all-cycles-done' }
$leftEnd = Read-Left 'end'
SLog "RECON DONE cycles_ok=$done stop=$stop seq=$seq crashes=$crashes host_conn=$hostc left_crashes=$($leftEnd.crashes) left_marks=$($leftEnd.marks)"
if ($stop -eq 'all-cycles-done') { exit 0 } else { exit 1 }
