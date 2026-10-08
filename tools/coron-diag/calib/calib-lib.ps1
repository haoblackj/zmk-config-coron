# Shared functions for the boot-instrument calibration scripts (dot-sourced).
# Real mode talks to Windows (Get-PnpDevice, CIM disk chain, a child calib-io.ps1 per serial
# exchange). Mock mode ($script:Scn, a scenario loaded from JSON) replays canned device states,
# UF2 drives, copy results and file hashes, and feeds the REAL calib-io.ps1 child a canned port
# (-MockFile), so every decision path, including the child's send gate and a hanging child, can
# be exercised without a device. Reads the device tree only (Get-PnpDevice / CIM disk classes);
# never Win32_SerialPort.
#
# Contract for callers:
#   Log/Check/Require/Abort write to $script:LogFile. Check records PASS/FAIL and continues;
#   Require is Check + Abort on failure, used for every precondition of a device write, so a
#   failed precondition stops before the write. Abort throws 'CALIB-ABORT'; the step runner
#   catches it, logs "STOPPED before <next operation>", saves everything and exits 1.
#   Every console exchange is saved verbatim (stdout, stderr, exit code, timeout) whether or not
#   it looks like a dump. Missing values are never defaulted: Validate-Dump requires every line
#   and key the firmware prints for each record, and Need() aborts when a field is absent.
#   Console text is compared case-sensitively (-ceq/-cmatch): 'h' and 'H' are different
#   commands (review #9, point 4). Windows PnP instance ids keep the case-insensitive -match.
#   Children run through Invoke-Child with a deadline; a child that does not return is killed
#   with its process tree and counted as a failure (review #9, point 5).

$script:fails = 0
$script:nextOp = 'start'
$script:xn = 0
$script:childAlive = $false   # set when a timed-out console child could not be confirmed dead (exit 5)

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
# Throws when the file is missing or not JSON; the caller exits 4 before any device operation
# (review #9, point 1).
function Load-Mock([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "mock scenario file missing: $path" }
    $j = Get-Content -Path $path -Raw | ConvertFrom-Json
    if ($null -eq $j) { throw "mock scenario file empty or invalid: $path" }
    $script:Scn = @{ states = @($j.states); si = 0; exchanges = @($j.exchanges); ei = 0; ports = @($j.ports);
                      uf2 = $j.uf2; files = @{}; copies = @(); step_hang_s = [int]$j.step_hang_s; kill_mode = [string]$j.kill_mode }
    if ($j.files) { foreach ($p in $j.files.PSObject.Properties) { $script:Scn.files[$p.Name] = $p.Value } }
    Log "MOCK scenario $path"
}
function Mock-Next([string]$kind) {
    $m = $script:Scn
    if ($kind -ceq 'state') {
        if ($m.si -lt $m.states.Count) { $v = $m.states[$m.si]; $m.si++ } else { $v = $m.states[$m.states.Count - 1] }
        return $v
    }
}

# ---- files ----------------------------------------------------------------------------------
function File-Md5([string]$path) {
    if ($script:Scn) { if ($script:Scn.files.ContainsKey($path)) { return $script:Scn.files[$path] } else { return $null } }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash.ToLower()
}
# Every file the run will write to the device must exist and match its expected md5 BEFORE the
# first device operation (review #8, point 6).
function Require-File([string]$label, [string]$path, [string]$md5) {
    $h = File-Md5 $path
    Require "$label exists" ($null -ne $h) "$path"
    Require "$label md5" ($h -ceq $md5.ToLower()) "have=$h want=$($md5.ToLower())"
}

