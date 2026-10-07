# Boot-instrument calibration, one README step per invocation (evidence/boottest2-20261007/README.md).
#   calib-run.ps1 -Step <pre|0|1|2|3|4|5|6|7|8> -Serial <usb serial> -LogDir <dir>
#                 -Uf2Base <file> -Md5Base <md5> -Uf2Alt <file> -Md5Alt <md5> -Uf2Prod <file> -Md5Prod <md5>
#                 [-Mock <scenario.json>]
# Exit 0 = step PASS, 1 = step FAIL (stopped before the next device operation), 2 = SKIP,
# 3 = usage, 4 = mock scenario file missing/invalid (nothing done).
# Step 3 (pin reset by hand) is not performed: no manual operation is part of this run. It is
# recorded as SKIP, never PASS; retention across a pin reset stays unverified.
# A FAIL stops the calibration; restoring the production image is a separate script
# (calib-flash.ps1 -Expect prod) that calib-all.ps1 runs afterwards whatever the result.
# Every command goes through Send-Cmd (calib-lib.ps1): it is written only after a complete,
# #TRUNC-free dump, and the step fails before the command when that is not so.
param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [string]$Uf2Base = '', [string]$Md5Base = '',
    [string]$Uf2Alt = '', [string]$Md5Alt = '',
    [string]$Uf2Prod = '', [string]$Md5Prod = '',
    [string]$TagBase = 'bt4-R-10080217',
    [string]$TagAlt = 'bt4A-R-10080217',
    [long]$SpinBase = 0x662ea,   # diag_spin_forever, base image (4 bytes: nop; b.n)
    [long]$SpinAlt = 0x38a08,
    [string]$Mock = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:Serial = $Serial
$script:LogFile = Join-Path $LogDir ("step$Step-" + (Get-Date).ToString('MMdd-HHmmss') + '.log')
$script:Scn = $null
if ($Mock) {
    try { Load-Mock $Mock } catch { Log "MOCK ERROR $($_.Exception.Message); nothing done"; exit 4 }
    if ($script:Scn.step_hang_s -gt 0) { Log "MOCK: this step hangs for $($script:Scn.step_hang_s) s (simulated non-returning step)"; Start-Sleep -Seconds $script:Scn.step_hang_s }
}
Log "STEP $Step start serial=$Serial"

