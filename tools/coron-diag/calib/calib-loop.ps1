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
$deadline = @{ 'flash-base' = 300; 'flash-prod' = 300; 'baseline' = 120 }
for ($i = 1; $i -le $n; $i++) { $deadline["t$i"] = $dwellList[$i - 1] * 60 + 400 }
$killModes = @{}
$flash = Join-Path $PSScriptRoot 'calib-flash.ps1'
$trial = Join-Path $PSScriptRoot 'calib-trial.ps1'
$results = [ordered]@{}
$ledger = @()
$stop = ''
$script:alive = @()
$noNewAfter = $null
if ($NoNewTrialAfter) { $noNewAfter = [datetime]::ParseExact($NoNewTrialAfter, 'yyyy-MM-dd HH:mm', $null) }

$mockFiles = @{}
if ($MockDir) {
    $missing = @()
    foreach ($name in @('flash-base', 'baseline') + (1..$n | ForEach-Object { "t$_" }) + @('flash-prod')) {
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
function Read-Result([string]$file) { if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }; return $null }

S ("deadlines: " + (($deadline.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "))
S "LOOP start serial=$Serial mode=$Mode trials=$n dwells=[$($dwellList -join ',')] min no_new_trial_after=$NoNewTrialAfter restore_reserve=${RestoreReserveMin}min"
S "page difference of the two images (UF2 contents, 4 KiB pages): bt4 93 pages, bt4A 104 pages, 0 identical; how many pages the bootloader actually erases is a separate, unmeasured quantity"
# 1. base image (the boot after it is NOT a trial: no dwell preceded it; its ring state is the baseline)
$results['flash-base'] = Run-Child 'flash-base' $flash (@('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2', $Uf2Base, '-Md5', $Md5Base, '-Expect', 'base') + (MockArg 'flash-base'))
S "flash-base rc=$($results['flash-base'])"
if ("$($results['flash-base'])" -cne '0') { $stop = 'flash-base-failed' }
# 2. baseline: every existing record to the PC, the reference counters
$expect = ''
if (-not $stop) {
    $rf = Join-Path $LogDir 'result-baseline.json'
    $results['baseline'] = Run-Child 'baseline' $trial (@('-Trial', '0', '-Mode', 'baseline', '-Serial', $Serial, '-LogDir', $LogDir, '-ResultFile', $rf, '-TagNow', $TagBase) + (MockArg 'baseline'))
    S "baseline rc=$($results['baseline'])"
    $r0 = Read-Result $rf
    switch ("$($results['baseline'])") {
        '0' { $expect = ($r0.after | ConvertTo-Json -Compress -Depth 4) }
        '10' { $stop = "event-at-baseline: $($r0.stop_reason)" }
        default { $stop = "baseline-failed (rc=$($results['baseline']))" }
    }
}
# 3. trials
$tagNow = $TagBase
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
    $row = [ordered]@{ trial = $i; mode = $Mode; image = $img; tag_before = $tagNow; tag_after = $tagNext; rc = "$rc"
                       seq_before = $(if ($r -and $r.before) { $r.before.seq } else { $null }); seq_after = $(if ($r -and $r.after) { $r.after.seq } else { $null })
                       uptime_min_before_op = $(if ($r -and $r.dwell) { $r.dwell.up_min } else { $null }); dwell_min = $dw
                       ring_after = $(if ($r -and $r.after) { "count=$($r.after.count) dropped=$($r.after.dropped) invalid=$($r.after.invalid) reinit=$($r.after.ring_reinit)" } else { '' })
                       result = $(if ($r) { $r.result } else { 'no result file' }); stop_reason = $(if ($r) { $r.stop_reason } else { '' }) }
    $ledger += $row
    S ("trial $i " + (($row.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    switch ("$rc") {
        '0' { $expect = ($r.after | ConvertTo-Json -Compress -Depth 4); $tagNow = $tagNext }
        '10' { $stop = "event: $($r.stop_reason) (trial $i)" }
        '11' { $stop = "no-observation: $($r.stop_reason) (trial $i)" }
        default { $stop = "trial $i failed (rc=$rc)" }
    }
}
if (-not $stop) { $stop = 'all-trials-done' }
# 4. restore, always, unless a loop process may still be alive
if (Device-Unsafe) {
    $results['restore'] = 'not-attempted'; $restoreFail = $true
    S "RESTORE NOT ATTEMPTED: a loop process may still be alive ([$($script:alive -join ',')]); no further device operation. The device is NOT restored to the production image (recorded as a failure; no manual step is requested)."
} else {
    $results['restore'] = Run-Child 'flash-prod' $flash (@('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2', $Uf2Prod, '-Md5', $Md5Prod, '-Expect', 'prod') + (MockArg 'flash-prod'))
    $restoreFail = ("$($results['restore'])" -cne '0')
}
$ledger | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $LogDir 'ledger.json') -Encoding UTF8
$csv = @('trial,mode,image,tag_before,tag_after,rc,seq_before,seq_after,uptime_min_before_op,dwell_min,ring_after,result,stop_reason')
foreach ($row in $ledger) { $csv += (($row.GetEnumerator() | ForEach-Object { '"' + ("$($_.Value)" -replace '"', '""') + '"' }) -join ',') }
$csv | Set-Content -Path (Join-Path $LogDir 'ledger.csv') -Encoding UTF8
$okTrials = @($ledger | Where-Object { $_.rc -ceq '0' }).Count
S "ledger: mode=$Mode boots after $(if ($Mode -ceq 'write') { 'a write' } else { 'a soft reset' }) = $($ledger.Count) tried, $okTrials without event; stop=$stop"
$base = 0
if ($stop -clike 'event*') { $base = 10 } elseif ($stop -clike 'no-observation*') { $base = 11 } elseif ($stop -cne 'all-trials-done' -and $stop -cnotlike 'deadline*') { $base = 1 }
S ("restore " + $(if ($restoreFail) { "FAIL (rc=$($results['restore']))" } else { 'PASS' }))
S ("LOOP " + $(switch ($base) { 0 { 'DONE (no event)' } 10 { 'STOPPED ON EVENT' } 11 { 'STOPPED, NO OBSERVATION' } default { 'FAILED' } }) + " | RESTORE " + $(if ($restoreFail) { 'FAIL' } else { 'PASS' }))
S ("results: " + (($results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') + " stop=" + ($stop -replace ' ', '_'))
exit ($base + $(if ($restoreFail) { 2 } else { 0 }))
