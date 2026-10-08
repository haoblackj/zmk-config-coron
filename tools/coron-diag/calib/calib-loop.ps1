# Unattended natural-stall loop (review #14): write the base test image, then run trials, each
# being "dwell 13-26 min as app, then ONE operation (an alternating image write, or in reset mode
# a soft reset) and ONE boot", judged from the firmware's own counters; stop at the first event,
# FAIL, deadline or unconfirmed termination; then ALWAYS restore the production image (unless a
# calibration process could not be confirmed dead). No manual operation, no waiting for a person.
#   calib-loop.ps1 -Serial <s> -LogDir <dir> -Uf2Base/-Md5Base -Uf2Alt/-Md5Alt -Uf2Prod/-Md5Prod
#                  -Mode <write|reset> -Dwells <min,min,...> (one trial per entry)
#                  [-NoNewTrialAfter <yyyy-MM-dd HH:mm>] [-RestoreReserveMin 10] [-MockDir <dir>]
# Every operation is a child under a deadline (Invoke-Child / calib-kill.ps1, as in calib-all):
#   flash-base 300 s, trial = dwell*60 + 400 s, restore 300 s. Nothing in this script talks to the
#   device, CIM or a serial port directly.
# Ledger: ledger.json / ledger.csv, one row per trial (mode, image, boot number before/after,
#   uptime before the operation from up_ms, ring counters, result), denominators separated by mode.
# Exit: base 0 = all trials done without an event, 1 = stopped by a script FAIL / timeout,
#   10 = stopped on an event (records saved), 11 = stopped because the device gave no response;
#   +2 when the restore failed or was not attempted; 4 = mock files missing/invalid.
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [Parameter(Mandatory = $true)][string]$Uf2Base, [Parameter(Mandatory = $true)][string]$Md5Base,
    [Parameter(Mandatory = $true)][string]$Uf2Alt, [Parameter(Mandatory = $true)][string]$Md5Alt,
    [Parameter(Mandatory = $true)][string]$Uf2Prod, [Parameter(Mandatory = $true)][string]$Md5Prod,
    [ValidateSet('write', 'reset')][string]$Mode = 'write',
    [string]$Dwells = '13,26,17,21,13',
    [string]$NoNewTrialAfter = '',
    [int]$RestoreReserveMin = 10,
    [string]$TagBase = 'bt4-R-10080217', [string]$TagAlt = 'bt4A-R-10080217',
    [string]$MockDir = ''
)
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:LogFile = Join-Path $LogDir 'summary.log'
function S($m) { Log $m }
$dwellList = @("$Dwells" -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })   # '13,17,26' arrives as '13 17 26' through -File; a separate name: $Dwells is [string]-typed, so assigning an array to it would turn it back into a string
$n = $dwellList.Count
$deadline = @{ 'pre' = 90; 'flash-base' = 300; 'flash-prod' = 300; 'baseline' = 120 }
for ($i = 1; $i -le $n; $i++) { $deadline["t$i"] = $dwellList[$i - 1] * 60 + 400 }
$killModes = @{}
$flash = Join-Path $PSScriptRoot 'calib-flash.ps1'
$trial = Join-Path $PSScriptRoot 'calib-trial.ps1'
$run = Join-Path $PSScriptRoot 'calib-run.ps1'
$common = @('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2Base', $Uf2Base, '-Md5Base', $Md5Base, '-Uf2Alt', $Uf2Alt, '-Md5Alt', $Md5Alt, '-Uf2Prod', $Uf2Prod, '-Md5Prod', $Md5Prod)
$results = [ordered]@{}
$ledger = @()
$stop = ''
$script:alive = @()
$noNewAfter = $null
if ($NoNewTrialAfter) { $noNewAfter = [datetime]::ParseExact($NoNewTrialAfter, 'yyyy-MM-dd HH:mm', $null) }

