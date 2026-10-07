# One serial exchange with a Coron diag console for the boot-instrument calibration.
# Opens the port with DTR (the firmware dumps on DTR), collects the dump, optionally sends one
# command character, then keeps reading for -ReadSeconds so the console's replies after the
# command ("ZDIAG calibrate X rc=N", "... returned") are captured. Every event (open, dump
# complete, sent, port lost, close) is stamped into the output as a "[calib-io] ..." line, so
# the caller can tell WHEN the device went away relative to the command. Losing the port ends the
# read without failing: whatever was captured is printed. Exit 0 = port opened; 1 = could not.
# Runs in its own process (see calib-lib.ps1) so a .NET SerialPort crash cannot take the driver down.
param([Parameter(Mandatory = $true)][string]$Com, [string]$Send = '', [int]$ReadSeconds = 0)
function Stamp($m) { return "[calib-io] $m at " + (Get-Date).ToString('HH:mm:ss.fff') + "`n" }
$sp = New-Object System.IO.Ports.SerialPort $Com, 115200
$sp.DtrEnable = $true
$sp.ReadTimeout = 300
$text = ''
$rc = 0
try {
    $sp.Open()
    $text += Stamp "opened $Com"
    Start-Sleep -Milliseconds 1500
    $text += $sp.ReadExisting()
    if ($text -match 'ZDIAG begin') {
        $deadline = (Get-Date).AddSeconds(4)
        while ($text -notmatch 'ZDIAG end' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $text += $sp.ReadExisting()
        }
        if ($text -match 'ZDIAG end') { $text += "`n" + (Stamp 'dump complete') } else { $text += "`n" + (Stamp 'dump incomplete (no ZDIAG end within 4 s)') }
    } else {
        $text += "`n" + (Stamp 'no dump (no ZDIAG begin within 1.5 s)')
    }
    if ($Send -and $text -match 'ZDIAG begin') {
        $sp.Write($Send)
        $text += Stamp "sent '$Send'"
        $deadline = (Get-Date).AddSeconds([Math]::Max($ReadSeconds, 1))
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
            try { $text += $sp.ReadExisting() } catch { $text += "`n" + (Stamp "port lost ($($_.Exception.Message))"); break }
        }
        $text += "`n" + (Stamp 'read window over')
    }
} catch {
    $text += "`n" + (Stamp "error on $Com ($($_.Exception.Message))")
    $rc = 1
} finally {
    $text += Stamp 'closing'
    [Console]::Out.Write($text)
    [Console]::Out.Flush()
    try { if ($sp.IsOpen) { $sp.Close() } } catch {}
}
exit $rc