# ---- child processes ------------------------------------------------------------------------
# Runs powershell.exe -File $file $argv with stdout/stderr redirected to files (written as the
# child flushes, so a killed child leaves what it had) and a deadline. On the deadline the
# termination is delegated to calib-kill.ps1, a separate process that enumerates the tree
# (Win32_Process), runs taskkill /T /F, logs its output and exit code, and polls every pid for up
# to 5 s. THAT process is itself waited for with a deadline ($killTimeoutSec, 20 s): the CIM
# enumeration and taskkill are synchronous calls that cannot be interrupted from inside, so the
# deadline on the termination as a whole lives here (review #11). If the helper does not return,
# its partial progress is logged, it is dropped with Process.Kill() (asynchronous, best effort,
# never counted as a confirmation) and the termination is NOT confirmed.
# Returns @{ rc; timedOut; killed; alive; tree }: killed=$true ONLY when the helper returned 0
# (taskkill returned 0 AND no pid of the tree was left) within the deadline (review #10, point 3).
# $killMode (simulation only) is passed to the helper: 'fail', 'linger', 'enum-hang', 'kill-hang'.
function Invoke-Child([string]$file, [string[]]$argv, [int]$timeoutSec, [string]$outFile, [string]$errFile, [string]$killMode = '', [int]$killTimeoutSec = 20) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) + $argv
    $quoted = ($all | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' }) -join ' '
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru
    $null = $p.Handle
    $done = $p.WaitForExit($timeoutSec * 1000)
    if ($done) {
        $p.WaitForExit()
        return @{ rc = $p.ExitCode; timedOut = $false; killed = $false; alive = @(); tree = @($p.Id) }
    }
    Log "deadline ${timeoutSec}s passed for pid $($p.Id): terminating through calib-kill.ps1 (deadline ${killTimeoutSec}s for enumeration + request + confirmation)"
    $helper = Join-Path $PSScriptRoot 'calib-kill.ps1'
    $kout = "$outFile.kill"; $kerr = "$outFile.kill.err"
    $kargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-TargetPid', "$($p.Id)")
    if ($killMode) { $kargs += @('-Mode', $killMode) }
    $kq = ($kargs | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' }) -join ' '
    $k = Start-Process -FilePath 'powershell.exe' -ArgumentList $kq -RedirectStandardOutput $kout -RedirectStandardError $kerr -NoNewWindow -PassThru
    $null = $k.Handle
    $kdone = $k.WaitForExit($killTimeoutSec * 1000)
    $progress = ''
    if (Test-Path -LiteralPath $kout) { $progress = [string](Get-Content -LiteralPath $kout -Raw -ErrorAction SilentlyContinue) }
    foreach ($l in ($progress -split "`r?`n")) { if ($l) { Log "kill: $l" } }
    $tree = @(); if ($progress -cmatch '(?m)^tree=\[([0-9,]*)\]') { $tree = @($Matches[1] -split ',' | Where-Object { $_ }) }
    $alive = @(); if ($progress -cmatch '(?m)^alive=\[([0-9,]*)\]') { $alive = @($Matches[1] -split ',' | Where-Object { $_ }) }
    if (-not $kdone) {
        $phase = 'unknown'; if ($progress -cmatch '(?m)^phase=(\S+)') { $phase = @([regex]::Matches($progress, '(?m)^phase=(\S+)') | ForEach-Object { $_.Groups[1].Value })[-1] }
        Log "termination confirmed=False: kill helper did not return within ${killTimeoutSec}s (last phase=$phase); dropping it with Process.Kill (not a confirmation)"
        try { $k.Kill() } catch {}
        if ($alive.Count -eq 0) { $alive = @("$($p.Id)") }
        return @{ rc = $null; timedOut = $true; killed = $false; alive = $alive; tree = $tree }
    }
    $k.WaitForExit()
    $killed = ($k.ExitCode -eq 0 -and ($progress -cmatch '(?m)confirmed=True'))
    Log "termination confirmed=$killed (kill helper rc=$($k.ExitCode); pids still alive: [$($alive -join ',')])"
    if (-not $killed -and $alive.Count -eq 0) { $alive = @("$($p.Id)") }
    return @{ rc = $null; timedOut = $true; killed = $killed; alive = $alive; tree = $tree }
}

# ---- identification (one implementation for the real PC and the mock; see calib-selftest.ps1) --
# The UF2 disk of this serial: Windows prefixes the serial in the USBSTOR instance id with a
# generated "A&258725EA&0&" (read on the real PC, 2026-10-08 10:42:
#   USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1&0 ),
# so the serial is the element right before the trailing "&<n>", after either "\" or "&".
# A longer or shorter string in that position is NOT the serial.
function Test-UsbstorSerial([string]$pnp) {
    return ($pnp -match ("^USBSTOR\\DISK&.*(\\|&)" + [regex]::Escape($script:Serial) + "&[0-9]+$"))
}
# The diag console is the CDC ACM interface with USB interface number $script:ConsoleMI (default
# 00). Derivation: both images set zephyr,console = &board_cdc_acm_uart, the first
# zephyr,cdc-acm-uart node (cdc_acm instance 0, zephyr.dts of the bt4 and the production build);
# Zephyr's legacy USB stack numbers interfaces in descriptor order (usb_fix_descriptor,
# usb_descriptor.c), and on the real PC MI_00 is the only interface that ever answered the ZDIAG
# protocol (test image: MI_00 only; production image: MI_00 dumps on DTR, MI_03 = Studio RPC UART,
# the snippet's second node, never did). The bus-reported description is "coron" on every
# interface, so it cannot tell them apart. Nothing is written to any other interface.
$script:ConsoleMI = '00'
function Test-ConsoleIface([string]$instanceId) {
    return ($instanceId -match ("^USB\\VID_1D50&PID_615E&MI_" + $script:ConsoleMI + "\\"))
}

# ---- USB state ------------------------------------------------------------------------------
function Get-State() {
    if ($script:Scn) { return (Mock-Next 'state') }
    $devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
    if ($devs | Where-Object { $_.InstanceId -match "^USB\\VID_(239A|2886)&PID_[0-9A-F]{4}\\$script:Serial$" }) { return 'boot' }
    if ($devs | Where-Object { $_.InstanceId -match "^USB\\VID_1D50&PID_615E\\$script:Serial$" }) { return 'app' }
    return 'none'
}
# COM names of the diag console of this serial: a Ports device whose instance id is the console
# interface (Test-ConsoleIface) AND whose parent is this serial. Other CDC interfaces of the same
# device (the Studio RPC UART) are never returned, so nothing is ever written to them
# (review #13, point 1). Mock: entries {com, id} filtered by the same function.
function Get-DiagPorts() {
    if ($script:Scn) { return @($script:Scn.ports | Where-Object { Test-ConsoleIface ([string]$_.id) } | ForEach-Object { [string]$_.com }) }
    Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue |
        Where-Object { Test-ConsoleIface $_.InstanceId } |
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
        if ($s -ceq $want -and ($want -cne 'app' -or (Get-DiagPorts))) { return $true }
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
        if ($s -cne 'app') { return $s }
        $n++
        if ($script:Scn) { if ($n -ge $seconds) { return 'app' } } elseif (((Get-Date) - $t0).TotalSeconds -ge $seconds) { return 'app' }
        Pause-Ms 200
    }
}