$mockFiles = @{}
if ($MockDir) {
    $missing = @()
    foreach ($name in @('pre', 'flash-base', 'baseline') + (1..$n | ForEach-Object { "t$_" }) + @('flash-prod')) {
        $p = Join-Path $MockDir "$name.json"
        if (-not (Test-Path -LiteralPath $p)) { $missing += "$name.json missing"; continue }
        try {
            $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            if ($null -eq $j) { throw 'empty' }
            if ($j.step_timeout_s) { $deadline[$name] = [int]$j.step_timeout_s }
            if ($j.kill_mode) { $killModes[$name] = [string]$j.kill_mode }
            $mockFiles[$name] = $p
        } catch { $missing += "$name.json invalid ($($_.Exception.Message))" }
    }
    if ($missing.Count -gt 0) { S ("MOCK FILE MISSING/INVALID: " + ($missing -join '; ') + " -> nothing launched"); S 'LOOP NOT RUN | RESTORE NOT RUN'; exit 4 }
    S "MOCK mode: every child gets its scenario file from $MockDir"
}
function MockArg([string]$name) { if ($MockDir) { return @('-Mock', $mockFiles[$name]) }; return @() }
function Run-Child([string]$name, [string]$file, [string[]]$argv) {
    $out = Join-Path $LogDir "child-$name.out"; $err = Join-Path $LogDir "child-$name.err"
    $t = $deadline[$name]
    S "launch $name (deadline ${t}s)"
    $km = ''; if ($killModes.ContainsKey($name)) { $km = $killModes[$name] }
    $res = Invoke-Child $file $argv $t $out $err $km
    if ($res.timedOut) {
        if ($res.killed) { S "$name did not return within ${t}s: killed with its process tree, termination confirmed"; return 'TIMEOUT' }
        S "$name did not return within ${t}s: termination NOT confirmed (pids still alive: [$($res.alive -join ',')]); a loop process may still operate the device"
        $script:alive += $res.alive
        return 'TIMEOUT-ALIVE'
    }
    if ("$($res.rc)" -ceq '5') { S "$name reports a console child it could not confirm dead (exit 5)"; $script:alive += "child-of-$name" }
    return $res.rc
}
function Device-Unsafe() { return ($script:alive.Count -gt 0) }
function Read-Result([string]$file) { if (Test-Path -LiteralPath $file) { try { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) } catch { return $null } }; return $null }
# A child's exit 0 is accepted only with a complete result file of THIS trial (review #15 point 5).
function Test-ResultComplete($r, [int]$trialNo) {
    if ($null -eq $r) { return 'result file missing or not JSON' }
    if ([int]$r.trial -ne $trialNo) { return "result file is of trial $($r.trial), not $trialNo" }
    if ("$($r.result)" -cne 'ok') { return "result=$($r.result)" }
    if ($null -eq $r.after) { return 'after snapshot missing' }
    foreach ($k in @('seq', 'count', 'dropped', 'invalid', 'ring_reinit', 'up_ms', 'tag', 'done')) { if ($null -eq $r.after.$k) { return "after.$k missing" } }
    if (-not $r.stages.completed) { return 'stages.completed is not set' }
    return ''
}

