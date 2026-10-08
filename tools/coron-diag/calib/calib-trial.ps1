# One trial of the unattended natural-stall loop (review #14, #15), run as a child of
# calib-loop.ps1 under a deadline. No manual operation, no waiting for a person.
#   calib-trial.ps1 -Trial <n> -Mode <baseline|write|reset> -DwellMin <m> -Serial <s> -LogDir <dir>
#                   -ResultFile <json> [-Uf2 <image> -Md5 <md5>] -TagNow <tag of the running image>
#                   [-TagNext <tag after the write>] [-Expect <json of the previous trial's "after">]
#                   [-Mock <scenario.json>]
# Flow (write mode): baseline dump (every record saved to the PC, compared with -Expect) ->
# dwell for -DwellMin minutes while polling the USB state every 10 s (the first state other than
# 'app' ENDS the dwell at once) -> dump at the end of the dwell (the uptime is the firmware's own
# up_ms; the DWT-based at_us / lastfeed_us wrap every 67.1 s and are never used for time) -> the
# reproduction condition is checked from up_ms -> 'b' -> write -Uf2 -> the device must come back
# as 'app' -> dump(s) until done=1 (RUNNING reached) -> judge. Reset mode: 'r' instead of the
# write. Baseline mode: the first dump only (right after the base image was written).
# Judgement (from the firmware's own counters; review #14 point 3, #15 points 1 and 3):
#   same boot (baseline -> end of dwell): seq, count, dropped, invalid and the reinit flag all
#     unchanged (ring_reinit_this_boot is fixed for the whole boot), up_ms strictly increasing and
#     consistent with the dwell: up_ms(end) - up_ms(start) in [dwell*60 s - 2 s, dwell*60 s + 120 s]
#     (the +120 s covers the dump reads and retries), and up_ms(end) >= dwell*60 s.
#   new boot (after the operation): seq == before + 1, count/dropped/invalid unchanged,
#     reinit == 0 (a reinitialisation in a NEW boot is an event), tag == -TagNext, done == 1 within
#     60 s (6 reads 10 s apart; mock: 3 reads) - a dump without done=1 is never a success.
# Stages recorded in the result (review #15 point 6): dwell_started, dwell_done, op_sent,
#   image_written, boot_observed, running_confirmed, completed - the ledger's denominators are
#   built from these, not from the plan. op_sent comes from the console child's 'sent' stamp and
#   survives a failed exchange ($true / $false / 'unknown' when the child timed out without a
#   stamp; review #16 point 2).
# Exit: 0 = trial done (result file written and complete), 1 = script FAIL / condition not met /
# result could not be saved (stopped before the next device operation); 5 = a console child could
# not be confirmed dead; 10 = event detected (records saved); 11 = the device gave no external
# response / no dump (observation failed: the stall mechanism is NOT decided, the state is saved).
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
$mockNoResult = $false; $mockStale = $false; $mockDropAfter = $false; $mockUnknownStages = $false; $mockCompletedUnknown = $false
if ($Mock) {
    try { Load-Mock $Mock } catch { Log "MOCK ERROR $($_.Exception.Message); nothing done"; exit 4 }
    if ($script:Scn.step_hang_s -gt 0) { Log "MOCK: this trial hangs for $($script:Scn.step_hang_s) s"; Start-Sleep -Seconds $script:Scn.step_hang_s }
    $j = Get-Content -Path $Mock -Raw | ConvertFrom-Json
    if ($j.mock_no_result_file) { $mockNoResult = $true; Log 'MOCK: the result file will NOT be written (simulated inconsistent child)' }
    if ($j.mock_stale_result) { $mockStale = $true; Log 'MOCK: the result file will carry the previous trial number (simulated stale file)' }
    if ($j.mock_drop_after) { $mockDropAfter = $true; Log 'MOCK: the result file will lack the after snapshot (simulated incomplete success)' }
    if ($j.mock_unknown_stages) { $mockUnknownStages = $true; Log "MOCK: a failed result will carry the string 'unknown' in image_written/boot_observed/running_confirmed/completed" }
    if ($j.mock_completed_unknown) { $mockCompletedUnknown = $true; Log "MOCK: a successful result will carry completed='unknown'" }
}
Log "TRIAL $Trial mode=$Mode dwell=${DwellMin}min serial=$Serial image=$Uf2 tag_now=$TagNow tag_next=$TagNext"
$DWELL_EARLY_MS = 2000; $DWELL_LATE_MS = 120000   # tolerance of the dwell check (documented in loop-plan.md)
$res = [ordered]@{ trial = $Trial; mode = $Mode; dwell_min = $DwellMin; image_planned = $Uf2; image_written = ''; tag_now = $TagNow; tag_next = $TagNext;
                   result = 'fail'; stop_reason = ''; before = $null; dwell = $null; after = $null; note = @();
                   stages = [ordered]@{ dwell_started = $false; dwell_done = $false; op_sent = 'not-attempted'; image_written = $false; boot_observed = $false; running_confirmed = $false; completed = $false } }
