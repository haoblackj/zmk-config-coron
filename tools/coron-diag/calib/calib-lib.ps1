# Shared functions for the boot-instrument calibration scripts (dot-sourced).
# Real mode talks to Windows (Get-PnpDevice, CIM disk chain, a child calib-io.ps1 per serial
# exchange). Mock mode ($script:Scn, a scenario loaded from JSON) replays canned device states,
# console texts, UF2 drives and copy results, so every decision path can be exercised without a
# device. Reads the device tree only (Get-PnpDevice / CIM disk classes); never Win32_SerialPort.
#
# Contract for callers:
#   Log/Check/Require/Abort write to $script:LogFile. Check records PASS/FAIL and continues;
#   Require is Check + Abort on failure, used for every precondition of a device write, so a
#   failed precondition stops before the write. Abort throws 'CALIB-ABORT'; the step runner
#   catches it, logs "STOPPED before <next operation>", saves everything and exits 1.
#   Every console exchange is saved verbatim (stdout, stderr, exit code) whether or not it looks
#   like a dump. Missing values are never defaulted: Need() aborts when a field is absent.

$script:fails = 0
$script:nextOp = 'start'

function Log($m) {
    $line = (Get-Date).ToString('HH:mm:ss.fff') + " $m"
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    Write-Host $line
}
function Check([string]$name, [bool]$ok, [string]$actual) {
    if ($ok) { Log "PASS $name ($actual)" } else { Log "FAIL $name ($actual)"; $script:fails++ }
    return $ok
}
function Abort([string]$why) {
    Log "ABORT $why; not performing: $script:nextOp"
    throw 'CALIB-ABORT'
}
function Require([string]$name, [bool]$ok, [string]$actual) {
    if (-not (Check $name $ok $actual)) { Abort "precondition failed: $name" }
}
# What the next device-changing operation would be; printed when aborting so the report shows
# exactly what was NOT done.
function NextOp([string]$op) { $script:nextOp = $op }

function Pause-Ms([int]$ms) { if (-not $script:Scn) { Start-Sleep -Milliseconds $ms } }

# ---- mock -----------------------------------------------------------------------------------
function Load-Mock([string]$path) {
    $j = Get-Content -Path $path -Raw | ConvertFrom-Json
    $script:Scn = @{ states = @($j.states); si = 0; exchanges = @($j.exchanges); ei = 0; ports = @($j.ports);
                      uf2 = $j.uf2; files = @{}; copies = @() }
    if ($j.files) { foreach ($p in $j.files.PSObject.Properties) { $script:Scn.files[$p.Name] = $p.Value } }
    Log "MOCK scenario $path"
}
function Mock-Next([string]$kind) {
    $m = $script:Scn
    if ($kind -eq 'state') {
        if ($m.si -lt $m.states.Count) { $v = $m.states[$m.si]; $m.si++ } else { $v = $m.states[$m.states.Count - 1] }
        return $v
    }
}

# ---- files ----------------------------------------------------------------------------------
function File-Md5([string]$path) {
    if ($script:Scn) { if ($script:Scn.files.ContainsKey($path)) { return $script:Scn.files[$path] } else { return $null } }
    if (-not (Test-Path $path)) { return $null }
    return (Get-FileHash -Path $path -Algorithm MD5).Hash.ToLower()
}
# Every file the run will write to the device must exist and match its expected md5 BEFORE the
# first device operation (review #8, point 6).
function Require-File([string]$label, [string]$path, [string]$md5) {
    $h = File-Md5 $path
    Require "$label exists" ($null -ne $h) "$path"
    Require "$label md5" ($h -eq $md5.ToLower()) "have=$h want=$($md5.ToLower())"
}

