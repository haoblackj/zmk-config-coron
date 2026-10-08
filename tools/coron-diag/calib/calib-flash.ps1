# Write one UF2 to the half identified by -Serial and verify what came back.
#   calib-flash.ps1 -Serial <usb serial> -LogDir <dir> -Uf2 <file> -Md5 <md5> -Expect <base|prod> [-Mock <json>]
# -Expect base: the test image must answer with a complete, structurally valid dump (every record
#               with every line), cur tag -TagBase, addr cur=0x2002c818, done=1.
# -Expect prod: the production image (2725423) must answer with 'ZDIAG begin version=prof1' and NO
#               ZBOOT line (the production build has no CONFIG_CORON_DIAG_BOOT). That is the whole
#               identification the console offers; the copied file's md5 is verified before the copy.
# 'b' is written only after a complete, #TRUNC-free dump (Send-Cmd); the image currently running
# may be any image with the diag console (the production image included).
# Exit 0 = PASS, 1 = FAIL (stopped before the next device operation, everything saved),
# 4 = mock scenario file missing/invalid (nothing done), 5 = FAIL and a timed-out console child could
# not be confirmed dead.
# This script is also the production restore: calib-all.ps1 runs it last whatever happened before.
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [Parameter(Mandatory = $true)][string]$Uf2,
    [Parameter(Mandatory = $true)][string]$Md5,
    [Parameter(Mandatory = $true)][ValidateSet('base', 'prod')][string]$Expect,
    [string]$TagBase = 'bt4-R-10080217',
    [string]$Mock = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:Serial = $Serial
$script:LogFile = Join-Path $LogDir ("flash-$Expect-" + (Get-Date).ToString('MMdd-HHmmss') + '.log')
$script:Scn = $null
if ($Mock) {
    try { Load-Mock $Mock } catch { Log "MOCK ERROR $($_.Exception.Message); nothing done"; exit 4 }
    if ($script:Scn.step_hang_s -gt 0) { Log "MOCK: this script hangs for $($script:Scn.step_hang_s) s (simulated non-returning restore)"; Start-Sleep -Seconds $script:Scn.step_hang_s }
}
Log "FLASH $Expect start serial=$Serial file=$Uf2"
$code = 1
try {
    NextOp 'nothing (preflight)'
    Require-File "$Expect image" $Uf2 $Md5
    $state = Get-State
    Log "initial state=$state"
    if ($state -ceq 'app') {
        NextOp "send 'b'"
        Require 'diag port present' (@(Get-DiagPorts).Count -gt 0) 'ports'
        $t = Send-Cmd 'b' 2
        NextOp 'copy the image to the UF2 drive'
        # the ack line is evidence only (it can be lost with the port); the gate is the bootloader on USB
        $ev = Ack-Evidence $t 'b' 'ZDIAG bootloader'
        Require 'bootloader of this serial on USB within 30 s' (Wait-State 'boot' 30) ("state=" + $script:lastState)
    } elseif ($state -ceq 'boot') {
        NextOp 'copy the image to the UF2 drive'
        Log 'device already in its bootloader'
    } else {
        Require 'device on USB (app or boot)' $false "state=$state"
    }
    Pause-Ms 500
    $drives = @(Get-Uf2DrivesOfSerial)
    Require 'exactly one UF2 drive tied to this serial' ($drives.Count -eq 1) ("drives of serial=[$($drives -join ',')] all uf2 drives=[$((Get-AllUf2Drives) -join ',')]")
    Require 'exactly one bootloader on USB' ((Count-Bootloaders) -eq 1) ("count=" + (Count-Bootloaders))
    Require 'image md5 (re-checked at copy time)' ((File-Md5 $Uf2) -ceq $Md5.ToLower()) (File-Md5 $Uf2)
    $ok = Copy-Uf2 $Uf2 $drives[0]
    NextOp 'nothing more (only reading)'
    Require 'copy raised no error' $ok ("to " + $drives[0])
    Require 'UF2 drive vanished within 30 s (image taken)' (Wait-Uf2Gone $drives[0] 30) ("drive " + $drives[0])
    Require 'device back as app within 90 s' (Wait-State 'app' 90) ("state=" + $script:lastState)
    Pause-Ms 700
    $t2 = Exchange
    if (-not $t2) { Pause-Ms 1500; $t2 = Exchange }
    Require 'dump present' ($null -ne $t2) 'ZDIAG begin'
    $zb = @($t2 -split "`n" | Where-Object { $_ -cmatch '^ZBOOT ' }).Count
    $begin = ($t2 -split "`n" | Where-Object { $_ -cmatch '^ZDIAG begin' } | Select-Object -First 1)
    Log "dump: $begin ; ZBOOT lines=$zb"
    if ($Expect -ceq 'base') {
        $r = Validate-Dump $t2 'after flash' $true
        Check 'cur tag=base' ((Need $r 'cur' 'a' 'tag') -ceq $TagBase) (V $r 'cur' 'a' 'tag') | Out-Null
        Check 'addr cur=0x2002c818' ((Need $r 'addr' 'x' 'cur') -ceq '0x2002c818') (Raw $r 'addr' 'x') | Out-Null
        Check 'first boot after the write reached RUNNING (done=1)' ((Need $r 'cur' 'a' 'done') -ceq '1') (Raw $r 'cur' 'a') | Out-Null
        Log ("after flash ring: " + (Raw $r 'ring' 'x'))
    } else {
        # complete and #TRUNC-free like every other dump; ZBOOT lines are not required (a $null table
        # is the expected answer of the production image) but are validated when present
        $r = Validate-Dump $t2 'after flash' $false
        Check 'production image answers (version=prof1)' ($t2 -cmatch '(?m)^ZDIAG begin version=prof1') "$begin" | Out-Null
        Check 'no ZBOOT line (not a test image)' ($zb -eq 0 -and $null -eq $r) "zboot=$zb" | Out-Null
    }
    if ($script:fails -eq 0) { $code = 0 }
} catch {
    if ($_.Exception.Message -cne 'CALIB-ABORT') { Log "ERROR $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"; $script:fails++ }
    Log "STOPPED before: $script:nextOp"
    $code = 1
    if ($script:childAlive) { Log "a console child may still be alive (termination not confirmed): exit 5, the caller must not start any device operation"; $code = 5 }
}
if ($code -eq 0) { Log "FLASH $Expect RESULT PASS" } elseif ($code -eq 5) { Log "FLASH $Expect RESULT FAIL ($($script:fails) failed checks; a console child may still be alive)" } else { Log "FLASH $Expect RESULT FAIL ($($script:fails) failed checks)" }
exit $code