# ---- UF2 drive tied to the serial ------------------------------------------------------------
# Walks USB device -> USBSTOR disk (its PNPDeviceID carries the USB serial) -> partition ->
# logical disk, and returns the drive letters whose chain ends at $script:Serial and which carry
# INFO_UF2.TXT. The caller copies only when exactly one letter comes back (review #8, point 3).
# The serial match is Test-UsbstorSerial (above; the earlier "\<serial>&<n>" form found nothing
# on the real PC and stopped the first real run before any copy).
function Get-Uf2DrivesOfSerial() {
    if ($script:Scn) {
        # the mock carries the full USBSTOR instance id of each drive; the real matcher runs on it
        return @($script:Scn.uf2.drives | Where-Object { Test-UsbstorSerial ([string]$_.pnp) } | ForEach-Object { $_.letter })
    }
    $out = @()
    $disks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
        Where-Object { Test-UsbstorSerial $_.PNPDeviceID }
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
        if ($script:Scn.uf2.copy -ceq 'fail') { Log "copy error (mock): The device is not ready"; return $false }
        return $true
    }
    try {
        Copy-Item -LiteralPath $src -Destination (Join-Path ($letter + ':\') 'firmware.uf2') -Force -ErrorAction Stop
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
# One exchange through calib-io.ps1 on each diag port of the serial, with a deadline
# ($ReadSeconds + 20 s; the child itself waits at most 1.5 + 4 + $ReadSeconds s). Everything the
# child printed (stdout, stderr, exit code, timeout) is appended to the step log, dump or not.
# Returns the stdout text of the first port that produced a dump (a 'ZDIAG begin' LINE; the child's
# stamps are never matched as marks), or $null (after logging) when none did. Whether a command was actually written is known ONLY from the child's
# "[calib-io] sent 'X'" stamp; see Send-Cmd.
function Exchange([string]$Send = '', [int]$ReadSeconds = 0) {
    $helper = Join-Path $PSScriptRoot 'calib-io.ps1'
    $dir = Split-Path -Parent $script:LogFile
    $ports = @(Get-DiagPorts)
    if ($ports.Count -eq 0) { Log "no diag port for serial $script:Serial"; return $null }
    foreach ($com in $ports) {
        $script:xn++
        $base = Join-Path $dir (((Split-Path -Leaf $script:LogFile) -replace '\.log$', '') + "-io$($script:xn)")
        $outFile = "$base.out"; $errFile = "$base.err"
        $argv = @('-Com', $com, '-ReadSeconds', "$ReadSeconds")
        if ($Send) { $argv += @('-Send', $Send) }
        $timeout = $ReadSeconds + 20
        if ($script:Scn) {
            $m = $script:Scn
            if ($m.ei -ge $m.exchanges.Count) { Log "MOCK: no exchange left for send='$Send'"; $script:fails++; return $null }
            $e = $m.exchanges[$m.ei]; $m.ei++
            if ([string]$e.send -cne $Send) { Log "MOCK: exchange order mismatch: script sent '$Send', scenario expected '$($e.send)'"; $script:fails++; return $null }
            $mockPath = "$base.mock.json"
            $e | ConvertTo-Json -Depth 4 | Set-Content -Path $mockPath -Encoding UTF8
            $argv += @('-MockFile', $mockPath)
            if ($e.io_timeout_s) { $timeout = [int]$e.io_timeout_s }
        }
        $killMode = ''
        if ($script:Scn -and $script:Scn.kill_mode) { $killMode = [string]$script:Scn.kill_mode }
        $res = Invoke-Child $helper $argv $timeout $outFile $errFile $killMode
        $stdout = ''; $stderr = ''
        if (Test-Path -LiteralPath $outFile) { $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path -LiteralPath $errFile) { $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
        $stdout = $stdout -replace "`r`n", "`n"
        Add-Content -Path $script:LogFile -Value ("----- console $com send='$Send' read=${ReadSeconds}s exit=$($res.rc) timed_out=$($res.timedOut) deadline=${timeout}s -----") -Encoding UTF8
        Add-Content -Path $script:LogFile -Value $stdout -Encoding UTF8
        if ($stderr) { Add-Content -Path $script:LogFile -Value ("[stderr] " + $stderr) -Encoding UTF8 }
        Add-Content -Path $script:LogFile -Value '----- end console -----' -Encoding UTF8
        $sentStamp = ($Send -and ($stdout -cmatch ("\[calib-io\] sent '" + [regex]::Escape($Send) + "'")))
        if ($res.timedOut) {
            $stampTxt = $(if ($sentStamp) { 'PRESENT' } else { 'absent' })
            if ($res.killed) {
                Log "FAIL console child returned within ${timeout}s (timed out; killed with its process tree, termination confirmed; sent stamp $stampTxt)"
                $script:fails++
                return $null
            }
            Log "FAIL console child returned within ${timeout}s (timed out; termination NOT confirmed, pids still alive [$($res.alive -join ',')]; sent stamp $stampTxt)"
            $script:fails++
            $script:childAlive = $true
            Abort "a console child may still be alive and could still write to the port; no further device operation"
        }
        if ($Send) {
            if ($sentStamp) { Log "DEVICE-OP console sent '$Send' (child stamp)" }
            else { Log "console '$Send' NOT sent by the child (exit=$($res.rc))" }
        }
        if ($stdout -cmatch '(?m)^ZDIAG begin') { return $stdout }
    }
    return $null
}
# A command exchange whose verdict needs the command to have been written: the child's own
# "sent" stamp is required (the child writes only after a complete, #TRUNC-free dump; review #9,
# point 3). On a refusal nothing was written, so Abort reports the command as not performed.
function Send-Cmd([string]$cmd, [int]$ReadSeconds) {
    $t = Exchange $cmd $ReadSeconds
    Require "'$cmd' written by the console child (its pre-send dump complete and without #TRUNC)" ($null -ne $t -and ($t -cmatch ("\[calib-io\] sent '" + [regex]::Escape($cmd) + "'"))) 'child stamp "sent"'
    return $t
}

# ---- dump structure --------------------------------------------------------------------------
# The lines and keys print_rec/diag_boot_print (diag_boot.c v4) emit for every record. A record
# is complete only with all of them; the fire1..fire4 lines (exception frame, registers, USBD,
# clocks) are printed only when the net fired (fire.exc_return != 0), so a BOOT_TIMEOUT/WQ_TIMEOUT
# incident must carry all four and an interrupted boot (reason 0) carries none (review #10, point 1).
$script:RecLines = @('a', 'b', 'entry1', 'entry2', 'us1', 'us2')
$script:FireLines = @('fire1', 'fire2', 'fire3', 'fire4')
$script:LineKeys = @{
    a      = @('seq', 'tag', 'done', 'reason', 'phase', 'calib', 'stage', 'reset', 'reinit')
    b      = @('fix', 'probes', 'feeds', 'loops', 'lastfeed_us')
    entry1 = @('lfstat', 'lfrun', 'lfsrc', 'lfcopy', 'lfev')
    entry2 = @('hfstat', 'hfrun', 'hfev', 'rtc1', 'usbreg', 'ficr130', 'ficr134')
    us1    = @('hook', 'pk1', 'clk', 'pk1end', 'sysclk', 'post', 'app')
    us2    = @('usb', 'applast', 'commit', 'mainexit', 'probed', 'running')
    fire1  = @('exc', 'msp', 'psp', 'frame', 'pc', 'lr')
    fire2  = @('xpsr', 'handler', 'thread', 'at_us')
    fire3  = @('en', 'ec', 'pullup', 'usbreg')
    fire4  = @('lfstat', 'lfrun', 'hfstat', 'hfrun', 'cc0')
    ring   = @('count', 'slots', 'dropped', 'invalid', 'reinit', 'calib_live')
    addr   = @('cur', 'last', 'ring', 'sysq', 'main', 'calib')
}
function Validate-Line($r, [string]$rec, [string]$line, [string]$what) {
    Require "${what}:$rec $line line present" ($r[$rec].ContainsKey($line)) ("lines=" + (($r[$rec].Keys | Where-Object { $_ -cne '_lines' } | Sort-Object) -join ','))
    foreach ($k in $script:LineKeys[$line]) {
        Require "${what}:$rec $line.$k present" ($r[$rec][$line].ContainsKey($k)) (Raw $r $rec $line)
    }
}
# $fireMode: 'required' (the net fired: all four lines), 'optional' (all four or none), or
# 'by-reason' for an incident: diag_boot.c's is_incident() files BOOT_TIMEOUT/WQ_TIMEOUT records
# (reason 1/2, the net fired, fire lines required) AND boots that ended with boot_done=0 without a
# requested reboot (reason 0, no firing, print_rec prints no fire line); a partial set is rejected
# in every mode (review #10, point 1).
function Validate-Record($r, [string]$rec, [string]$what, [string]$fireMode) {
    Require "${what}:$rec present" ($r.ContainsKey($rec)) "keys=$(($r.Keys | Sort-Object) -join ',')"
    foreach ($ln in $script:RecLines) { Validate-Line $r $rec $ln $what }
    $nf = @($script:FireLines | Where-Object { $r[$rec].ContainsKey($_) }).Count
    if ($fireMode -ceq 'by-reason') {
        $reason = $r[$rec]['a']['reason']
        if ($reason -ceq '1' -or $reason -ceq '2') { $fireMode = 'required' }
        else { Log "${what}:$rec reason=$reason (boot interrupted without the net firing): fire lines not required, all-or-none"; $fireMode = 'optional' }
    }
    if ($fireMode -ceq 'required') { Require "${what}:$rec fire1..fire4 (exception frame, registers, USBD, clocks) present" ($nf -eq 4) "fire lines=$nf" }
    else { Require "${what}:$rec fire lines all-or-none" ($nf -eq 0 -or $nf -eq 4) "fire lines=$nf" }
    if ($nf -eq 4) { foreach ($ln in $script:FireLines) { Validate-Line $r $rec $ln $what } }
}
# Checks the whole dump, not only the fields a step reads: begin/end marks, no #TRUNC, the ring and
# addr headers with all keys, every incident the ring count announces with every line and key,
# last (a record or 'none'), cur. Returns the parsed table; returns $null when the dump has no
# ZBOOT line at all and $zbootRequired is $false (an image without the boot instrument).
function Validate-Dump([string]$t, [string]$what, [bool]$zbootRequired) {
    Require "${what}:dump complete" ($t -cmatch '(?m)^ZDIAG end\s*$') 'ZDIAG end line'
    $trunc = @($t -split "`n" | Where-Object { $_ -cmatch '#TRUNC' }).Count
    Require "${what}:no #TRUNC line" ($trunc -eq 0) "trunc lines=$trunc"
    $zb = @($t -split "`n" | Where-Object { $_ -cmatch '^ZBOOT ' }).Count
    if ($zb -eq 0) {
        if ($zbootRequired) { Require "${what}:ZBOOT lines present" $false 'zboot=0' }
        Log "${what}: no ZBOOT line (the running image has no boot instrument)"
        return $null
    }
    $r = Parse-Zboot $t
    Require "${what}:ring header present" ($r.ContainsKey('ring') -and $r['ring'].ContainsKey('x')) "keys=$(($r.Keys | Sort-Object) -join ',')"
    foreach ($k in $script:LineKeys['ring']) { Require "${what}:ring.$k present" ($r['ring']['x'].ContainsKey($k)) (Raw $r 'ring' 'x') }
    Require "${what}:addr header present" ($r.ContainsKey('addr') -and $r['addr'].ContainsKey('x')) "keys=$(($r.Keys | Sort-Object) -join ',')"
    foreach ($k in $script:LineKeys['addr']) { Require "${what}:addr.$k present" ($r['addr']['x'].ContainsKey($k)) (Raw $r 'addr' 'x') }
    $n = [int]$r['ring']['x']['count']; $slots = [int]$r['ring']['x']['slots']
    Require "${what}:ring count <= slots" ($n -le $slots) "count=$n slots=$slots"
    for ($i = 0; $i -lt $n; $i++) { Validate-Record $r "inc$i" $what 'by-reason' }
    $incKeys = @($r.Keys | Where-Object { $_ -cmatch '^inc\d+$' }).Count
    Require "${what}:incident records == ring count" ($incKeys -eq $n) "records=$incKeys count=$n"
    if ($r.ContainsKey('last') -and $r['last'].ContainsKey('none')) { Log "${what}: last none" } else { Validate-Record $r 'last' $what 'optional' }
    Validate-Record $r 'cur' $what 'optional'
    # ring_reinit_this_boot is one per-boot flag printed in both places (diag_boot.c 443/696)
    Require "${what}:ring header reinit == cur reinit" ("$($r['ring']['x']['reinit'])" -ceq "$($r['cur']['a']['reinit'])") ("header=$($r['ring']['x']['reinit']) cur=$($r['cur']['a']['reinit'])")
    return $r
}
# A dump for analysis. -ZbootOptional: accept an image without ZBOOT lines (preflight on whatever
# image is running); the result is then $null.
function Read-Dump([string]$what, [switch]$ZbootOptional) {
    Pause-Ms 700
    $t = Exchange
    if (-not $t) { Pause-Ms 1500; $t = Exchange }
    Require "${what}:dump present" ($null -ne $t) 'ZDIAG begin'
    return (Validate-Dump $t $what (-not $ZbootOptional))
}
# "ZBOOT <rec> <line> k=v ..." -> $r[rec][line][key]; the ring/addr header lines get line 'x'.
# $r[rec]['_lines'] keeps every raw line of that record (for whole-record comparison).
function Parse-Zboot([string]$text) {
    $r = @{}
    foreach ($l in ($text -split "`n")) {
        $l = $l.TrimEnd("`r")
        if ($l -cnotmatch '^ZBOOT (\S+) (\S+)(.*)$') { continue }
        $rec = $Matches[1]; $line = $Matches[2]; $rest = $Matches[3].Trim()
        if ($rec -ceq 'ring' -or $rec -ceq 'addr') { $rest = "$line $rest"; $line = 'x' }
        if (-not $r.ContainsKey($rec)) { $r[$rec] = @{ _lines = @() } }
        $h = @{}
        foreach ($kv in ($rest -split ' ')) { if ($kv -cmatch '^([a-z0-9_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
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
function Hex($s) { if ($s -cmatch '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }; return -1 }
function Raw($r, $rec, $line) { return (V $r $rec $line '_raw') }

# Common checks on one filed incident (all fields required; the four fire lines were already
# required by Validate-Dump and are logged here as the evidence for the stall cause). $spin =
# diag_spin_forever of the image that fired; $threadKey = 'sysq'/'calib' to match against the
# addr line, or ''.
function Check-Incident($r, [string]$inc, [string]$tag, [int]$reason, [string]$calib, [int]$done, [long]$spin, [string]$threadKey) {
    Require "$inc present" ($r.ContainsKey($inc)) "keys=$(($r.Keys | Sort-Object) -join ',')"
    Check "$inc tag" ((Need $r $inc 'a' 'tag') -ceq $tag) (Raw $r $inc 'a') | Out-Null
    Check "$inc reason=$reason" ((Need $r $inc 'a' 'reason') -ceq "$reason") (V $r $inc 'a' 'reason') | Out-Null
    Check "$inc calib=$calib" ((Need $r $inc 'a' 'calib') -ceq $calib) (V $r $inc 'a' 'calib') | Out-Null
    Check "$inc done=$done" ((Need $r $inc 'a' 'done') -ceq "$done") (V $r $inc 'a' 'done') | Out-Null
    $pc = Hex (Need $r $inc 'fire1' 'pc')
    Check "$inc pc in diag_spin_forever" ($pc -ge $spin -and $pc -lt ($spin + 4)) ("pc=" + (V $r $inc 'fire1' 'pc') + " spin=0x" + $spin.ToString('x')) | Out-Null
    Check "$inc handler=0" ((Need $r $inc 'fire2' 'handler') -ceq '0') (Raw $r $inc 'fire2') | Out-Null
    if ($threadKey) {
        $want = Need $r 'addr' 'x' $threadKey
        Check "$inc thread == addr.$threadKey" ((Need $r $inc 'fire2' 'thread') -ceq $want) ("thread=" + (V $r $inc 'fire2' 'thread') + " $threadKey=$want") | Out-Null
    }
    foreach ($ln in @('fire1', 'fire3', 'fire4')) { Need $r $inc $ln $script:LineKeys[$ln][0] | Out-Null; Log ("$inc evidence: " + (Raw $r $inc $ln)) }
}
# Did the device reset between the command and now? Three observations, reported separately:
# the console child saw the port vanish (direct), the parent saw USB leave 'app' (direct), the
# boot number advanced (indirect). "not observed" is not "did not reset" (review #8, point 4).
function Check-Reset([string]$text, [string]$leaveState, [int]$seqBefore, [int]$seqAfter, [int]$expectDelta) {
    $portLost = ($text -cmatch '\[calib-io\] port lost')
    $usbLeft = ($leaveState -cne 'app')
    Log ("reset observation: port_lost=$portLost usb_left_app=$usbLeft (state=$leaveState) seq $seqBefore -> $seqAfter")
    Check "boot number advanced by $expectDelta" (($seqAfter - $seqBefore) -eq $expectDelta) "delta=$($seqAfter - $seqBefore)" | Out-Null
    if ($portLost -or $usbLeft) { Log "reset observed directly (port_lost=$portLost usb_left_app=$usbLeft)" }
    else { Log "NOTE reset NOT observed directly: the disconnect may have completed before the parent looked (unobserved, not 'no reset'); the verdict rests on the boot number and the incident record" }
}
