# The whole calibration without any manual operation: preflight, write the base test image,
# steps 0,1,2,(3 SKIP),4,5,6,7,8, then ALWAYS the production restore, then a summary.
# Calibration stops at the first FAIL (the failing step already saved everything and did not
# perform its next device operation). The restore runs afterwards whatever the calibration result,
# with its own checks, and is reported separately.
# Every child (step, flash, restore) runs under a deadline (table below); a child that does not
# return is killed with its process tree, counted as a failure ('TIMEOUT'), and the run goes on to
# the restore (review #9, point 5) ONLY when the termination was confirmed (taskkill returned 0 and
# no pid of the tree is left within 5 s). An unconfirmed termination ('TIMEOUT-ALIVE'), or a step
# that reports its own console child alive (exit 5), means a calibration process may still write
# to the port or copy a file: the restore is then NOT attempted, nothing else is done, and the run
# ends as a failure that says the device was not restored (review #10, point 3). No manual step
# is requested. The children's stdout/stderr are saved as they are written.
# Exit codes: 0 both PASS, 1 calibration FAIL and restore PASS, 2 restore FAIL (calibration PASS),
# 3 both FAIL (also: restore not attempted), 4 mock scenario files missing/invalid (nothing launched).
# -MockDir: simulation only. Mock mode is fixed for the whole run: every step's scenario file
# (pre, flash-base, 0,1,2,4,5,6,7,8, flash-prod; step 3 has no I/O) must exist and parse BEFORE
# anything is launched, otherwise exit 4 (review #9, point 1). A scenario file may carry
# step_timeout_s to shorten that step's deadline for a hang test, and kill_mode ('fail'/'linger')
# to simulate a termination request that fails or has no effect.
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [Parameter(Mandatory = $true)][string]$Uf2Base, [Parameter(Mandatory = $true)][string]$Md5Base,
    [Parameter(Mandatory = $true)][string]$Uf2Alt, [Parameter(Mandatory = $true)][string]$Md5Alt,
    [Parameter(Mandatory = $true)][string]$Uf2Prod, [Parameter(Mandatory = $true)][string]$Md5Prod,
    [string]$MockDir = ''
)
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:LogFile = Join-Path $LogDir 'summary.log'
function S($m) { Log $m }
# deadlines per child, seconds (each child's own waits add up to well below these)
$deadline = @{ 'pre' = 90; 'flash-base' = 300; '0' = 90; '1' = 90; '2' = 240; '3' = 30; '4' = 150; '5' = 240; '6' = 240; '7' = 400; '8' = 90; 'flash-prod' = 300 }
$steps = @('0', '1', '2', '3', '4', '5', '6', '7', '8')
$run = Join-Path $PSScriptRoot 'calib-run.ps1'
$flash = Join-Path $PSScriptRoot 'calib-flash.ps1'
$common = @('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2Base', $Uf2Base, '-Md5Base', $Md5Base, '-Uf2Alt', $Uf2Alt, '-Md5Alt', $Md5Alt, '-Uf2Prod', $Uf2Prod, '-Md5Prod', $Md5Prod)
$results = [ordered]@{}
$calibFail = $false

