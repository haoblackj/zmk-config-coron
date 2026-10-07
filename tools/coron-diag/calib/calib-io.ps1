# One serial exchange with a Coron diag console for the boot-instrument calibration.
# Opens the port with DTR (the firmware dumps on DTR), collects the dump, optionally sends one
# command character, then keeps reading for -ReadSeconds so the console's replies after the
# command ("ZDIAG calibrate X rc=N", "... returned") are captured. Losing the port (the device
# reset) ends the read without failing: whatever was captured is printed.
# Runs in its own process (see calib-run.ps1) so a .NET SerialPort crash cannot take the driver down.
param([Parameter(Mandatory = $true)][string]$Com, [string]$Send = '', [int]$ReadSeconds = 0)
$sp = New-Object System.IO.Ports.SerialPort $Com, 115200
$sp.DtrEnable = $true
$sp.ReadTimeout = 300
$text = ''
try {
    $sp.Open()
    Start-Sleep -Milliseconds 1500
    $text = $sp.ReadExisting()
    if ($text -match 'ZDIAG begin') {
        $deadline = (Get-Date).AddSeconds(4)
        while ($text -notmatch 'ZDIAG end' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $text += $sp.ReadExisting()
        }
    }
    if ($Send -and $text -match 'ZDIAG begin') {
        $sp.Write($Send)
        $text += "`n[calib-io] sent '$Send' at " + (Get-Date).ToString('HH:mm:ss.fff') + "`n"
        $deadline = (Get-Date).AddSeconds([Math]::Max($ReadSeconds, 1))
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
            try { $text += $sp.ReadExisting() } catch { $text += "`n[calib-io] port lost at " + (Get-Date).ToString('HH:mm:ss.fff') + ": $($_.Exception.Message)`n"; break }
        }
    }
} catch {
    $text += "`n[calib-io] error on ${Com}: $($_.Exception.Message)`n"
} finally {
    [Console]::Out.Write($text)
    [Console]::Out.Flush()
    try { if ($sp.IsOpen) { $sp.Close() } } catch {}
}
exit 0