# op_sent: 'not-attempted' until the send stage, then $true / $false (child's explicit refusal) /
# 'unknown' from the child's stamps. Every other stage is a boolean (the mock hooks below can
# write the string 'unknown' to prove that the orchestrator never counts it; review #18).
$script:saveFailed = $false
function Save-Result {
    if ($mockNoResult) { return }
    try {
        if ($mockStale) { $res.trial = $Trial - 1 }
        if ($mockDropAfter -and $res.result -ceq 'ok') { $res.after = $null }
        if ($mockUnknownStages -and $res.result -cne 'ok') { foreach ($k in @('image_written', 'boot_observed', 'running_confirmed', 'completed')) { $res.stages[$k] = 'unknown' } }
        if ($mockCompletedUnknown -and $res.result -ceq 'ok') { $res.stages['completed'] = 'unknown' }
        $res | ConvertTo-Json -Depth 6 | Set-Content -Path $ResultFile -Encoding UTF8 -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $ResultFile)) { throw 'result file absent after writing' }
    } catch { Log "FAIL result file saved ($($_.Exception.Message))"; $script:fails++; $script:saveFailed = $true }
}
function Parse-Zdiag([string]$t) {
    $h = @{}
    if ($t -cmatch '(?m)^ZDIAG begin .*up_ms=(\d+)') { $h['up_ms'] = [long]$Matches[1] }
    if ($t -cmatch '(?m)^ZDIAG now count (.*)$') { foreach ($kv in ($Matches[1].Trim() -split ' ')) { if ($kv -cmatch '^([a-z_]+)=(\d+)$') { $h[$Matches[1]] = [long]$Matches[2] } } }
    return $h
}
# A dump for the ledger: the ZBOOT table plus the ZDIAG header values; up_ms is required.
function Read-Snapshot([string]$what) {
    Pause-Ms 700
    $t = Exchange
    if (-not $t) { Pause-Ms 1500; $t = Exchange }
    if ($null -eq $t) { return $null }
    $r = Validate-Dump $t $what $true
    $z = Parse-Zdiag $t
    Require "${what}:up_ms present in the ZDIAG begin line" ($null -ne $z['up_ms']) 'up_ms'
    $snap = [ordered]@{
        seq = [int](Need $r 'cur' 'a' 'seq'); tag = (Need $r 'cur' 'a' 'tag'); done = (Need $r 'cur' 'a' 'done'); reinit = (Need $r 'cur' 'a' 'reinit')
        count = [int](Need $r 'ring' 'x' 'count'); dropped = [int](Need $r 'ring' 'x' 'dropped'); invalid = [int](Need $r 'ring' 'x' 'invalid')
        ring_reinit = (Need $r 'ring' 'x' 'reinit'); up_ms = $z['up_ms']; up_min = [math]::Round($z['up_ms'] / 60000.0, 2)
        host_conn = $z['host_conn']; host_disc = $z['host_disc']; split_conn = $z['split_conn']; split_disc = $z['split_disc']
        incidents = @()
    }
    for ($i = 0; $i -lt $snap.count; $i++) {
        $calib = V $r "inc$i" 'a' 'calib'
        $snap.incidents += [ordered]@{ id = "inc$i"; seq = (V $r "inc$i" 'a' 'seq'); reason = (V $r "inc$i" 'a' 'reason'); calib = $calib;
                                       kind = $(if ($calib -cne '-') { 'calibration artifact' } else { 'natural' }); lines = @($r["inc$i"]['_lines']) }
    }
    Log ("${what}: seq=$($snap.seq) tag=$($snap.tag) done=$($snap.done) count=$($snap.count) dropped=$($snap.dropped) invalid=$($snap.invalid) reinit=$($snap.ring_reinit) up_ms=$($snap.up_ms) (" + $snap.up_min + " min) host_conn=$($snap.host_conn) host_disc=$($snap.host_disc) split_conn=$($snap.split_conn) split_disc=$($snap.split_disc)")
    foreach ($inc in $snap.incidents) { foreach ($l in $inc.lines) { Log "saved [$($inc.kind)] $l" } }
    return $snap
}
# Same-boot comparison (seqDelta 0) or new-boot comparison (seqDelta 1). Returns '' or the reason.
function Judge($snap, $exp, [int]$seqDelta, [string]$tag, [string]$what) {
    if ($null -eq $exp) { return '' }
    $r = ''
    if ($snap.seq -ne ($exp.seq + $seqDelta)) { Log "EVENT ${what}: boot number $($exp.seq) -> $($snap.seq), expected +$seqDelta (an unexpected reboot happened)"; $r = 'unexpected-boot-count' }
    if ($seqDelta -eq 0) {
        if ("$($snap.ring_reinit)" -cne "$($exp.ring_reinit)") { Log "EVENT ${what}: the reinit flag changed within the same boot ($($exp.ring_reinit) -> $($snap.ring_reinit)); the firmware holds it for the whole boot"; if (-not $r) { $r = 'reinit-flag-changed-within-boot' } }
        if ($null -ne $exp.up_ms -and $snap.up_ms -le $exp.up_ms) { Log "EVENT ${what}: up_ms went backwards or stood still within the same boot ($($exp.up_ms) -> $($snap.up_ms))"; if (-not $r) { $r = 'uptime-regressed' } }
    } else {
        if ("$($snap.ring_reinit)" -cne '0') { Log "EVENT ${what}: the ring was reinitialised in this new boot (its counters are lost; reinit=1)"; if (-not $r) { $r = 'ring-reinit' } }
    }
    if ($snap.count -ne $exp.count -or $snap.dropped -ne $exp.dropped) {
        Log "EVENT ${what}: incident records count $($exp.count) -> $($snap.count), dropped $($exp.dropped) -> $($snap.dropped) (a new incident was filed)"
        $r = 'new-incident'
        foreach ($inc in $snap.incidents) { if ($inc.kind -ceq 'natural' -and [int]$inc.seq -ge $exp.seq) { Log "new natural incident: $($inc.id) seq=$($inc.seq) reason=$($inc.reason)" } }
    }
    if ($snap.invalid -ne $exp.invalid) { Log "EVENT ${what}: invalid records $($exp.invalid) -> $($snap.invalid)"; if (-not $r) { $r = 'invalid-record' } }
    if ($tag -and $snap.tag -cne $tag) { Log "EVENT ${what}: cur tag=$($snap.tag), expected $tag"; if (-not $r) { $r = 'unexpected-image' } }
    return $r
}
# Dwell: poll the USB state every 10 s (mock: one poll per minute, no sleep); the FIRST state other
# than 'app' ends the dwell at once (review #15 point 4).
function Wait-Dwell([int]$min) {
    $t0 = Get-Date; $polls = 0; $seen = @{}; $left = ''
    while ($true) {
        if ($script:Scn) { if ($polls -ge $min) { break } } elseif (((Get-Date) - $t0).TotalMinutes -ge $min) { break }
        $s = Get-State; $polls++
        if (-not $seen.ContainsKey($s)) { $seen[$s] = 0; Log "dwell: USB state '$s' first seen at poll $polls" }
        $seen[$s]++
        if ($s -cne 'app') { $left = $s; Log "EVENT dwell: the device left 'app' (state=$s) at poll $polls; the dwell ends here"; break }
        Pause-Ms 10000
    }
    return [ordered]@{ polls = $polls; states = $seen; left_app = $left; minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1) }
}
function Stop-Trial([string]$result, [string]$reason, [int]$exitCode) {
    $res.result = $result; $res.stop_reason = $reason; Save-Result
    $script:code = $exitCode
    throw 'TRIAL-STOP'
}
# After a boot: dumps until done=1 (RUNNING reached), at most $maxReads 10 s apart.
function Read-UntilRunning([string]$what, [int]$maxReads) {
    $snap = $null
    for ($k = 1; $k -le $maxReads; $k++) {
        $snap = Read-Snapshot "$what (read $k)"
        if ($null -eq $snap) { return $null }
        if ("$($snap.done)" -ceq '1') { return $snap }
        Log "${what}: done=$($snap.done) (RUNNING not reached yet) at read $k of $maxReads"
        Pause-Ms 10000
    }
    return $snap
}

