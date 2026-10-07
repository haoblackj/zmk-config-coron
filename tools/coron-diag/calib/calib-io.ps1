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
# hang_s = block that long inside Open (a child that never returns), open_error = fail to open,
# stderr = text to print on stderr). Used by the simulation only; the gate and the stamps are
# the real code paths.
param([Parameter(Mandatory = $true)][string]$Com, [string]$Send = '', [int]$ReadSeconds = 0, [string]$MockFile = '')
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
    $o | Add-Member -MemberType ScriptMethod -Name Write -Value { param($s) $this.phase = 2 }
    $o | Add-Member -MemberType ScriptMethod -Name ReadExisting -Value {
        switch ($this.phase) {
            0 { $this.phase = 1; return [string]$script:mock.pre }
            2 { $this.phase = 3; return [string]$script:mock.post }
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
    if ($text -cmatch $BEGIN) {
        $deadline = (Get-Date).AddSeconds(4); $iter = 0
        while ($text -cnotmatch $END) {
            if ($script:mock) { if ($iter -ge 3) { break } } elseif ((Get-Date) -ge $deadline) { break }
            $iter++
            Nap 100
            ReadChunk
        }
        if ($text -cmatch $END) { Stamp 'dump complete' } else { Stamp 'dump incomplete (no end mark within 4 s)' }
    } else {
        Stamp 'no dump (no begin mark within 1.5 s)'
    }
    if ($Send) {
        $complete = ($text -cmatch $BEGIN) -and ($text -cmatch $END)
        $trunc = ($text -cmatch '#TRUNC')
        if ($complete -and -not $trunc) {
            $sp.Write($Send)
            Stamp "sent '$Send'"
            $deadline = (Get-Date).AddSeconds([Math]::Max($ReadSeconds, 1)); $iter = 0
            while ($true) {
                if ($script:mock) { if ($iter -ge 3) { break } } elseif ((Get-Date) -ge $deadline) { break }
                $iter++
                Nap 200
                try { ReadChunk } catch { Stamp "port lost ($($_.Exception.Message))"; break }
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