# ---- USB state ------------------------------------------------------------------------------
function Get-State() {
    if ($script:Scn) { return (Mock-Next 'state') }
    $devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
    if ($devs | Where-Object { $_.InstanceId -match "^USB\\VID_(239A|2886)&PID_[0-9A-F]{4}\\$script:Serial$" }) { return 'boot' }
    if ($devs | Where-Object { $_.InstanceId -match "^USB\\VID_1D50&PID_615E\\$script:Serial$" }) { return 'app' }
    return 'none'
}
function Get-DiagPorts() {
    if ($script:Scn) { return $script:Scn.ports }
    Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^USB\\VID_1D50&PID_615E&MI_' } |
        Where-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data -match "\\$script:Serial$" } |
        ForEach-Object { if ($_.FriendlyName -match '\((COM\d+)\)') { $Matches[1] } }
}
function Count-Bootloaders() {
    if ($script:Scn) { return @($script:Scn.uf2.drives).Count }
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^USB\\VID_(239A|2886)&PID_[0-9A-F]{4}\\[0-9A-F]+$' }).Count
}
# Wait until Get-State returns $want (and, for 'app', a diag port exists). Returns $true/$false.
function Wait-State([string]$want, [int]$seconds) {
    $t0 = Get-Date; $n = 0
    while ($true) {
        $s = Get-State; $script:lastState = $s
        if ($s -eq $want -and ($want -ne 'app' -or (Get-DiagPorts))) { return $true }
        $n++
        if ($script:Scn) { if ($n -ge $seconds) { return $false } } elseif (((Get-Date) - $t0).TotalSeconds -ge $seconds) { return $false }
        Pause-Ms 300
    }
}
# Wait until the state leaves 'app'. Returns the state seen, or 'app' on timeout.
function Wait-Leave-App([int]$seconds) {
    $t0 = Get-Date; $n = 0
    while ($true) {
        $s = Get-State; $script:lastState = $s
        if ($s -ne 'app') { return $s }
        $n++
        if ($script:Scn) { if ($n -ge $seconds) { return 'app' } } elseif (((Get-Date) - $t0).TotalSeconds -ge $seconds) { return 'app' }
        Pause-Ms 200
    }
}

