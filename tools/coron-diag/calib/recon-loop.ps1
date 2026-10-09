# Reconnect stimulus for the one-shot lab measurement (2026-10-09): no flash writes at all. Every
# cycle sends 'x' on the right half's console (the firmware drops the PC connection once; the PC
# reconnects within seconds), waits, then reads the console dump and checks:
#   - the breadcrumb seq is unchanged (no reboot, i.e. no crash) and the stage is still RUNNING,
#   - the lab record's crash count is unchanged,
#   - host_conn grew (the PC did reconnect).
# A crash (seq advanced or crashes grew) STOPS the loop: the crash record is already in the dump
# that detected it (the lab image keeps it in RAM across the reboot), nothing else is sent.
# usage: recon-loop.ps1 -RunDir <dir> [-Cycles 200] [-WaitSec 30] [-Serial B17318CDBE9A61B1]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [int]$Cycles = 200,
    [int]$WaitSec = 30,
    [string]$Serial = 'B17318CDBE9A61B1'
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$script:Serial = $Serial
$script:LogFile = Join-Path $RunDir 'recon.log'
$script:Scn = $null
$summary = Join-Path $RunDir 'summary.log'
function SLog([string]$m) {
    $line = (Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m
    for ($k = 0; $k -lt 10; $k++) { try { Add-Content -LiteralPath $summary -Value $line -Encoding UTF8; break } catch { Start-Sleep -Milliseconds 200 } }
    Write-Host $line
}
function Parse([string]$t) {
    $r = @{ seq = $null; st = $null; host = $null; crashes = $null; max = $null; ok = $false }
    if ($null -eq $t) { return $r }
    if ($t -cmatch 'ZDIAG crumb .* seq=(\d+) st=(\d+)') { $r.seq = [int]$Matches[1]; $r.st = [int]$Matches[2] }
    if ($t -cmatch 'ZDIAG now count host_conn=(\d+)') { $r.host = [int]$Matches[1] }
    if ($t -cmatch 'ZDIAG lab live ticks=\d+ max=(\d+)@\d+ .* crashes=(\d+)') { $r.max = [int]$Matches[1]; $r.crashes = [int]$Matches[2] }
    $r.ok = ($null -ne $r.seq -and $null -ne $r.crashes -and ($t -cmatch '(?m)^ZDIAG end'))
    return $r
}
SLog "RECON start cycles=$Cycles wait=${WaitSec}s serial=$Serial"
$t0 = Exchange '' 0
$base = Parse $t0
if (-not $base.ok) { SLog "baseline dump incomplete; STOP"; exit 1 }
SLog ("baseline seq={0} st={1} host_conn={2} crashes={3} max={4}" -f $base.seq, $base.st, $base.host, $base.crashes, $base.max)
if ($base.st -ne 10) { SLog "baseline stage is not RUNNING; STOP"; exit 1 }
$seq = $base.seq; $crashes = $base.crashes; $host = $base.host
$done = 0; $stop = ''
for ($i = 1; $i -le $Cycles; $i++) {
    SLog ("cycle {0} send x (deadline {1}s)" -f $i, ($WaitSec + 40))
    $tx = $null
    try { $tx = Send-Cmd 'x' 3 } catch { SLog ("cycle {0} 'x' not written ({1}); STOP" -f $i, $_.Exception.Message); $stop = 'send-failed'; break }
    $ack = ($null -ne $tx -and ($tx -cmatch 'ZDIAG drop-host rc=(-?\d+)'))
    $rc = if ($ack) { $Matches[1] } else { '?' }
    SLog ("cycle {0} drop-host rc={1}" -f $i, $rc)
    Start-Sleep -Seconds $WaitSec
    $t = Exchange '' 0
    if (-not $t) { Pause-Ms 2000; $t = Exchange '' 0 }
    $p = Parse $t
    $elapsed = ''
    SLog ("cycle {0} result seq={1} st={2} host_conn={3} crashes={4} max={5} complete={6}" -f $i, $p.seq, $p.st, $p.host, $p.crashes, $p.max, $p.ok)
    if (-not $p.ok) { $stop = 'dump-incomplete'; SLog ("cycle {0} STOP ({1}); no further device operation" -f $i, $stop); break }
    if ($p.seq -ne $seq -or $p.crashes -ne $crashes) { $stop = "crash-or-reboot seq=$seq->$($p.seq) crashes=$crashes->$($p.crashes)"; SLog ("cycle {0} STOP ({1}); record is in this cycle's dump" -f $i, $stop); break }
    if ($p.st -ne 10) { $stop = "stage=$($p.st)"; SLog ("cycle {0} STOP ({1})" -f $i, $stop); break }
    if ($p.host -le $host) { SLog ("cycle {0} note: host_conn did not grow ({1} -> {2}); the PC has not reconnected yet" -f $i, $host, $p.host) }
    $host = $p.host
    $done++
}
if (-not $stop) { $stop = 'all-cycles-done' }
SLog "RECON DONE cycles_ok=$done stop=$stop seq=$seq crashes=$crashes host_conn=$host"
if ($stop -eq 'all-cycles-done') { exit 0 } else { exit 1 }
