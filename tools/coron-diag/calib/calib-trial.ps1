# One trial of the unattended natural-stall loop (review #14), run as a child of calib-loop.ps1
# under a deadline. No manual operation, no waiting for a person.
#   calib-trial.ps1 -Trial <n> -Mode <baseline|write|reset> -DwellMin <m> -Serial <s> -LogDir <dir>
#                   -ResultFile <json> [-Uf2 <image> -Md5 <md5>] -TagNow <tag of the running image>
#                   [-TagNext <tag after the write>] [-Expect <json of the previous trial's "after">]
#                   [-Mock <scenario.json>]
# Flow (write mode): baseline dump (every record saved to the PC, compared with -Expect) ->
# dwell for -DwellMin minutes while polling the USB state (the device must stay 'app') -> dump
# at the end of the dwell (up_ms = the uptime the firmware itself reports; the DWT-based at_us /
# lastfeed_us wrap every 67.1 s and are never used for time) -> 'b' -> write -Uf2 -> the device
# must come back as 'app' -> dump -> judge. Reset mode: 'r' instead of the write. Baseline mode:
# the first dump only (right after the base image was written).
# Judgement after a boot (all from the firmware's own counters, review #14 point 3):
#   seq == before + 1, ring count/dropped/invalid unchanged, reinit == 0, cur tag == -TagNext.
#   Otherwise: a new incident record (count or dropped grew), a ring reinitialisation (counters
#   lost) or an unexpected boot count is an EVENT: every record is saved to the PC first, then the
#   trial stops with exit 10 so that no further write happens before the restore.
# Exit: 0 = trial done, continue; 1 = script FAIL (precondition, stopped before the next device
# operation); 5 = a console child could not be confirmed dead; 10 = event detected (records
# saved); 11 = the device gave no external response / no dump after the operation (observation
# failed: the stall mechanism is NOT decided, the state seen is saved).
param(
    [Parameter(Mandatory = $true)][int]$Trial,
    [Parameter(Mandatory = $true)][ValidateSet('baseline', 'write', 'reset')][string]$Mode,
    [int]$DwellMin = 0,
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [Parameter(Mandatory = $true)][string]$ResultFile,
    [string]$Uf2 = '', [string]$Md5 = '',
    [string]$TagNow = '', [string]$TagNext = '',
    [string]$Expect = '',
    [string]$Mock = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:Serial = $Serial
$script:LogFile = Join-Path $LogDir ("trial$Trial-$Mode-" + (Get-Date).ToString('MMdd-HHmmss') + '.log')
$script:Scn = $null
if ($Mock) {
    try { Load-Mock $Mock } catch { Log "MOCK ERROR $($_.Exception.Message); nothing done"; exit 4 }
    if ($script:Scn.step_hang_s -gt 0) { Log "MOCK: this trial hangs for $($script:Scn.step_hang_s) s"; Start-Sleep -Seconds $script:Scn.step_hang_s }
}
Log "TRIAL $Trial mode=$Mode dwell=${DwellMin}min serial=$Serial image=$Uf2 tag_now=$TagNow tag_next=$TagNext"
$res = [ordered]@{ trial = $Trial; mode = $Mode; dwell_min = $DwellMin; image = $Uf2; tag_now = $TagNow; tag_next = $TagNext;
                   result = 'fail'; stop_reason = ''; before = $null; dwell = $null; after = $null; note = @() }
function Save-Result { $res | ConvertTo-Json -Depth 6 | Set-Content -Path $ResultFile -Encoding UTF8 }

# "ZDIAG begin version=.. up_ms=N .." and "ZDIAG now count host_conn=.. ..": the firmware's own
# uptime and connection counters.
function Parse-Zdiag([string]$t) {
    $h = @{}
    if ($t -cmatch '(?m)^ZDIAG begin .*up_ms=(\d+)') { $h['up_ms'] = [long]$Matches[1] }
    if ($t -cmatch '(?m)^ZDIAG now count (.*)$') { foreach ($kv in ($Matches[1].Trim() -split ' ')) { if ($kv -cmatch '^([a-z_]+)=(\d+)$') { $h[$Matches[1]] = [long]$Matches[2] } } }
    return $h
}
# A dump read for the ledger: the parsed ZBOOT table plus the ZDIAG header values.
function Read-Snapshot([string]$what) {
    Pause-Ms 700
    $t = Exchange
    if (-not $t) { Pause-Ms 1500; $t = Exchange }
    if ($null -eq $t) { return $null }
    $r = Validate-Dump $t $what $true
    $z = Parse-Zdiag $t
    $snap = [ordered]@{
        seq = [int](Need $r 'cur' 'a' 'seq'); tag = (Need $r 'cur' 'a' 'tag'); done = (Need $r 'cur' 'a' 'done'); reinit = (Need $r 'cur' 'a' 'reinit')
        count = [int](Need $r 'ring' 'x' 'count'); dropped = [int](Need $r 'ring' 'x' 'dropped'); invalid = [int](Need $r 'ring' 'x' 'invalid')
        ring_reinit = (Need $r 'ring' 'x' 'reinit'); up_ms = $z['up_ms']; up_min = $(if ($null -ne $z['up_ms']) { [math]::Round($z['up_ms'] / 60000.0, 1) } else { $null })
        host_conn = $z['host_conn']; host_disc = $z['host_disc']; split_conn = $z['split_conn']; split_disc = $z['split_disc']
        incidents = @()
    }
    for ($i = 0; $i -lt $snap.count; $i++) {
        $calib = V $r "inc$i" 'a' 'calib'
        $snap.incidents += [ordered]@{ id = "inc$i"; seq = (V $r "inc$i" 'a' 'seq'); reason = (V $r "inc$i" 'a' 'reason'); calib = $calib;
                                       kind = $(if ($calib -cne '-') { 'calibration artifact' } else { 'natural' }); lines = @($r["inc$i"]['_lines']) }
    }
    Log ("${what}: seq=$($snap.seq) tag=$($snap.tag) count=$($snap.count) dropped=$($snap.dropped) invalid=$($snap.invalid) reinit=$($snap.ring_reinit) up_ms=$($snap.up_ms) (" + $snap.up_min + " min) host_conn=$($snap.host_conn) host_disc=$($snap.host_disc) split_conn=$($snap.split_conn) split_disc=$($snap.split_disc)")
    foreach ($inc in $snap.incidents) { foreach ($l in $inc.lines) { Log "saved [$($inc.kind)] $l" } }
    return $snap
}
# Compares a snapshot with the expected ring state; returns '' or the stop reason.
function Judge($snap, $exp, [int]$seqDelta, [string]$tag, [string]$what) {
    if ($null -eq $exp) { return '' }
    $r = ''
    if ($snap.seq -ne ($exp.seq + $seqDelta)) { Log "EVENT ${what}: boot number $($exp.seq) -> $($snap.seq), expected +$seqDelta (an unexpected reboot happened)"; $r = 'unexpected-boot-count' }
    if ($snap.ring_reinit -cne '0') { Log "EVENT ${what}: the ring was reinitialised this boot (its counters are lost; cur.ring_reinit=1)"; $r = 'ring-reinit' }
    if ($snap.count -ne $exp.count -or $snap.dropped -ne $exp.dropped) {
        Log "EVENT ${what}: incident records count $($exp.count) -> $($snap.count), dropped $($exp.dropped) -> $($snap.dropped) (a new incident was filed)"
        $r = 'new-incident'
        foreach ($inc in $snap.incidents) { if ($inc.kind -ceq 'natural' -and [int]$inc.seq -ge $exp.seq) { Log "new natural incident: $($inc.id) seq=$($inc.seq) reason=$($inc.reason)" } }
    }
    if ($snap.invalid -ne $exp.invalid) { Log "EVENT ${what}: invalid records $($exp.invalid) -> $($snap.invalid)"; if (-not $r) { $r = 'invalid-record' } }
    if ($tag -and $snap.tag -cne $tag) { Log "EVENT ${what}: cur tag=$($snap.tag), expected $tag"; if (-not $r) { $r = 'unexpected-image' } }
    return $r
}
# Dwell: the device runs as 'app' for $min minutes; the USB state is polled every 10 s (mock: once
# per minute, no sleep). Returns a summary; a state other than 'app' is an event.
function Wait-Dwell([int]$min) {
    $t0 = Get-Date; $polls = 0; $seen = @{}; $left = ''
    while ($true) {
        if ($script:Scn) { if ($polls -ge $min) { break } } elseif (((Get-Date) - $t0).TotalMinutes -ge $min) { break }
        $s = Get-State; $polls++
        if (-not $seen.ContainsKey($s)) { $seen[$s] = 0; Log "dwell: USB state '$s' first seen at poll $polls" }
        $seen[$s]++
        if ($s -cne 'app' -and -not $left) { $left = $s; Log "EVENT dwell: the device left 'app' (state=$s) at poll $polls" }
        Pause-Ms 10000
    }
    return [ordered]@{ polls = $polls; states = $seen; left_app = $left; minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1) }
}