S ("deadlines: " + (($deadline.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "))
S "LOOP start serial=$Serial mode=$Mode trials=$n dwells=[$($dwellList -join ',')] min no_new_trial_after=$NoNewTrialAfter restore_reserve=${RestoreReserveMin}min"
S "page difference of the two images (UF2 contents, 4 KiB pages): bt4 93 pages, bt4A 104 pages, 0 identical; how many pages the bootloader actually erases is a separate, unmeasured quantity"
# 0. preflight (calib-run.ps1 -Step pre): the base, alternate AND production images must exist with
#    their md5, and the running image must answer, BEFORE the first device operation (review #15
#    point 2). A failure here means no device change has started: no restore is needed.
$deviceChanged = $false
$results['pre'] = Run-Child 'pre' $run (@('-Step', 'pre') + $common + (MockArg 'pre'))
S "pre rc=$($results['pre'])"
if ("$($results['pre'])" -cne '0') { $stop = "pre-failed (rc=$($results['pre'])): nothing written to the device" }
# 1. base image (the boot after it is NOT a trial: no dwell preceded it; its ring state is the baseline)
if (-not $stop) {
    $deviceChanged = $true
    $results['flash-base'] = Run-Child 'flash-base' $flash (@('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2', $Uf2Base, '-Md5', $Md5Base, '-Expect', 'base') + (MockArg 'flash-base'))
    S "flash-base rc=$($results['flash-base'])"
    if ("$($results['flash-base'])" -cne '0') { $stop = 'flash-base-failed' }
}
# 2. baseline: every existing record to the PC, the reference counters
$expect = ''
if (-not $stop) {
    $rf = Join-Path $LogDir 'result-baseline.json'
    $results['baseline'] = Run-Child 'baseline' $trial (@('-Trial', '0', '-Mode', 'baseline', '-Serial', $Serial, '-LogDir', $LogDir, '-ResultFile', $rf, '-TagNow', $TagBase) + (MockArg 'baseline'))
    S "baseline rc=$($results['baseline'])"
    $r0 = Read-Result $rf
    switch ("$($results['baseline'])") {
        '0' { $bad = Test-ResultComplete $r0 0; if ($bad) { $stop = "baseline result invalid: $bad"; S $stop } else { $expect = ($r0.after | ConvertTo-Json -Compress -Depth 4) } }
        '10' { $stop = "event-at-baseline: $($r0.stop_reason)" }
        default { $stop = "baseline-failed (rc=$($results['baseline']))" }
    }
}
# 3. trials (any exception here is a failure of this script: it is logged and the restore decision
#    below still applies)
$tagNow = $TagBase
try {
for ($i = 1; $i -le $n; $i++) {
    $name = "t$i"
    if ($stop -or (Device-Unsafe)) { $results[$name] = 'not-run'; continue }
    $dw = $dwellList[$i - 1]
    if ($noNewAfter) {
        $need = [timespan]::FromMinutes($dw + 7 + $RestoreReserveMin)   # dwell + the operation's own waits + the restore
        if ((Get-Date) + $need -gt $noNewAfter) { $stop = "deadline: trial $i (dwell $dw min + reserve) would end after $NoNewTrialAfter"; S $stop; $results[$name] = 'not-run'; continue }
    }
    if ($Mode -ceq 'write') {
        if ($tagNow -ceq $TagBase) { $img = $Uf2Alt; $md5 = $Md5Alt; $tagNext = $TagAlt } else { $img = $Uf2Base; $md5 = $Md5Base; $tagNext = $TagBase }
    } else { $img = ''; $md5 = ''; $tagNext = $tagNow }
    $rf = Join-Path $LogDir "result-$name.json"
    $argv = @('-Trial', "$i", '-Mode', $Mode, '-DwellMin', "$dw", '-Serial', $Serial, '-LogDir', $LogDir, '-ResultFile', $rf, '-TagNow', $tagNow, '-TagNext', $tagNext, '-Expect', $expect)
    if ($img) { $argv += @('-Uf2', $img, '-Md5', $md5) }
    $rc = Run-Child $name $trial ($argv + (MockArg $name))
    $results[$name] = $rc
    $r = Read-Result $rf
    $st = $(if ($r -and $r.stages) { $r.stages } else { $null })
    $unknown = ($null -eq $st)   # no result file: the stages reached are UNKNOWN, never counted as "not started"
    $row = [ordered]@{ trial = $i; mode = $Mode; image_planned = $img; image_written = $(if ($r) { $r.image_written } else { '' }); tag_before = $tagNow; tag_after_planned = $tagNext
                       tag_after_observed = $(if ($r -and $r.after) { $r.after.tag } else { '' }); rc = "$rc"
                       seq_before = $(if ($r -and $r.before) { $r.before.seq } else { $null }); seq_after = $(if ($r -and $r.after) { $r.after.seq } else { $null })
                       uptime_min_before_op = $(if ($r -and $r.dwell) { $r.dwell.up_min } else { $null }); dwell_min = $dw
                       stages_unknown = $unknown
                       dwell_started = $(if ($st) { [bool]$st.dwell_started } else { 'unknown' }); op_sent = $(if ($st) { [bool]$st.op_sent } else { 'unknown' })
                       image_written_stage = $(if ($st) { [bool]$st.image_written } else { 'unknown' }); boot_observed = $(if ($st) { [bool]$st.boot_observed } else { 'unknown' })
                       running_confirmed = $(if ($st) { [bool]$st.running_confirmed } else { 'unknown' }); completed = $(if ($st) { [bool]$st.completed } else { 'unknown' })
                       ring_after = $(if ($r -and $r.after) { "count=$($r.after.count) dropped=$($r.after.dropped) invalid=$($r.after.invalid) reinit=$($r.after.ring_reinit)" } else { '' })
                       result = $(if ($r) { $r.result } else { 'no result file' }); stop_reason = $(if ($r) { $r.stop_reason } else { '' }) }
    $ledger += $row
    S ("trial $i " + (($row.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    switch ("$rc") {
        '0' { $bad = Test-ResultComplete $r $i; if ($bad) { $stop = "trial $i returned 0 but its result is invalid: $bad"; S $stop } else { $expect = ($r.after | ConvertTo-Json -Compress -Depth 4); $tagNow = $tagNext } }
        '10' { $stop = "event: $($r.stop_reason) (trial $i)" }
        '11' { $stop = "no-observation: $($r.stop_reason) (trial $i)" }
        default { $stop = "trial $i failed (rc=$rc)" }
    }
}
} catch { $stop = "orchestrator-error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"; S $stop }
if (-not $stop) { $stop = 'all-trials-done' }
# 4. restore, always, unless a loop process may still be alive
if (-not $deviceChanged) {
    $results['restore'] = 'not-needed'; $restoreFail = $false
    S "RESTORE NOT NEEDED: no device change was started (the preflight stopped the run); the device still runs what it ran before"
} elseif (Device-Unsafe) {
    $results['restore'] = 'not-attempted'; $restoreFail = $true
    S "RESTORE NOT ATTEMPTED: a loop process may still be alive ([$($script:alive -join ',')]); no further device operation. The device is NOT restored to the production image (recorded as a failure; no manual step is requested)."
} else {
    $results['restore'] = Run-Child 'flash-prod' $flash (@('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2', $Uf2Prod, '-Md5', $Md5Prod, '-Expect', 'prod') + (MockArg 'flash-prod'))
    $restoreFail = ("$($results['restore'])" -cne '0')
}
$ledger | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $LogDir 'ledger.json') -Encoding UTF8
$csv = @()
if ($ledger.Count -gt 0) { $csv += (($ledger[0].Keys) -join ',') }
foreach ($row in $ledger) { $csv += (($row.GetEnumerator() | ForEach-Object { '"' + ("$($_.Value)" -replace '"', '""') + '"' }) -join ',') }
$csv | Set-Content -Path (Join-Path $LogDir 'ledger.csv') -Encoding UTF8
# denominators from what actually happened (review #15 point 6), never from the plan
$known = @($ledger | Where-Object { -not $_.stages_unknown })
$nUnknown = @($ledger | Where-Object { $_.stages_unknown }).Count
$nStarted = @($known | Where-Object { $_.dwell_started }).Count
$nSent = @($known | Where-Object { $_.op_sent }).Count
$nWritten = @($known | Where-Object { $_.image_written_stage }).Count
$nBoot = @($known | Where-Object { $_.boot_observed }).Count
$nRun = @($known | Where-Object { $_.running_confirmed }).Count
$nOk = @($known | Where-Object { $_.completed -and $_.rc -ceq '0' }).Count
$unk = $(if ($nUnknown -gt 0) { ", stages unknown=$nUnknown (no result file; these trials may have operated the device)" } else { '' })
if ($Mode -ceq 'write') { S "ledger: mode=write trials started=$nStarted, b sent=$nSent, images written=$nWritten (boots after a write), boots observed=$nBoot, RUNNING confirmed=$nRun, completed without event=$nOk$unk; stop=$stop" }
else { S "ledger: mode=reset trials started=$nStarted, r sent=$nSent (boots after a soft reset), boots observed=$nBoot, RUNNING confirmed=$nRun, completed without event=$nOk$unk; stop=$stop" }
$base = 0
if ($stop -clike 'event*') { $base = 10 } elseif ($stop -clike 'no-observation*') { $base = 11 } elseif ($stop -cne 'all-trials-done' -and $stop -cnotlike 'deadline*') { $base = 1 }
if ($stop -clike 'pre-failed*') { $base = 1 }
S ("restore " + $(if ($restoreFail) { "FAIL (rc=$($results['restore']))" } else { 'PASS' }))
S ("LOOP " + $(switch ($base) { 0 { 'DONE (no event)' } 10 { 'STOPPED ON EVENT' } 11 { 'STOPPED, NO OBSERVATION' } default { 'FAILED' } }) + " | RESTORE " + $(if ($restoreFail) { 'FAIL' } else { 'PASS' }))
S ("results: " + (($results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') + " stop=" + ($stop -replace ' ', '_'))
exit ($base + $(if ($restoreFail) { 2 } else { 0 }))
