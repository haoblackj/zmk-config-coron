#!/usr/bin/env bash
# Studio RPC probe for the right half: send core.get_device_info over the Studio RPC UART
# (USB interface MI_03 of serial B17318CDBE9A61B1) and print the raw reply as hex.
# Request = zmk.studio.Request{request_id=1, core={get_device_info=true}} = 08 01 1A 02 08 01,
# framed as SOF(0xAB) payload EOF(0xAD). Nothing else is written. usage: studio-probe.sh <out-file>
set -u
out=$1
ser=B17318CDBE9A61B1
powershell.exe -NoProfile -Command "
\$port = Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -match 'VID_1D50&PID_615E&MI_03' } | ForEach-Object {
    \$parent = (Get-PnpDeviceProperty -InstanceId \$_.InstanceId -KeyName DEVPKEY_Device_Parent).Data
    if (\$parent -match '$ser' -and \$_.FriendlyName -match '\((COM\d+)\)') { \$Matches[1] }
} | Select-Object -First 1
if (-not \$port) { [Console]::Out.WriteLine('PROBE no MI_03 port'); exit 1 }
[Console]::Out.WriteLine('PROBE port ' + \$port)
\$p = New-Object System.IO.Ports.SerialPort \$port, 115200
\$p.DtrEnable = \$true; \$p.ReadTimeout = 200
try { \$p.Open() } catch { [Console]::Out.WriteLine('PROBE open failed: ' + \$_.Exception.Message); exit 1 }
Start-Sleep -Milliseconds 200
try { \$p.DiscardInBuffer() } catch {}
\$req = [byte[]](0xAB, 0x08, 0x01, 0x1A, 0x02, 0x08, 0x01, 0xAD)
\$p.Write(\$req, 0, \$req.Length)
[Console]::Out.WriteLine('PROBE sent ' + ((\$req | ForEach-Object { \$_.ToString('x2') }) -join ' '))
\$buf = New-Object byte[] 512; \$got = @()
\$end = (Get-Date).AddSeconds(3)
while ((Get-Date) -lt \$end) {
    try { \$n = \$p.Read(\$buf, 0, \$buf.Length); if (\$n -gt 0) { \$got += \$buf[0..(\$n-1)] } } catch [TimeoutException] {} catch { break }
    if (\$got.Count -gt 0 -and \$got[-1] -eq 0xAD) { break }
}
try { \$p.Close() } catch {}
[Console]::Out.WriteLine('PROBE recv ' + \$got.Count + ' bytes: ' + ((\$got | ForEach-Object { \$_.ToString('x2') }) -join ' '))
" 2>/dev/null | tr -d '\r' > "$out"
cat "$out"
grep -q '^PROBE recv [1-9]' "$out"