# mock: all-or-nothing, validated before any launch
$mockFiles = @{}
$killModes = @{}
if ($MockDir) {
    $missing = @()
    foreach ($name in @('pre', 'flash-base') + ($steps | Where-Object { $_ -cne '3' }) + @('flash-prod')) {
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
    if ($missing.Count -gt 0) {
        S ("MOCK FILE MISSING/INVALID: " + ($missing -join '; ') + " -> nothing launched (mock mode is all-or-nothing)")
        S "CALIBRATION NOT RUN | RESTORE NOT RUN"
        exit 4
    }
    S "MOCK mode: every child gets its scenario file from $MockDir"
}
function MockArg([string]$name) { if ($MockDir) { return @('-Mock', $mockFiles[$name]) }; return @() }

# Runs one child under its deadline; returns the exit code, 'TIMEOUT' (killed, termination
# confirmed) or 'TIMEOUT-ALIVE' (termination NOT confirmed: pids of its tree still alive).
$script:alive = @()
function Run-Child([string]$name, [string]$file, [string[]]$argv) {
    $out = Join-Path $LogDir "child-$name.out"; $err = Join-Path $LogDir "child-$name.err"
    $t = $deadline[$name]
    S "launch $name (deadline ${t}s)"
    $km = ''; if ($killModes.ContainsKey($name)) { $km = $killModes[$name] }
    $res = Invoke-Child $file $argv $t $out $err $km
    if ($res.timedOut) {
        if ($res.killed) { S "$name did not return within ${t}s: killed with its process tree, termination confirmed (its log and $out hold what it wrote)"; return 'TIMEOUT' }
        S "$name did not return within ${t}s: termination NOT confirmed (pids still alive: [$($res.alive -join ',')]); a calibration process may still operate the device"
        $script:alive += $res.alive
        return 'TIMEOUT-ALIVE'
    }
    if ("$($res.rc)" -ceq '5') { S "$name reports a console child it could not confirm dead (exit 5); a calibration process may still operate the device"; $script:alive += "child-of-$name" }
    return $res.rc
}
function Device-Unsafe() { return ($script:alive.Count -gt 0) }

S "CALIBRATION start serial=$Serial"
# preflight (no device write) and the base image write
$results['pre'] = Run-Child 'pre' $run (@('-Step', 'pre') + $common + (MockArg 'pre'))
S "pre rc=$($results['pre'])"
if ($results['pre'] -ne 0) { $calibFail = $true }
if (-not $calibFail) {
    $results['flash-base'] = Run-Child 'flash-base' $flash (@('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2', $Uf2Base, '-Md5', $Md5Base, '-Expect', 'base') + (MockArg 'flash-base'))
    S "flash-base rc=$($results['flash-base'])"
    if ($results['flash-base'] -ne 0) { $calibFail = $true }
}
foreach ($step in $steps) {
    if ($calibFail) { $results[$step] = 'not-run'; S "step $step not run (calibration stopped)"; continue }
    $rc = Run-Child $step $run (@('-Step', $step) + $common + (MockArg $step))
    $results[$step] = $rc
    $label = switch ("$rc") { '0' { 'PASS' } '1' { 'FAIL' } '2' { 'SKIP' } '5' { 'FAIL (console child may be alive)' } default { "rc=$rc" } }
    S "step $step $label"
    if ("$rc" -cne '0' -and "$rc" -cne '2') { $calibFail = $true }
}
# production restore: always, separately judged, under its own deadline, UNLESS a calibration
# process could not be confirmed dead (it could still send a command or copy a file and race the
# restore): then no further device operation at all, and the failure says so.
if (Device-Unsafe) {
    $results['restore'] = 'not-attempted'
    $restoreFail = $true
    S "RESTORE NOT ATTEMPTED: a calibration process may still be alive ([$($script:alive -join ',')]); no further device operation. The device is NOT restored to the production image (recorded as a failure; no manual step is requested)."
} else {
    $results['restore'] = Run-Child 'flash-prod' $flash (@('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2', $Uf2Prod, '-Md5', $Md5Prod, '-Expect', 'prod') + (MockArg 'flash-prod'))
    $restoreFail = ("$($results['restore'])" -cne '0')
    if ("$($results['restore'])" -ceq 'TIMEOUT-ALIVE' -or "$($results['restore'])" -ceq '5') { S "restore process not confirmed dead: the device state is unknown and no further device operation is done" }
}
S ("restore " + $(if ($restoreFail) { "FAIL (rc=$($results['restore']))" } else { 'PASS' }))
S ("CALIBRATION " + $(if ($calibFail) { 'FAIL' } else { 'PASS (step 3 SKIP: pin reset not tested)' }) + " | RESTORE " + $(if ($restoreFail) { 'FAIL' } else { 'PASS' }))
S ("results: " + (($results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
$code = 0
if ($calibFail) { $code += 1 }
if ($restoreFail) { $code += 2 }
exit $code