$code = 1
try {
    $exp = $null
    if ($Expect) { $exp = ($Expect | ConvertFrom-Json) }
    NextOp 'nothing (baseline read)'
    Require 'device on USB as app with a diag port' (Wait-State 'app' 20) ("state=" + $script:lastState)
    $before = Read-Snapshot 'baseline'
    Require 'baseline dump present' ($null -ne $before) 'ZDIAG begin'
    $res.before = $before
    if ($TagNow) { Require "running image tag=$TagNow" ($before.tag -ceq $TagNow) $before.tag }
    $naturalAtStart = @($before.incidents | Where-Object { $_.kind -ceq 'natural' }).Count
    if ($exp) {
        $why = Judge $before $exp 0 '' 'baseline vs previous trial'
        if ($why) { $res.result = 'event'; $res.stop_reason = $why; Save-Result; $code = 10; throw 'TRIAL-STOP' }
    } elseif ($naturalAtStart -gt 0) {
        Log "EVENT baseline: $naturalAtStart natural incident record(s) already present (origin ambiguous: the boot after the base write, or earlier); saved above"
        $res.result = 'event'; $res.stop_reason = 'incident-at-baseline'; Save-Result; $code = 10; throw 'TRIAL-STOP'
    }
    if ($Mode -ceq 'baseline') { $res.result = 'ok'; $res.after = $before; Save-Result; $code = 0; throw 'TRIAL-DONE' }

    NextOp 'nothing (dwell, read only)'
    Log "dwell start: $DwellMin min (the uptime is taken from up_ms of the dump at the end)"
    $dw = Wait-Dwell $DwellMin
    $res.dwell = $dw
    $endDwell = Read-Snapshot 'end of dwell'
    Require 'dump at the end of the dwell' ($null -ne $endDwell) 'ZDIAG begin'
    $res.dwell.up_ms = $endDwell.up_ms; $res.dwell.up_min = $endDwell.up_min
    $res.dwell.counters = [ordered]@{ host_conn = $endDwell.host_conn; host_disc = $endDwell.host_disc; split_conn = $endDwell.split_conn; split_disc = $endDwell.split_disc }
    Log "dwell done: polls=$($dw.polls) left_app='$($dw.left_app)' uptime=$($endDwell.up_min) min (up_ms=$($endDwell.up_ms))"
    $why = Judge $endDwell $before 0 $before.tag 'end of dwell'
    if ($dw.left_app -and -not $why) { $why = 'left-app-during-dwell' }
    if ($why) { $res.result = 'event'; $res.stop_reason = $why; Save-Result; $code = 10; throw 'TRIAL-STOP' }

    if ($Mode -ceq 'write') {
        NextOp "send 'b'"
        Require-File 'image to write' $Uf2 $Md5
        $t = Send-Cmd 'b' 2
        NextOp 'copy the image to the UF2 drive'
        Require 'b acknowledged' ($t -cmatch 'ZDIAG bootloader') 'ZDIAG bootloader'
        Require 'bootloader of this serial on USB within 30 s' (Wait-State 'boot' 30) ("state=" + $script:lastState)
        Pause-Ms 500
        $drives = @(Get-Uf2DrivesOfSerial)
        Require 'exactly one UF2 drive tied to this serial' ($drives.Count -eq 1) ("drives of serial=[$($drives -join ',')] all uf2 drives=[$((Get-AllUf2Drives) -join ',')]")
        Require 'exactly one bootloader on USB' ((Count-Bootloaders) -eq 1) ("count=" + (Count-Bootloaders))
        Require 'image md5 (re-checked at copy time)' ((File-Md5 $Uf2) -ceq $Md5.ToLower()) (File-Md5 $Uf2)
        $ok = Copy-Uf2 $Uf2 $drives[0]
        NextOp 'nothing more (only reading)'
        Require 'copy raised no error' $ok ("to " + $drives[0])
        Require 'UF2 drive vanished within 30 s (image taken)' (Wait-Uf2Gone $drives[0] 30) ("drive " + $drives[0])
        $res.note += "written $Uf2 at " + (Get-Date).ToString('HH:mm:ss')
        $back = Wait-State 'app' 90
    } else {
        NextOp "send 'r'"
        $t = Send-Cmd 'r' 2
        NextOp 'nothing more (only reading)'
        Require 'r acknowledged' ($t -cmatch 'ZDIAG reboot') 'ZDIAG reboot'
        $left = Wait-Leave-App 10
        $res.note += "r sent; usb left app: $($left -cne 'app') (state=$left)"
        $back = Wait-State 'app' 60
    }
    if (-not $back) {
        Log "EVENT after ${Mode}: NO EXTERNAL RESPONSE: the device did not come back as 'app' (last USB state=$($script:lastState)); the stall mechanism is not decided by this trial; nothing more is done to the device"
        $res.result = 'no-response'; $res.stop_reason = "no-external-response (state=$($script:lastState))"; Save-Result; $code = 11; throw 'TRIAL-STOP'
    }
    $after = Read-Snapshot "after $Mode"
    if ($null -eq $after) {
        Log "EVENT after ${Mode}: the device is on USB as app but gave no dump (observation failed; saved as such)"
        $res.result = 'no-dump'; $res.stop_reason = 'observation-failed (no dump)'; Save-Result; $code = 11; throw 'TRIAL-STOP'
    }
    $res.after = $after
    $why = Judge $after $before 1 $TagNext "after $Mode"
    if ($why) { $res.result = 'event'; $res.stop_reason = $why; Save-Result; $code = 10; throw 'TRIAL-STOP' }
    Log "trial $Trial ok: boot $($before.seq) -> $($after.seq), ring unchanged (count=$($after.count) dropped=$($after.dropped) invalid=$($after.invalid)), tag=$($after.tag), uptime before the operation $($endDwell.up_min) min"
    $res.result = 'ok'; Save-Result
    if ($script:fails -eq 0) { $code = 0 }
} catch {
    $m = $_.Exception.Message
    if ($m -cne 'CALIB-ABORT' -and $m -cne 'TRIAL-STOP' -and $m -cne 'TRIAL-DONE') { Log "ERROR $m at $($_.InvocationInfo.PositionMessage)"; $script:fails++; $code = 1 }
    if ($m -ceq 'CALIB-ABORT') { Log "STOPPED before: $script:nextOp"; $res.result = 'fail'; $res.stop_reason = "script FAIL before: $script:nextOp"; Save-Result; $code = 1 }
    if ($script:childAlive) { Log "a console child may still be alive (termination not confirmed): exit 5"; $code = 5 }
}
switch ($code) {
    0 { Log "TRIAL $Trial RESULT OK (continue)" }
    1 { Log "TRIAL $Trial RESULT FAIL ($($script:fails) failed checks)" }
    5 { Log "TRIAL $Trial RESULT FAIL (console child may be alive)" }
    10 { Log "TRIAL $Trial RESULT EVENT ($($res.stop_reason)); records saved; stop" }
    11 { Log "TRIAL $Trial RESULT NO OBSERVATION ($($res.stop_reason)); stop" }
}
exit $code
