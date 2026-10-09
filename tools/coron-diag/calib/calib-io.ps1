# One serial exchange with a Coron diag console for the boot-instrument calibration.
# Opens the port with DTR (the firmware dumps on DTR), collects the dump, optionally sends one
# command character, then keeps reading for -ReadSeconds so the console's replies after the
# command ("ZDIAG calibrate X rc=N", "... returned") are captured. Every event (open, dump
# complete, sent / NOT sent, port lost, close) is stamped into the output as a "[calib-io] ..."
# line, so the caller can tell WHEN the device went away relative to the command. The stamps never
# contain the dump marks themselves ('ZDIAG begin'/'ZDIAG end'), and the parent matches the marks
# at the start of a line, so a stamp can never pass for a mark.
#
# Send gate (review #9, point 3): the command is written ONLY when the dump read just before it is
# complete (ZDIAG begin AND ZDIAG end) and carries no " #TRUNC" line. Otherwise nothing is
# written, a "NOT sent" stamp says why, and the exit code is 2.
#
# Output is written progressively (every chunk is flushed as it arrives), so a parent that kills
# this process on a timeout still has everything read up to that moment (review #9, point 5).
# Losing the port ends the read without failing: whatever was captured is printed.
# Exit 0 = port opened (and the command sent, if one was given); 1 = could not open / error;
# 2 = command NOT sent (gate). Runs in its own process (see calib-lib.ps1) so a .NET SerialPort
# crash cannot take the driver down.
#
# -MockFile <json>: replaces the SerialPort by a canned port (fields: pre = text the device
# emits before the command, post = text after it, lost = the port vanishes after post,
# hang_s = block that long inside Open (a child that never returns), hang_after_send_s = block that
# long on the first read after the command was written (the 'sent' stamp is out), write_error = throw
# inside the command write (neither 'sent' nor 'NOT sent' is stamped), open_error = fail to open,
# stderr = text to print on stderr, dump_on_request = pre is delivered only after a 'd' write,
# like the test images). Used by the simulation only; the gate and the stamps are the real code
# paths.
# -DumpSeconds: how long to wait for the end mark after the begin mark (the lab image's dump with
# four crash records is ~1,000 lines at 5 ms each; 4 s was enough for the production dump only).
param([Parameter(Mandatory = $true)][string]$Com, [string]$Send = '', [int]$ReadSeconds = 0, [string]$MockFile = '', [int]$DumpSeconds = 20)
$script:mock = $null
function Emit([string]$s) { if ($s) { [Console]::Out.Write($s); [Console]::Out.Flush() } }
function Stamp([string]$m) { Emit ("[calib-io] $m at " + (Get-Date).ToString('HH:mm:ss.fff') + "`n") }
function Nap([int]$ms) { if (-not $script:mock) { Start-Sleep -Milliseconds $ms } }

function New-MockPort {
    $o = New-Object PSObject -Property @{ IsOpen = $false; phase = 0 }
    $o | Add-Member -MemberType ScriptMethod -Name Open -Value {
        if ($script:mock.open_error) { throw $script:mock.open_error }
        $this.IsOpen = $true
        if ($script:mock.hang_s) { Start-Sleep -Seconds ([int]$script:mock.hang_s) }
    }
    $o | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.IsOpen = $false }
    $o | Add-Member -MemberType ScriptMethod -Name Write -Value { param($s)
        if ($s -ceq 'd' -and $this.phase -le 1) { $this.phase = 5; return }   # dump request -> deliver pre on the next read
        if ($script:mock.write_error) { throw (New-Object System.IO.IOException 'The I/O operation has been aborted (simulated, inside the write)') }
        $this.phase = 2 }
    $o | Add-Member -MemberType ScriptMethod -Name ReadExisting -Value {
        switch ($this.phase) {
            0 { $this.phase = 1; if ($script:mock.dump_on_request) { return '' }; return [string]$script:mock.pre }
            5 { $this.phase = 1; return [string]$script:mock.pre }
            2 { $this.phase = 3; if ($script:mock.hang_after_send_s) { Start-Sleep -Seconds ([int]$script:mock.hang_after_send_s) }; return [string]$script:mock.post }
            3 { if ($script:mock.lost) { $this.phase = 4; throw (New-Object System.IO.IOException 'The device does not recognize the command.') }; return '' }
            default { return '' }
        }
    }
    return $o
}