$script:code = 1
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
        if ($why) { Stop-Trial 'event' $why 10 }
    } elseif ($naturalAtStart -gt 0) {
        Log "EVENT baseline: $naturalAtStart natural incident record(s) already present (origin ambiguous: the boot after the base write, or earlier); saved above"
        Stop-Trial 'event' 'incident-at-baseline' 10
    }
    if ($Mode -ceq 'baseline') {
        Require 'baseline boot reached RUNNING (done=1)' ("$($before.done)" -ceq '1') "done=$($before.done)"
        $res.after = $before; $res.stages.completed = $true; $res.result = 'ok'; Save-Result
        if (-not $script:saveFailed) { $script:code = 0 }
        throw 'TRIAL-DONE'
    }

    NextOp 'nothing (dwell, read only)'
    $res.stages.dwell_started = $true
    Log "dwell start: $DwellMin min (the uptime is taken from up_ms of the dump at the end)"
    $dw = Wait-Dwell $DwellMin
    $res.dwell = $dw
    if ($dw.left_app) {
        # bounded recovery wait, then the records if the device is back; never the test operation
        $back = Wait-State 'app' 90
        if (-not $back) { Log "after leaving 'app' the device did not come back within 90 s (last state=$($script:lastState))"; Stop-Trial 'no-response' "left-app-during-dwell, no return (state=$($script:lastState))" 11 }
        $snap = Read-Snapshot 'after leaving app'
        if ($null -eq $snap) { Stop-Trial 'no-dump' 'left-app-during-dwell, no dump after return' 11 }
        $res.after = $snap
        # no reboot was expected during the dwell: the same-boot comparison reports one as unexpected
        $why = Judge $snap $before 0 $before.tag 'after leaving app'
        Stop-Trial 'event' ("left-app-during-dwell" + $(if ($why) { " ($why)" } else { '' })) 10
    }
    $res.stages.dwell_done = $true
    $endDwell = Read-Snapshot 'end of dwell'
    Require 'dump at the end of the dwell' ($null -ne $endDwell) 'ZDIAG begin'
    $res.dwell.up_ms = $endDwell.up_ms; $res.dwell.up_min = $endDwell.up_min
    $res.dwell.counters = [ordered]@{ host_conn = $endDwell.host_conn; host_disc = $endDwell.host_disc; split_conn = $endDwell.split_conn; split_disc = $endDwell.split_disc }
    $why = Judge $endDwell $before 0 $before.tag 'end of dwell'
    if ($why) { Stop-Trial 'event' $why 10 }
    # the reproduction condition, from the firmware's uptime (review #15 point 3)
    $progress = $endDwell.up_ms - $before.up_ms
    $want = $DwellMin * 60000
    Log "dwell measured by the firmware: up_ms $($before.up_ms) -> $($endDwell.up_ms), progress ${progress} ms for a dwell of ${want} ms (tolerance -$DWELL_EARLY_MS/+$DWELL_LATE_MS ms); uptime before the operation $($endDwell.up_min) min"
    Require 'dwell progress within tolerance' ($progress -ge ($want - $DWELL_EARLY_MS) -and $progress -le ($want + $DWELL_LATE_MS)) "progress=$progress want=$want"
    Require 'uptime before the operation >= dwell' ($endDwell.up_ms -ge $want) "up_ms=$($endDwell.up_ms)"
    $res.dwell.progress_ms = $progress

    if ($Mode -ceq 'write') {
        NextOp "send 'b'"
        Require-File 'image to write' $Uf2 $Md5
        $script:lastSentStamp = $null
        try { $t = Send-Cmd 'b' 2 } finally { $res.stages.op_sent = $(if ($null -eq $script:lastSentStamp) { 'unknown' } else { $script:lastSentStamp }); Log "stage op_sent=$($res.stages.op_sent) (from the console child's stamp, independent of the exchange's outcome)" }
        NextOp 'copy the image to the UF2 drive'
        # the ack line is evidence only (it can be lost with the port); the gate is the bootloader on USB
        $ev = Ack-Evidence $t 'b' 'ZDIAG bootloader'
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
        $res.stages.image_written = $true; $res.image_written = $Uf2
        $res.note += "written $Uf2 at " + (Get-Date).ToString('HH:mm:ss')
        $back = Wait-State 'app' 90
    } else {
        NextOp "send 'r'"
        $script:lastSentStamp = $null
        try { $t = Send-Cmd 'r' 2 } finally { $res.stages.op_sent = $(if ($null -eq $script:lastSentStamp) { 'unknown' } else { $script:lastSentStamp }); Log "stage op_sent=$($res.stages.op_sent) (from the console child's stamp, independent of the exchange's outcome)" }
        NextOp 'nothing more (only reading)'
        # the ack line is evidence only (it can be lost with the port); the gate is any direct sign of the reboot
        $ev = Ack-Evidence $t 'r' 'ZDIAG reboot'
        $left = Wait-Leave-App 10
        Require "'r' acted upon (ack line, port lost after the send, or USB departure within 10 s)" ($ev.ack -or $ev.port_lost -or ($left -cne 'app')) "ack_seen=$($ev.ack) port_lost=$($ev.port_lost) state=$left"
        $res.note += "r sent; ack_seen=$($ev.ack) port_lost=$($ev.port_lost); usb left app: $($left -cne 'app') (state=$left)"
        $back = Wait-State 'app' 60
    }
    if (-not $back) {
        Log "EVENT after ${Mode}: NO EXTERNAL RESPONSE: the device did not come back as 'app' (last USB state=$($script:lastState)); the stall mechanism is not decided by this trial; nothing more is done to the device"
        Stop-Trial 'no-response' "no-external-response (state=$($script:lastState))" 11
    }
    $after = Read-UntilRunning "after $Mode" $(if ($script:Scn) { 3 } else { 6 })
    if ($null -eq $after) {
        Log "EVENT after ${Mode}: the device is on USB as app but gave no dump (observation failed; saved as such)"
        Stop-Trial 'no-dump' 'observation-failed (no dump)' 11
    }
    $res.stages.boot_observed = $true
    $res.after = $after
    $why = Judge $after $before 1 $TagNext "after $Mode"
    if ($why) { Stop-Trial 'event' $why 10 }
    if ("$($after.done)" -cne '1') { Log "EVENT after ${Mode}: the boot never reported done=1 (RUNNING) within the window; the console answers but the instrument did not reach RUNNING"; Stop-Trial 'event' 'running-not-reached' 10 }
    $res.stages.running_confirmed = $true
    Log "trial $Trial ok: boot $($before.seq) -> $($after.seq), done=1, ring unchanged (count=$($after.count) dropped=$($after.dropped) invalid=$($after.invalid)), tag=$($after.tag), uptime before the operation $($endDwell.up_min) min"
    $res.stages.completed = $true; $res.result = 'ok'; Save-Result
    if ($script:fails -eq 0 -and -not $script:saveFailed) { $script:code = 0 }
} catch {
    $m = $_.Exception.Message
    if ($m -cne 'CALIB-ABORT' -and $m -cne 'TRIAL-STOP' -and $m -cne 'TRIAL-DONE') { Log "ERROR $m at $($_.InvocationInfo.PositionMessage)"; $script:fails++; $script:code = 1 }
    if ($m -ceq 'CALIB-ABORT') { Log "STOPPED before: $script:nextOp"; $res.result = 'fail'; $res.stop_reason = "script FAIL before: $script:nextOp"; Save-Result; $script:code = 1 }
    if ($script:childAlive) { Log "a console child may still be alive (termination not confirmed): exit 5"; $script:code = 5 }
}
if ($script:saveFailed -and $script:code -eq 0) { Log 'the result file could not be saved: the trial counts as FAILED'; $script:code = 1 }
switch ($script:code) {
    0 { Log "TRIAL $Trial RESULT OK (continue)" }
    1 { Log "TRIAL $Trial RESULT FAIL ($($script:fails) failed checks)" }
    5 { Log "TRIAL $Trial RESULT FAIL (console child may be alive)" }
    10 { Log "TRIAL $Trial RESULT EVENT ($($res.stop_reason)); records saved; stop" }
    11 { Log "TRIAL $Trial RESULT NO OBSERVATION ($($res.stop_reason)); stop" }
}
exit $script:code
