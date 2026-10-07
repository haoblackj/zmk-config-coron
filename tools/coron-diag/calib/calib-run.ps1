# Boot-instrument calibration driver (evidence/README.md, steps 0..8), one step per invocation so
# the pace is controlled from outside and every step's raw console text is saved.
#   calib-run.ps1 -Step N -Serial <usb serial> -LogDir <dir> [-Uf2Alt <file>] [-Uf2Prod <file>]
# Reads the device tree only (Get-PnpDevice); never enumerates Win32_SerialPort. Never touches a
# device whose USB serial is not -Serial. Writes to the device only through the diag console
# characters the step needs (c/h/H/G/S/r/b) and, in steps 7 and 8, one UF2 copy to the UF2 drive
# that belongs to that serial.
# Every expectation is printed as PASS/FAIL with the actual value; the step's verdict is the AND.
param(
    [Parameter(Mandatory = $true)][int]$Step,
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [string]$Uf2Alt = '',
    [string]$Uf2Prod = '',
    [string]$TagBase = 'bt4-R-10080217',
    [string]$TagAlt = 'bt4A-R-10080217',
    [int]$SpinBase = 0x662ea,   # diag_spin_forever, base image (4 bytes: nop; b.n)
    [int]$SpinAlt = 0x38a08
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$ts = (Get-Date).ToString('MMdd-HHmmss')
$LogFile = Join-Path $LogDir ("step$Step-$ts.log")
$script:fails = 0

function Log($m) {
    $line = (Get-Date).ToString('HH:mm:ss.fff') + " $m"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}
function Check([string]$name, [bool]$ok, [string]$actual) {
    if ($ok) { Log "PASS $name ($actual)" } else { Log "FAIL $name ($actual)"; $script:fails++ }
}
function Get-Devices { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue }
function Get-State($devs) {
    if ($devs | Where-Object { $_.InstanceId -match "^USB\\VID_(239A|2886)&PID_[0-9A-F]{4}\\$Serial$" }) { return 'boot' }
    if ($devs | Where-Object { $_.InstanceId -match "^USB\\VID_1D50&PID_615E\\$Serial$" }) { return 'app' }
    return 'none'
}
function Get-DiagPorts {
    Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^USB\\VID_1D50&PID_615E&MI_' } |
        Where-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data -match "\\$Serial$" } |
        ForEach-Object { if ($_.FriendlyName -match '\((COM\d+)\)') { $Matches[1] } }
}
function Find-Uf2Drive {
    foreach ($d in Get-PSDrive -PSProvider FileSystem) {
        if (Test-Path (Join-Path ($d.Name + ':\') 'INFO_UF2.TXT')) { return $d.Name }
    }
    return $null
}
# Returns the raw console text (dump + replies), and appends it to the step log verbatim.
function Exchange([string]$Send = '', [int]$ReadSeconds = 0) {
    $helper = Join-Path $PSScriptRoot 'calib-io.ps1'
    foreach ($com in (Get-DiagPorts)) {
        $psa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-Com', $com, '-ReadSeconds', $ReadSeconds)
        if ($Send) { $psa += @('-Send', $Send) }
        $text = (& powershell.exe @psa 2>$null) -join "`n"
        if ($text -match 'ZDIAG begin') {
            Add-Content -Path $LogFile -Value ("----- console $com send='$Send' read=${ReadSeconds}s -----") -Encoding UTF8
            Add-Content -Path $LogFile -Value $text -Encoding UTF8
            Add-Content -Path $LogFile -Value '----- end console -----' -Encoding UTF8
            return $text
        }
    }
    return $null
}
function Wait-State([string]$want, [int]$seconds) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $seconds) {
        $s = Get-State (Get-Devices)
        if ($s -eq $want -and ($want -ne 'app' -or (Get-DiagPorts))) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}
function Read-Dump() {
    Start-Sleep -Milliseconds 700
    $t = Exchange
    if (-not $t) { Start-Sleep -Milliseconds 1500; $t = Exchange }
    return $t
}
# Parse "ZBOOT <rec> <line> k=v k=v ..." into a nested hashtable: $r[rec][line][key] = value.
function Parse-Zboot([string]$text) {
    $r = @{}
    foreach ($l in ($text -split "`n")) {
        $l = $l.TrimEnd("`r")
        if ($l -notmatch '^ZBOOT (\S+) (\S+) (.*)$') { continue }
        $rec = $Matches[1]; $line = $Matches[2]; $rest = $Matches[3]
        if ($rec -eq 'ring' -or $rec -eq 'addr') { $rest = "$line $rest"; $line = 'x' }
        if (-not $r.ContainsKey($rec)) { $r[$rec] = @{} }
        $h = @{}
        foreach ($kv in ($rest -split ' ')) { if ($kv -match '^([a-z0-9_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
        $h['_raw'] = $l
        $r[$rec][$line] = $h
    }
    return $r
}
function V($r, $rec, $line, $key) {
    if ($r.ContainsKey($rec) -and $r[$rec].ContainsKey($line) -and $r[$rec][$line].ContainsKey($key)) { return $r[$rec][$line][$key] }
    return $null
}
function Hex($s) { if ($s -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }; return -1 }
function Check-Trunc([string]$text) {
    $n = @($text -split "`n" | Where-Object { $_ -match '#TRUNC' }).Count
    Check 'no #TRUNC line' ($n -eq 0) "trunc lines=$n"
}
# Common incident checks. $spin is the spin address of the image that fired.
function Check-Incident($r, [string]$inc, [string]$tag, [int]$reason, [string]$calib, [int]$done, [long]$spin, [string]$threadKey) {
    Check "$inc present" ($r.ContainsKey($inc)) "keys=$(($r.Keys | Sort-Object) -join ',')"
    if (-not $r.ContainsKey($inc)) { return }
    Check "$inc tag" ((V $r $inc 'a' 'tag') -eq $tag) (V $r $inc 'a' 'tag')
    Check "$inc reason=$reason" ((V $r $inc 'a' 'reason') -eq "$reason") (V $r $inc 'a' 'reason')
    Check "$inc calib=$calib" ((V $r $inc 'a' 'calib') -eq $calib) (V $r $inc 'a' 'calib')
    Check "$inc done=$done" ((V $r $inc 'a' 'done') -eq "$done") (V $r $inc 'a' 'done')
    $pc = Hex (V $r $inc 'fire1' 'pc')
    Check "$inc pc in diag_spin_forever" ($pc -ge $spin -and $pc -lt ($spin + 4)) ("pc=" + (V $r $inc 'fire1' 'pc') + " spin=0x" + $spin.ToString('x'))
    Check "$inc handler=0" ((V $r $inc 'fire2' 'handler') -eq '0') (V $r $inc 'fire2' 'handler')
    if ($threadKey) {
        $want = V $r 'addr' 'x' $threadKey
        Check "$inc thread == addr.$threadKey" ((V $r $inc 'fire2' 'thread') -eq $want) ("thread=" + (V $r $inc 'fire2' 'thread') + " $threadKey=$want")
    }
}

Log "STEP $Step start serial=$Serial log=$LogFile"
if (-not (Wait-State 'app' 20)) { Log "FAIL device not on USB as app (state=$(Get-State (Get-Devices)))"; exit 2 }

switch ($Step) {
    0 {
        $t = Read-Dump; if (-not $t) { Log 'FAIL no dump'; exit 2 }
        $r = Parse-Zboot $t; Check-Trunc $t
        Log ("before clear: " + (V $r 'ring' 'x' '_raw'))
        Log ("addr: " + (V $r 'addr' 'x' '_raw'))
        $t2 = Exchange 'c' 3; Check 'c acknowledged' ($t2 -match 'ZDIAG ring cleared') 'ZDIAG ring cleared'
        $t3 = Read-Dump; $r3 = Parse-Zboot $t3; Check-Trunc $t3
        Check 'ring count=0' ((V $r3 'ring' 'x' 'count') -eq '0') (V $r3 'ring' 'x' '_raw')
        Check 'slots=6' ((V $r3 'ring' 'x' 'slots') -eq '6') (V $r3 'ring' 'x' 'slots')
        Check 'cur tag=base' ((V $r3 'cur' 'a' 'tag') -eq $TagBase) (V $r3 'cur' 'a' 'tag')
        Check 'addr cur=0x2002c818' ((V $r3 'addr' 'x' 'cur') -eq '0x2002c818') (V $r3 'addr' 'x' 'cur')
    }
    1 {
        $t = Read-Dump; $r = Parse-Zboot $t; Check-Trunc $t
        Start-Sleep -Seconds 5
        $t2 = Read-Dump; $r2 = Parse-Zboot $t2; Check-Trunc $t2
        Check 'cur done=1' ((V $r2 'cur' 'a' 'done') -eq '1') (V $r2 'cur' 'a' '_raw')
        Check 'cur running>0' ([int](V $r2 'cur' 'us2' 'running') -gt 0) (V $r2 'cur' 'us2' '_raw')
        Check 'probes_run increases' ([int]((V $r2 'cur' 'b' 'probes') -split '/')[1] -gt [int]((V $r 'cur' 'b' 'probes') -split '/')[1]) ((V $r 'cur' 'b' 'probes') + ' -> ' + (V $r2 'cur' 'b' 'probes'))
        Check 'feeds increases' ([int](V $r2 'cur' 'b' 'feeds') -gt [int](V $r 'cur' 'b' 'feeds')) ((V $r 'cur' 'b' 'feeds') + ' -> ' + (V $r2 'cur' 'b' 'feeds'))
        Check 'ring count unchanged' ((V $r2 'ring' 'x' 'count') -eq (V $r 'ring' 'x' 'count')) (V $r2 'ring' 'x' '_raw')
        Log ("cur: " + (V $r2 'cur' 'a' '_raw'))
    }
    2 {
        $t0 = Read-Dump; $r0 = Parse-Zboot $t0; $seq0 = V $r0 'cur' 'a' 'seq'; $count0 = [int](V $r0 'ring' 'x' 'count')
        $t = Exchange 'h' 20
        Check 'h rc=0' ($t -match 'ZDIAG calibrate h rc=0') 'rc line'
        Check 'h no returned line' ($t -notmatch 'calibrate h returned') 'returned must not appear'
        $gone = -not (Wait-State 'app' 0); Start-Sleep -Seconds 1
        $t2 = Get-Date; while ((Get-State (Get-Devices)) -eq 'app' -and ((Get-Date) - $t2).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
        Check 'device reset within 20 s' ((Get-State (Get-Devices)) -ne 'app') ("state=" + (Get-State (Get-Devices)))
        Check 'device back as app within 40 s' (Wait-State 'app' 40) ("state=" + (Get-State (Get-Devices)))
        $t3 = Read-Dump; $r = Parse-Zboot $t3; Check-Trunc $t3
        Check 'ring count +1' ([int](V $r 'ring' 'x' 'count') -eq ($count0 + 1)) (V $r 'ring' 'x' '_raw')
        Check-Incident $r "inc$count0" $TagBase 2 'h' 1 $SpinBase 'sysq'
        Check 'last seq == stalled boot' ((V $r 'last' 'a' 'seq') -eq $seq0) ("last.seq=" + (V $r 'last' 'a' 'seq') + " before=$seq0")
        Check 'cur seq == +1' ([int](V $r 'cur' 'a' 'seq') -eq ([int]$seq0 + 1)) (V $r 'cur' 'a' 'seq')
        Check 'last reason=2' ((V $r 'last' 'a' 'reason') -eq '2') (V $r 'last' 'a' '_raw')
    }
    3 {
        $t0 = Read-Dump; $r0 = Parse-Zboot $t0; $seq0 = V $r0 'cur' 'a' 'seq'; $count0 = V $r0 'ring' 'x' 'count'
        Log "PRESS the reset button of the right half ONCE now (waiting up to 120 s for the USB drop and return)"
        $t1 = Get-Date; while ((Get-State (Get-Devices)) -eq 'app' -and ((Get-Date) - $t1).TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200 }
        Check 'USB dropped (reset seen)' ((Get-State (Get-Devices)) -ne 'app') ("state=" + (Get-State (Get-Devices)))
        Check 'back as app within 40 s' (Wait-State 'app' 40) ("state=" + (Get-State (Get-Devices)))
        $t = Read-Dump; $r = Parse-Zboot $t; Check-Trunc $t
        Check 'ring count unchanged' ((V $r 'ring' 'x' 'count') -eq $count0) (V $r 'ring' 'x' '_raw')
        Check 'last seq == previous cur' ((V $r 'last' 'a' 'seq') -eq $seq0) (V $r 'last' 'a' '_raw')
        Check 'last done=1 reason=0' (((V $r 'last' 'a' 'done') -eq '1') -and ((V $r 'last' 'a' 'reason') -eq '0')) (V $r 'last' 'a' '_raw')
        Check 'cur seq == +1' ([int](V $r 'cur' 'a' 'seq') -eq ([int]$seq0 + 1)) (V $r 'cur' 'a' 'seq')
        Check 'invalid unchanged' ((V $r 'ring' 'x' 'invalid') -eq (V $r0 'ring' 'x' 'invalid')) (V $r 'ring' 'x' 'invalid')
    }
    4 {
        $t0 = Read-Dump; $r0 = Parse-Zboot $t0; $feeds0 = [int](V $r0 'cur' 'b' 'feeds'); $count0 = V $r0 'ring' 'x' 'count'
        $t = Exchange 'H' 40
        Check 'H rc=0' ($t -match 'ZDIAG calibrate H rc=0') 'rc line'
        Check 'H returned (after ~30 s)' ($t -match 'ZDIAG calibrate H returned') 'returned line'
        Check 'device stayed as app' ((Get-State (Get-Devices)) -eq 'app') ("state=" + (Get-State (Get-Devices)))
        $t2 = Read-Dump; $r = Parse-Zboot $t2; Check-Trunc $t2
        Check 'ring count unchanged' ((V $r 'ring' 'x' 'count') -eq $count0) (V $r 'ring' 'x' '_raw')
        Check 'calib_live=0' ((V $r 'ring' 'x' 'calib_live') -eq '0') (V $r 'ring' 'x' 'calib_live')
        $d = [int](V $r 'cur' 'b' 'feeds') - $feeds0
        Check 'feeds increased by ~15 (>=12)' ($d -ge 12) "delta=$d"
        Check 'cur calib=H' ((V $r 'cur' 'a' 'calib') -eq 'H') (V $r 'cur' 'a' 'calib')
    }
    5 {
        $t0 = Read-Dump; $r0 = Parse-Zboot $t0; $seq0 = V $r0 'cur' 'a' 'seq'; $count0 = [int](V $r0 'ring' 'x' 'count')
        Check 'calib_live=0 before G' ((V $r0 'ring' 'x' 'calib_live') -eq '0') (V $r0 'ring' 'x' 'calib_live')
        $t = Exchange 'G' 20
        Check 'G rc=0' ($t -match 'ZDIAG calibrate G rc=0') 'rc line'
        Check 'G no returned line' ($t -notmatch 'calibrate G returned') 'returned must not appear'
        $t2 = Get-Date; while ((Get-State (Get-Devices)) -eq 'app' -and ((Get-Date) - $t2).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
        Check 'device reset within 20 s' ((Get-State (Get-Devices)) -ne 'app') ("state=" + (Get-State (Get-Devices)))
        Check 'device back as app within 40 s' (Wait-State 'app' 40) ("state=" + (Get-State (Get-Devices)))
        $t3 = Read-Dump; $r = Parse-Zboot $t3; Check-Trunc $t3
        Check 'ring count +1' ([int](V $r 'ring' 'x' 'count') -eq ($count0 + 1)) (V $r 'ring' 'x' '_raw')
        Check-Incident $r "inc$count0" $TagBase 2 'G' 1 $SpinBase 'calib'
    }
    6 {
        $t0 = Read-Dump; $r0 = Parse-Zboot $t0; $seq0 = [int](V $r0 'cur' 'a' 'seq'); $count0 = [int](V $r0 'ring' 'x' 'count')
        $t = Exchange 'S' 3
        Check 'S rc=0' ($t -match 'ZDIAG calibrate S rc=0') 'rc line'
        Check 'S returned' ($t -match 'ZDIAG calibrate S returned') 'returned line'
        $t2 = Exchange 'r' 2
        Check 'r acknowledged' ($t2 -match 'ZDIAG reboot') 'ZDIAG reboot'
        $t3 = Get-Date; while ((Get-State (Get-Devices)) -eq 'app' -and ((Get-Date) - $t3).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 }
        Check 'device left app' ((Get-State (Get-Devices)) -ne 'app') ("state=" + (Get-State (Get-Devices)))
        # the armed boot stalls before USB init (APPLICATION 50) and the net fires at 20 s; then a normal boot
        Check 'device back as app within 60 s' (Wait-State 'app' 60) ("state=" + (Get-State (Get-Devices)))
        $t4 = Read-Dump; $r = Parse-Zboot $t4; Check-Trunc $t4
        Check 'ring count +1' ([int](V $r 'ring' 'x' 'count') -eq ($count0 + 1)) (V $r 'ring' 'x' '_raw')
        Check-Incident $r "inc$count0" $TagBase 1 'S' 0 $SpinBase ''
        Check "inc$count0 stage=6" ((V $r "inc$count0" 'a' 'stage') -eq '6') (V $r "inc$count0" 'a' 'stage')
        Check "inc$count0 usb=0" ((V $r "inc$count0" 'us2' 'usb') -eq '0') (V $r "inc$count0" 'us2' '_raw')
        Check "inc$count0 seq == r-boot seq+1" ([int](V $r "inc$count0" 'a' 'seq') -eq ($seq0 + 1)) ("inc.seq=" + (V $r "inc$count0" 'a' 'seq') + " before=$seq0")
        Check 'cur seq == +2' ([int](V $r 'cur' 'a' 'seq') -eq ($seq0 + 2)) (V $r 'cur' 'a' 'seq')
    }
    7 {
        if (-not $Uf2Alt -or -not (Test-Path $Uf2Alt)) { Log 'FAIL -Uf2Alt missing'; exit 2 }
        $t0 = Read-Dump; $r0 = Parse-Zboot $t0; $seq0 = [int](V $r0 'cur' 'a' 'seq'); $count0 = [int](V $r0 'ring' 'x' 'count')
        $tags0 = @(); for ($i = 0; $i -lt $count0; $i++) { $tags0 += (V $r0 "inc$i" 'a' 'tag') }
        Log "before: count=$count0 tags=$($tags0 -join ',') cur.seq=$seq0 invalid=$(V $r0 'ring' 'x' 'invalid') dropped=$(V $r0 'ring' 'x' 'dropped')"
        $t = Exchange 'S' 3
        Check 'S rc=0' ($t -match 'ZDIAG calibrate S rc=0') 'rc line'
        $t2 = Exchange 'b' 2
        Check 'b acknowledged' ($t2 -match 'ZDIAG bootloader') 'ZDIAG bootloader'
        $t3 = Get-Date; $drive = $null
        while (((Get-Date) - $t3).TotalSeconds -lt 30) {
            $drive = Find-Uf2Drive
            if ($drive -and (Get-State (Get-Devices)) -eq 'boot') { break }
            $drive = $null; Start-Sleep -Milliseconds 300
        }
        Check 'UF2 drive of this serial' ($null -ne $drive) "drive=$drive state=$(Get-State (Get-Devices))"
        if (-not $drive) { exit 2 }
        $bl = @((Get-Devices) | Where-Object { $_.InstanceId -match '^USB\\VID_(239A|2886)&PID_[0-9A-F]{4}\\[0-9A-F]+$' })
        Check 'exactly one bootloader on USB' ($bl.Count -eq 1) "count=$($bl.Count)"
        if ($bl.Count -ne 1) { exit 2 }
        Start-Sleep -Milliseconds 500
        Copy-Item -Path $Uf2Alt -Destination (Join-Path ($drive + ':\') 'firmware.uf2') -Force -ErrorAction SilentlyContinue
        Log ("copied " + (Split-Path $Uf2Alt -Leaf) + " to ${drive}:")
        # first boot of the alt image stalls at APPLICATION 50 (armed), net fires at 20 s, then a normal boot
        Check 'device back as app within 90 s' (Wait-State 'app' 90) ("state=" + (Get-State (Get-Devices)))
        $t4 = Read-Dump; $r = Parse-Zboot $t4; Check-Trunc $t4
        Check 'cur tag=alt' ((V $r 'cur' 'a' 'tag') -eq $TagAlt) (V $r 'cur' 'a' 'tag')
        Check 'addr cur=0x2002c818 (alt)' ((V $r 'addr' 'x' 'cur') -eq '0x2002c818') (V $r 'addr' 'x' 'cur')
        Check 'ring count +1' ([int](V $r 'ring' 'x' 'count') -eq ($count0 + 1)) (V $r 'ring' 'x' '_raw')
        for ($i = 0; $i -lt $count0; $i++) { Check "inc$i kept (tag)" ((V $r "inc$i" 'a' 'tag') -eq $tags0[$i]) ("tag=" + (V $r "inc$i" 'a' 'tag') + " was " + $tags0[$i]) }
        Check-Incident $r "inc$count0" $TagAlt 1 'S' 0 $SpinAlt ''
        Check "inc$count0 stage=6" ((V $r "inc$count0" 'a' 'stage') -eq '6') (V $r "inc$count0" 'a' 'stage')
        Check "inc$count0 seq == before+1" ([int](V $r "inc$count0" 'a' 'seq') -eq ($seq0 + 1)) ("inc.seq=" + (V $r "inc$count0" 'a' 'seq') + " before=$seq0")
        Check 'reinit=0' ((V $r 'ring' 'x' 'reinit') -eq '0') (V $r 'ring' 'x' 'reinit')
        Check 'dropped=0' ((V $r 'ring' 'x' 'dropped') -eq '0') (V $r 'ring' 'x' 'dropped')
        Check 'invalid unchanged' ((V $r 'ring' 'x' 'invalid') -eq (V $r0 'ring' 'x' 'invalid')) ((V $r0 'ring' 'x' 'invalid') + ' -> ' + (V $r 'ring' 'x' 'invalid'))
    }
    8 {
        $t = Exchange 'c' 3; Check 'c acknowledged' ($t -match 'ZDIAG ring cleared') 'ZDIAG ring cleared'
        $t2 = Read-Dump; $r = Parse-Zboot $t2; Check-Trunc $t2
        Check 'ring count=0' ((V $r 'ring' 'x' 'count') -eq '0') (V $r 'ring' 'x' '_raw')
        if ($Uf2Prod -and (Test-Path $Uf2Prod)) {
            $t3 = Exchange 'b' 2
            Check 'b acknowledged' ($t3 -match 'ZDIAG bootloader') 'ZDIAG bootloader'
            $t4 = Get-Date; $drive = $null
            while (((Get-Date) - $t4).TotalSeconds -lt 30) { $drive = Find-Uf2Drive; if ($drive -and (Get-State (Get-Devices)) -eq 'boot') { break }; $drive = $null; Start-Sleep -Milliseconds 300 }
            Check 'UF2 drive' ($null -ne $drive) "drive=$drive"
            if ($drive) {
                Start-Sleep -Milliseconds 500
                Copy-Item -Path $Uf2Prod -Destination (Join-Path ($drive + ':\') 'firmware.uf2') -Force -ErrorAction SilentlyContinue
                Log ("copied " + (Split-Path $Uf2Prod -Leaf) + " to ${drive}:")
                Check 'production image back as app within 60 s' (Wait-State 'app' 60) ("state=" + (Get-State (Get-Devices)))
                $t5 = Read-Dump; if ($t5) { Log ("prod dump: " + (($t5 -split "`n") | Where-Object { $_ -match 'ZDIAG begin' } | Select-Object -First 1)) }
            }
        } else { Log 'no -Uf2Prod: leaving the test image on the device' }
    }
    default { Log "unknown step $Step"; exit 2 }
}
if ($script:fails -eq 0) { Log "STEP $Step RESULT PASS"; exit 0 } else { Log "STEP $Step RESULT FAIL ($($script:fails) checks)"; exit 1 }