if ($MockFile) {
    $script:mock = Get-Content -Path $MockFile -Raw | ConvertFrom-Json
    if ($script:mock.stderr) { [Console]::Error.Write([string]$script:mock.stderr); [Console]::Error.Flush() }
    $sp = New-MockPort
} else {
    $sp = New-Object System.IO.Ports.SerialPort $Com, 115200
    $sp.DtrEnable = $true
    $sp.ReadTimeout = 300
}
# The marks are whole lines: 'ZDIAG begin ...' at a line start, 'ZDIAG end' alone on its line
# (CRLF from the device). A partial match ('ZDIAG endBROKEN') is not a mark (review #10, point 2).
$BEGIN = '(?m)^ZDIAG begin\b'
$END = '(?m)^ZDIAG end\r?$'
$text = ''
$rc = 0
function ReadChunk {
    $t = $sp.ReadExisting()
    if ($t) { $script:text += $t; Emit $t }
}
try {
    $sp.Open()
    Stamp "opened $Com"
    Nap 1500
    ReadChunk
    if ($text -cnotmatch $BEGIN) {
        # The test images are built without CONFIG_UART_LINE_CTRL (seen on the real device,
        # 2026-10-08 10:49): the console cannot see DTR and dumps only on 'd'. 'd' is a read-only
        # request (the firmware prints the records; nothing changes), so it is sent once here
        # whenever the open did not produce a dump. The production image dumps on DTR by itself.
        $sp.Write('d')
        Stamp "sent 'd' (dump request; no dump within 1.5 s of opening)"
        $deadline = (Get-Date).AddSeconds(4); $iter = 0
        while ($text -cnotmatch $BEGIN) {
            if ($script:mock) { if ($iter -ge 3) { break } } elseif ((Get-Date) -ge $deadline) { break }
            $iter++
            Nap 200
            ReadChunk
        }
    }
    if ($text -cmatch $BEGIN) {
        $deadline = (Get-Date).AddSeconds($DumpSeconds); $iter = 0
        while ($text -cnotmatch $END) {
            if ($script:mock) { if ($iter -ge 3) { break } } elseif ((Get-Date) -ge $deadline) { break }
            $iter++
            Nap 100
            ReadChunk
        }
        if ($text -cmatch $END) { Stamp 'dump complete' } else { Stamp "dump incomplete (no end mark within $DumpSeconds s)" }
    } else {
        Stamp 'no dump (no begin mark within 1.5 s)'
    }
    if ($Send) {
        $complete = ($text -cmatch $BEGIN) -and ($text -cmatch $END)
        $trunc = ($text -cmatch '#TRUNC')
        if ($complete -and -not $trunc) {
            $sp.Write($Send)
            Stamp "sent '$Send'"
            # Read at once and then every 20 ms: the firmware answers 'b'/'r' with one line and
            # reboots ~100 ms later, taking the CDC port (and any unread bytes) with it. A 200 ms
            # first nap lost that line on the real device (loop trial 3, 2026-10-08). The line is
            # evidence for the parent, not its gate (Ack-Evidence in calib-lib.ps1).
            $deadline = (Get-Date).AddSeconds([Math]::Max($ReadSeconds, 1)); $iter = 0
            while ($true) {
                try { ReadChunk } catch { Stamp "port lost ($($_.Exception.Message))"; break }
                if ($script:mock) { if ($iter -ge 3) { break } } elseif ((Get-Date) -ge $deadline) { break }
                $iter++
                Nap 20
            }
            Stamp 'read window over'
        } else {
            $why = if (-not $complete) { 'the dump before it is incomplete' } else { 'the dump before it has a #TRUNC line' }
            Stamp "NOT sent '$Send': $why"
            $rc = 2
        }
    }
} catch {
    Stamp "error on $Com ($($_.Exception.Message))"
    $rc = 1
} finally {
    Stamp 'closing'
    try { if ($sp.IsOpen) { $sp.Close() } } catch {}
}
exit $rc