# ---- UF2 drive tied to the serial ------------------------------------------------------------
# Walks USB device -> USBSTOR disk (its PNPDeviceID carries the USB serial) -> partition ->
# logical disk, and returns the drive letters whose chain ends at $script:Serial and which carry
# INFO_UF2.TXT. The caller copies only when exactly one letter comes back (review #8, point 3).
function Get-Uf2DrivesOfSerial() {
    if ($script:Scn) {
        return @($script:Scn.uf2.drives | Where-Object { $_.serial -eq $script:Serial } | ForEach-Object { $_.letter })
    }
    $out = @()
    $disks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match "^USBSTOR\\DISK&.*\\$script:Serial&[0-9]+$" }
    foreach ($d in $disks) {
        $parts = Get-CimAssociatedInstance -InputObject $d -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue
        foreach ($p in $parts) {
            $lds = Get-CimAssociatedInstance -InputObject $p -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue
            foreach ($ld in $lds) {
                $letter = $ld.DeviceID.TrimEnd(':')
                if (Test-Path (Join-Path ($letter + ':\') 'INFO_UF2.TXT')) { $out += $letter }
            }
        }
    }
    return $out
}
function Get-AllUf2Drives() {
    if ($script:Scn) { return @($script:Scn.uf2.drives | ForEach-Object { $_.letter }) }
    return @(Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path ($_.Name + ':\') 'INFO_UF2.TXT') } | ForEach-Object { $_.Name })
}
# Copies $src to the UF2 drive. Returns $true only if the copy raised no error. Never silent.
function Copy-Uf2([string]$src, [string]$letter) {
    if ($script:Scn) {
        $script:Scn.copies += @{ src = $src; letter = $letter }
        Log "DEVICE-OP copy (mock) $src -> ${letter}:"
        if ($script:Scn.uf2.copy -eq 'fail') { Log "copy error (mock): The device is not ready"; return $false }
        return $true
    }
    try {
        Copy-Item -Path $src -Destination (Join-Path ($letter + ':\') 'firmware.uf2') -Force -ErrorAction Stop
        Log "DEVICE-OP copied $src -> ${letter}:"
        return $true
    } catch {
        Log "copy error: $($_.Exception.Message)"
        return $false
    }
}
# After a successful UF2 write the bootloader resets and the drive disappears; a drive that stays
# means the image was not taken. Returns $true when it vanished within $seconds.
function Wait-Uf2Gone([string]$letter, [int]$seconds) {
    if ($script:Scn) { return [bool]$script:Scn.uf2.vanish }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $seconds) {
        if (-not (Test-Path (Join-Path ($letter + ':\') 'INFO_UF2.TXT'))) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# ---- console --------------------------------------------------------------------------------
# One exchange through calib-io.ps1 on each diag port of the serial. Everything the child printed
# (stdout, stderr, exit code) is appended to the step log, dump or not. Returns the stdout text
# of the first port that produced a dump, or $null (after logging) when none did.
function Exchange([string]$Send = '', [int]$ReadSeconds = 0) {
    if ($Send) { Log "DEVICE-OP console send '$Send'" }
    if ($script:Scn) {
        $m = $script:Scn
        if ($m.ei -ge $m.exchanges.Count) { Log "MOCK: no exchange left for send='$Send'"; return $null }
        $e = $m.exchanges[$m.ei]; $m.ei++
        if ($e.send -ne $Send) { Log "MOCK: exchange order mismatch: script sent '$Send', scenario expected '$($e.send)'"; return $null }
        Add-Content -Path $script:LogFile -Value ("----- console MOCK send='$Send' read=${ReadSeconds}s exit=$($e.exit) -----") -Encoding UTF8
        Add-Content -Path $script:LogFile -Value $e.stdout -Encoding UTF8
        if ($e.stderr) { Add-Content -Path $script:LogFile -Value ("[stderr] " + $e.stderr) -Encoding UTF8 }
        Add-Content -Path $script:LogFile -Value '----- end console -----' -Encoding UTF8
        if ($e.stdout -match 'ZDIAG begin') { return $e.stdout }
        return $null
    }
    $helper = Join-Path $PSScriptRoot 'calib-io.ps1'
    $ports = @(Get-DiagPorts)
    if ($ports.Count -eq 0) { Log "no diag port for serial $script:Serial"; return $null }
    foreach ($com in $ports) {
        $psa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-Com', $com, '-ReadSeconds', $ReadSeconds)
        if ($Send) { $psa += @('-Send', $Send) }
        $errFile = [System.IO.Path]::GetTempFileName()
        $stdout = (& powershell.exe @psa 2>$errFile) -join "`n"
        $rc = $LASTEXITCODE
        $stderr = ''
        if (Test-Path $errFile) { $stderr = (Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue); Remove-Item $errFile -ErrorAction SilentlyContinue }
        Add-Content -Path $script:LogFile -Value ("----- console $com send='$Send' read=${ReadSeconds}s exit=$rc -----") -Encoding UTF8
        Add-Content -Path $script:LogFile -Value $stdout -Encoding UTF8
        if ($stderr) { Add-Content -Path $script:LogFile -Value ("[stderr] " + $stderr) -Encoding UTF8 }
        Add-Content -Path $script:LogFile -Value '----- end console -----' -Encoding UTF8
        if ($stdout -match 'ZDIAG begin') { return $stdout }
    }
    return $null
}
# A dump for analysis: must have begin and end marks and the ring/addr/cur lines. Returns the
# parsed table or aborts. #TRUNC lines are saved (already, verbatim) but make the dump unusable.
function Read-Dump([string]$what) {
    Pause-Ms 700
    $t = Exchange
    if (-not $t) { Pause-Ms 1500; $t = Exchange }
    Require "${what}:dump present" ($null -ne $t) 'ZDIAG begin'
    Require "${what}:dump complete" ($t -match 'ZDIAG end') 'ZDIAG end'
    $trunc = @($t -split "`n" | Where-Object { $_ -match '#TRUNC' }).Count
    Require "${what}:no #TRUNC line" ($trunc -eq 0) "trunc lines=$trunc"
    $r = Parse-Zboot $t
    Require "${what}:ZBOOT ring/addr/cur present" ($r.ContainsKey('ring') -and $r.ContainsKey('addr') -and $r.ContainsKey('cur')) "keys=$(($r.Keys | Sort-Object) -join ',')"
    return $r
}
# "ZBOOT <rec> <line> k=v ..." -> $r[rec][line][key]; the ring/addr header lines get line 'x'.
# $r[rec]['_lines'] keeps every raw line of that record (for whole-record comparison).
function Parse-Zboot([string]$text) {
    $r = @{}
    foreach ($l in ($text -split "`n")) {
        $l = $l.TrimEnd("`r")
        if ($l -notmatch '^ZBOOT (\S+) (\S+)(.*)$') { continue }
        $rec = $Matches[1]; $line = $Matches[2]; $rest = $Matches[3].Trim()
        if ($rec -eq 'ring' -or $rec -eq 'addr') { $rest = "$line $rest"; $line = 'x' }
        if (-not $r.ContainsKey($rec)) { $r[$rec] = @{ _lines = @() } }
        $h = @{}
        foreach ($kv in ($rest -split ' ')) { if ($kv -match '^([a-z0-9_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
        $h['_raw'] = $l
        $r[$rec][$line] = $h
        $r[$rec]['_lines'] += $l
    }
    return $r
}
function V($r, $rec, $line, $key) {
    if ($r.ContainsKey($rec) -and $r[$rec].ContainsKey($line) -and $r[$rec][$line].ContainsKey($key)) { return $r[$rec][$line][$key] }
    return $null
}
# A value that the verdict depends on: absent -> abort (never defaulted to 0 or '').
function Need($r, $rec, $line, $key) {
    $v = V $r $rec $line $key
    if ($null -eq $v) { Log "FAIL field present $rec.$line.$key (absent)"; $script:fails++; Abort "missing field $rec.$line.$key" }
    return $v
}
function Hex($s) { if ($s -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }; return -1 }
function Raw($r, $rec, $line) { return (V $r $rec $line '_raw') }

# Common checks on one filed incident (all fields required). $spin = diag_spin_forever of the
# image that fired; $threadKey = 'sysq'/'calib' to match against the addr line, or ''.
function Check-Incident($r, [string]$inc, [string]$tag, [int]$reason, [string]$calib, [int]$done, [long]$spin, [string]$threadKey) {
    Require "$inc present" ($r.ContainsKey($inc)) "keys=$(($r.Keys | Sort-Object) -join ',')"
    Check "$inc tag" ((Need $r $inc 'a' 'tag') -eq $tag) (Raw $r $inc 'a') | Out-Null
    Check "$inc reason=$reason" ((Need $r $inc 'a' 'reason') -eq "$reason") (V $r $inc 'a' 'reason') | Out-Null
    Check "$inc calib=$calib" ((Need $r $inc 'a' 'calib') -eq $calib) (V $r $inc 'a' 'calib') | Out-Null
    Check "$inc done=$done" ((Need $r $inc 'a' 'done') -eq "$done") (V $r $inc 'a' 'done') | Out-Null
    $pc = Hex (Need $r $inc 'fire1' 'pc')
    Check "$inc pc in diag_spin_forever" ($pc -ge $spin -and $pc -lt ($spin + 4)) ("pc=" + (V $r $inc 'fire1' 'pc') + " spin=0x" + $spin.ToString('x')) | Out-Null
    Check "$inc handler=0" ((Need $r $inc 'fire2' 'handler') -eq '0') (Raw $r $inc 'fire2') | Out-Null
    if ($threadKey) {
        $want = Need $r 'addr' 'x' $threadKey
        Check "$inc thread == addr.$threadKey" ((Need $r $inc 'fire2' 'thread') -eq $want) ("thread=" + (V $r $inc 'fire2' 'thread') + " $threadKey=$want") | Out-Null
    }
}
# Did the device reset between the command and now? Three observations, reported separately:
# the console child saw the port vanish (direct), the parent saw USB leave 'app' (direct), the
# boot number advanced (indirect). "not observed" is not "did not reset" (review #8, point 4).
function Check-Reset([string]$text, [string]$leaveState, [int]$seqBefore, [int]$seqAfter, [int]$expectDelta) {
    $portLost = ($text -match '\[calib-io\] port lost')
    $usbLeft = ($leaveState -ne 'app')
    Log ("reset observation: port_lost=$portLost usb_left_app=$usbLeft (state=$leaveState) seq $seqBefore -> $seqAfter")
    Check "boot number advanced by $expectDelta" (($seqAfter - $seqBefore) -eq $expectDelta) "delta=$($seqAfter - $seqBefore)" | Out-Null
    if ($portLost -or $usbLeft) { Log "reset observed directly (port_lost=$portLost usb_left_app=$usbLeft)" }
    else { Log "NOTE reset NOT observed directly: the disconnect may have completed before the parent looked (unobserved, not 'no reset'); the verdict rests on the boot number and the incident record" }
}