function Step-Pre {
    # Everything the run will write to the device, checked before the first device operation, and
    # the console of WHATEVER image is running now: a complete dump is required, ZBOOT lines are
    # not (the production image has no boot instrument; review #9, point 2). Records the current
    # image carries are saved here.
    NextOp 'nothing (preflight only)'
    Require-File 'base image' $Uf2Base $Md5Base
    Require-File 'alt image' $Uf2Alt $Md5Alt
    Require-File 'production image' $Uf2Prod $Md5Prod
    Require 'device on USB as app with a diag port' (Wait-State 'app' 20) ("state=" + $script:lastState)
    $r = Read-Dump 'preflight' -ZbootOptional
    if ($null -eq $r) { Log 'preflight: running image answers without ZBOOT lines (no boot instrument; the base image will be written next)'; return }
    Log 'preflight: running image carries boot-instrument records (saved below)'
    Log ("preflight cur: " + (Raw $r 'cur' 'a'))
    Log ("preflight ring: " + (Raw $r 'ring' 'x'))
    Log ("preflight addr: " + (Raw $r 'addr' 'x'))
    foreach ($k in ($r.Keys | Where-Object { $_ -clike 'inc*' } | Sort-Object)) { foreach ($l in $r[$k]['_lines']) { Log "saved $l" } }
}
function Step-0 {
    NextOp "send 'c' (clear the ring)"
    $r = Read-Dump 'before clear'
    Log ("saved ring before clear: " + (Raw $r 'ring' 'x'))
    foreach ($k in ($r.Keys | Where-Object { $_ -clike 'inc*' } | Sort-Object)) { foreach ($l in $r[$k]['_lines']) { Log "saved $l" } }
    Require 'cur tag=base' ((Need $r 'cur' 'a' 'tag') -ceq $TagBase) (V $r 'cur' 'a' 'tag')
    Require 'addr cur=0x2002c818' ((Need $r 'addr' 'x' 'cur') -ceq '0x2002c818') (Raw $r 'addr' 'x')
    $t = Send-Cmd 'c' 3
    NextOp 'nothing more in step 0'
    Check 'c acknowledged' ($t -cmatch 'ZDIAG ring cleared') 'ZDIAG ring cleared' | Out-Null
    $r3 = Read-Dump 'after clear'
    Check 'ring count=0' ((Need $r3 'ring' 'x' 'count') -ceq '0') (Raw $r3 'ring' 'x') | Out-Null
    Check 'slots=6' ((Need $r3 'ring' 'x' 'slots') -ceq '6') (V $r3 'ring' 'x' 'slots') | Out-Null
    Check 'seq unchanged by c' ((Need $r3 'cur' 'a' 'seq') -ceq (Need $r 'cur' 'a' 'seq')) ((V $r 'cur' 'a' 'seq') + ' -> ' + (V $r3 'cur' 'a' 'seq')) | Out-Null
}
function Step-1 {
    NextOp 'nothing (read only)'
    $r = Read-Dump 'read 1'
    Pause-Ms 5000
    $r2 = Read-Dump 'read 2'
    Check 'cur done=1' ((Need $r2 'cur' 'a' 'done') -ceq '1') (Raw $r2 'cur' 'a') | Out-Null
    Check 'cur running>0' ([int](Need $r2 'cur' 'us2' 'running') -gt 0) (Raw $r2 'cur' 'us2') | Out-Null
    $p1 = (Need $r 'cur' 'b' 'probes') -split '/'; $p2 = (Need $r2 'cur' 'b' 'probes') -split '/'
    Check 'probes_run increases' ([int]$p2[1] -gt [int]$p1[1]) ("$($p1 -join '/') -> $($p2 -join '/')") | Out-Null
    Check 'feeds increases' ([int](Need $r2 'cur' 'b' 'feeds') -gt [int](Need $r 'cur' 'b' 'feeds')) ((V $r 'cur' 'b' 'feeds') + ' -> ' + (V $r2 'cur' 'b' 'feeds')) | Out-Null
    Check 'seq unchanged (no reboot)' ((Need $r2 'cur' 'a' 'seq') -ceq (Need $r 'cur' 'a' 'seq')) ((V $r 'cur' 'a' 'seq') + ' -> ' + (V $r2 'cur' 'a' 'seq')) | Out-Null
    Check 'ring count unchanged' ((Need $r2 'ring' 'x' 'count') -ceq (Need $r 'ring' 'x' 'count')) (Raw $r2 'ring' 'x') | Out-Null
}
# 'h' (step 2) and 'G' (step 5): a stall the net must catch within 15 s, then an automatic reset.
function Step-Stall([string]$cmd, [string]$threadKey) {
    NextOp "send '$cmd'"
    $r0 = Read-Dump "before $cmd"
    $seq0 = [int](Need $r0 'cur' 'a' 'seq'); $count0 = [int](Need $r0 'ring' 'x' 'count')
    Require 'cur done=1 (RUNNING) before the stall' ((Need $r0 'cur' 'a' 'done') -ceq '1') (Raw $r0 'cur' 'a')
    Require 'calib_live=0 before the command' ((Need $r0 'ring' 'x' 'calib_live') -ceq '0') (Raw $r0 'ring' 'x')
    Require 'ring has a free slot' ($count0 -lt [int](Need $r0 'ring' 'x' 'slots')) "count=$count0"
    $t = Send-Cmd $cmd 20
    NextOp "nothing more in step (only reading)"
    Check "$cmd rc=0" ($t -cmatch "ZDIAG calibrate $cmd rc=0") 'rc line' | Out-Null
    Check "$cmd no 'returned' line" ($t -cnotmatch "calibrate $cmd returned") 'returned must not appear' | Out-Null
    $left = Wait-Leave-App 20
    Require 'device back as app within 40 s' (Wait-State 'app' 40) ("state=" + $script:lastState)
    $r = Read-Dump "after $cmd"
    Check-Reset $t $left $seq0 ([int](Need $r 'cur' 'a' 'seq')) 1
    Check 'ring count +1' ([int](Need $r 'ring' 'x' 'count') -eq ($count0 + 1)) (Raw $r 'ring' 'x') | Out-Null
    Check-Incident $r "inc$count0" $TagBase 2 $cmd 1 $SpinBase $threadKey
    Check 'last = the stalled boot (seq)' ((Need $r 'last' 'a' 'seq') -ceq "$seq0") (Raw $r 'last' 'a') | Out-Null
    Check 'last reason=2' ((Need $r 'last' 'a' 'reason') -ceq '2') (V $r 'last' 'a' 'reason') | Out-Null
    Check 'dropped/invalid/reinit unchanged' (((Need $r 'ring' 'x' 'dropped') -ceq (Need $r0 'ring' 'x' 'dropped')) -and ((Need $r 'ring' 'x' 'invalid') -ceq (Need $r0 'ring' 'x' 'invalid')) -and ((Need $r 'ring' 'x' 'reinit') -ceq '0')) (Raw $r 'ring' 'x') | Out-Null
}
function Step-4 {
    NextOp "send 'H'"
    $r0 = Read-Dump 'before H'
    $seq0 = Need $r0 'cur' 'a' 'seq'; $feeds0 = [int](Need $r0 'cur' 'b' 'feeds'); $count0 = Need $r0 'ring' 'x' 'count'
    Require 'calib_live=0 before H' ((Need $r0 'ring' 'x' 'calib_live') -ceq '0') (Raw $r0 'ring' 'x')
    $t = Send-Cmd 'H' 40
    NextOp 'nothing more in step 4 (only reading)'
    Check 'H rc=0' ($t -cmatch 'ZDIAG calibrate H rc=0') 'rc line' | Out-Null
    Check 'H returned (after ~30 s)' ($t -cmatch 'ZDIAG calibrate H returned') 'returned line' | Out-Null
    Check 'no port loss during H' ($t -cnotmatch '\[calib-io\] port lost') 'port lost marker absent' | Out-Null
    Check 'device still app' ((Get-State) -ceq 'app') ("state=" + $script:lastState) | Out-Null
    $r = Read-Dump 'after H'
    Check 'seq unchanged (no reboot)' ((Need $r 'cur' 'a' 'seq') -ceq $seq0) ("$seq0 -> " + (V $r 'cur' 'a' 'seq')) | Out-Null
    Check 'ring count unchanged' ((Need $r 'ring' 'x' 'count') -ceq $count0) (Raw $r 'ring' 'x') | Out-Null
    Check 'calib_live=0' ((Need $r 'ring' 'x' 'calib_live') -ceq '0') (V $r 'ring' 'x' 'calib_live') | Out-Null
    $d = [int](Need $r 'cur' 'b' 'feeds') - $feeds0
    Check 'feeds increased by ~15 (>=12)' ($d -ge 12) "delta=$d" | Out-Null
    Check 'cur calib=H' ((Need $r 'cur' 'a' 'calib') -ceq 'H') (V $r 'cur' 'a' 'calib') | Out-Null
}
function Step-6 {
    NextOp "send 'S'"
    $r0 = Read-Dump 'before S+r'
    $seq0 = [int](Need $r0 'cur' 'a' 'seq'); $count0 = [int](Need $r0 'ring' 'x' 'count')
    Require 'ring has a free slot' ($count0 -lt [int](Need $r0 'ring' 'x' 'slots')) "count=$count0"
    Require 'calib_live=0 before S' ((Need $r0 'ring' 'x' 'calib_live') -ceq '0') (Raw $r0 'ring' 'x')
    $t = Send-Cmd 'S' 3
    NextOp "send 'r'"
    Require 'S rc=0' ($t -cmatch 'ZDIAG calibrate S rc=0') 'rc line'
    Require 'S returned' ($t -cmatch 'ZDIAG calibrate S returned') 'returned line'
    $t2 = Send-Cmd 'r' 2
    NextOp 'nothing more in step 6 (only reading)'
    Check 'r acknowledged' ($t2 -cmatch 'ZDIAG reboot') 'ZDIAG reboot' | Out-Null
    $left = Wait-Leave-App 10
    # the armed boot stalls before USB init (APPLICATION 50); the net fires at 20 s; then a normal boot
    Require 'device back as app within 60 s' (Wait-State 'app' 60) ("state=" + $script:lastState)
    $r = Read-Dump 'after S+r'
    Check-Reset $t2 $left $seq0 ([int](Need $r 'cur' 'a' 'seq')) 2
    Check 'ring count +1' ([int](Need $r 'ring' 'x' 'count') -eq ($count0 + 1)) (Raw $r 'ring' 'x') | Out-Null
    $inc = "inc$count0"
    Check-Incident $r $inc $TagBase 1 'S' 0 $SpinBase ''
    Check "$inc stage=6" ((Need $r $inc 'a' 'stage') -ceq '6') (V $r $inc 'a' 'stage') | Out-Null
    Check "$inc usb=0" ((Need $r $inc 'us2' 'usb') -ceq '0') (Raw $r $inc 'us2') | Out-Null
    Check "$inc seq == seq0+1" ([int](Need $r $inc 'a' 'seq') -eq ($seq0 + 1)) ("inc.seq=" + (V $r $inc 'a' 'seq') + " seq0=$seq0") | Out-Null
}
function Step-7 {
    NextOp "send 'S'"
    $r0 = Read-Dump 'before S+b'
    $seq0 = [int](Need $r0 'cur' 'a' 'seq'); $count0 = [int](Need $r0 'ring' 'x' 'count')
    Require 'ring has a free slot' ($count0 -lt [int](Need $r0 'ring' 'x' 'slots')) "count=$count0"
    Require 'calib_live=0 before S' ((Need $r0 'ring' 'x' 'calib_live') -ceq '0') (Raw $r0 'ring' 'x')
    # every line of every existing incident (Validate-Dump already required all of them to be
    # complete), saved for a whole-record, case-sensitive comparison after the flash
    $before = @{}
    for ($i = 0; $i -lt $count0; $i++) {
        $before["inc$i"] = @($r0["inc$i"]['_lines'])
        foreach ($l in $before["inc$i"]) { Log "saved $l" }
    }
    Log ("before: count=$count0 cur.seq=$seq0 " + (Raw $r0 'ring' 'x'))
    $t = Send-Cmd 'S' 3
    NextOp "send 'b'"
    Require 'S rc=0' ($t -cmatch 'ZDIAG calibrate S rc=0') 'rc line'
    Require 'S returned' ($t -cmatch 'ZDIAG calibrate S returned') 'returned line'
    $t2 = Send-Cmd 'b' 2
    NextOp 'copy the alt image to the UF2 drive'
    Require 'b acknowledged' ($t2 -cmatch 'ZDIAG bootloader') 'ZDIAG bootloader'
    Require 'bootloader of this serial on USB within 30 s' (Wait-State 'boot' 30) ("state=" + $script:lastState)
    Pause-Ms 500
    $drives = @(Get-Uf2DrivesOfSerial)
    Require 'exactly one UF2 drive tied to this serial' ($drives.Count -eq 1) ("drives of serial=[$($drives -join ',')] all uf2 drives=[$((Get-AllUf2Drives) -join ',')]")
    Require 'exactly one bootloader on USB' ((Count-Bootloaders) -eq 1) ("count=" + (Count-Bootloaders))
    Require 'alt image md5 (re-checked at copy time)' ((File-Md5 $Uf2Alt) -ceq $Md5Alt.ToLower()) (File-Md5 $Uf2Alt)
    $ok = Copy-Uf2 $Uf2Alt $drives[0]
    NextOp 'nothing more in step 7 (only reading)'
    Require 'copy raised no error' $ok ("to " + $drives[0])
    Require 'UF2 drive vanished within 30 s (image taken)' (Wait-Uf2Gone $drives[0] 30) ("drive " + $drives[0])
    # the first boot of the alt image stalls at APPLICATION 50 (armed), the net fires at 20 s, then a normal boot
    Require 'device back as app within 90 s' (Wait-State 'app' 90) ("state=" + $script:lastState)
    $r = Read-Dump 'after flash'
    Check 'cur tag=alt' ((Need $r 'cur' 'a' 'tag') -ceq $TagAlt) (V $r 'cur' 'a' 'tag') | Out-Null
    Check 'addr cur=0x2002c818 (alt)' ((Need $r 'addr' 'x' 'cur') -ceq '0x2002c818') (Raw $r 'addr' 'x') | Out-Null
    Check 'boot number advanced by 2 (b-boot + stalled boot)' (([int](Need $r 'cur' 'a' 'seq') - $seq0) -eq 2) ("$seq0 -> " + (V $r 'cur' 'a' 'seq')) | Out-Null
    Check 'ring count +1' ([int](Need $r 'ring' 'x' 'count') -eq ($count0 + 1)) (Raw $r 'ring' 'x') | Out-Null
    for ($i = 0; $i -lt $count0; $i++) {
        $after = @()
        if ($r.ContainsKey("inc$i")) { $after = @($r["inc$i"]['_lines']) }
        $same = ($after.Count -eq $before["inc$i"].Count)
        if ($same) { for ($j = 0; $j -lt $after.Count; $j++) { if ($after[$j] -cne $before["inc$i"][$j]) { $same = $false } } }
        Check "inc$i kept verbatim (every line, case-sensitive)" $same ("lines before=$($before["inc$i"].Count) after=$($after.Count)") | Out-Null
        if (-not $same) { foreach ($l in $after) { Log "after  $l" } }
    }
    $inc = "inc$count0"
    Check-Incident $r $inc $TagAlt 1 'S' 0 $SpinAlt ''
    Check "$inc stage=6" ((Need $r $inc 'a' 'stage') -ceq '6') (V $r $inc 'a' 'stage') | Out-Null
    Check "$inc seq == seq0+1" ([int](Need $r $inc 'a' 'seq') -eq ($seq0 + 1)) ("inc.seq=" + (V $r $inc 'a' 'seq') + " seq0=$seq0") | Out-Null
    Check 'reinit=0' ((Need $r 'ring' 'x' 'reinit') -ceq '0') (V $r 'ring' 'x' 'reinit') | Out-Null
    Check 'dropped unchanged' ((Need $r 'ring' 'x' 'dropped') -ceq (Need $r0 'ring' 'x' 'dropped')) ((V $r0 'ring' 'x' 'dropped') + ' -> ' + (V $r 'ring' 'x' 'dropped')) | Out-Null
    Check 'invalid unchanged' ((Need $r 'ring' 'x' 'invalid') -ceq (Need $r0 'ring' 'x' 'invalid')) ((V $r0 'ring' 'x' 'invalid') + ' -> ' + (V $r 'ring' 'x' 'invalid')) | Out-Null
}
function Step-8 {
    NextOp "send 'c'"
    $r0 = Read-Dump 'before final clear'
    foreach ($k in ($r0.Keys | Where-Object { $_ -clike 'inc*' } | Sort-Object)) { foreach ($l in $r0[$k]['_lines']) { Log "saved $l" } }
    $t = Send-Cmd 'c' 3
    NextOp 'nothing more in step 8 (restore is calib-flash.ps1 -Expect prod)'
    Check 'c acknowledged' ($t -cmatch 'ZDIAG ring cleared') 'ZDIAG ring cleared' | Out-Null
    $r = Read-Dump 'after final clear'
    Check 'ring count=0' ((Need $r 'ring' 'x' 'count') -ceq '0') (Raw $r 'ring' 'x') | Out-Null
}

$code = 1
try {
    switch ($Step) {
        'pre' { Step-Pre }
        '0' { Step-0 }
        '1' { Step-1 }
        '2' { Step-Stall 'h' 'sysq' }
        '3' { Log 'SKIP step 3 (pin reset by hand): no manual operation in this run; retention across a pin reset stays unverified'; $code = 2 }
        '4' { Step-4 }
        '5' { Step-Stall 'G' 'calib' }
        '6' { Step-6 }
        '7' { Step-7 }
        '8' { Step-8 }
        default { Log "usage: unknown step $Step"; $code = 3 }
    }
    if ($code -eq 1) { if ($script:fails -eq 0) { $code = 0 } }
} catch {
    if ($_.Exception.Message -cne 'CALIB-ABORT') { Log "ERROR $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)" ; $script:fails++ }
    Log "STOPPED before: $script:nextOp"
    $code = 1
}
switch ($code) {
    0 { Log "STEP $Step RESULT PASS" }
    1 { Log "STEP $Step RESULT FAIL ($($script:fails) failed checks)" }
    2 { Log "STEP $Step RESULT SKIP" }
}
exit $code
