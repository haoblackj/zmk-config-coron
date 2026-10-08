#!/usr/bin/env bash
# Send one framed Studio RPC request to the right half's Studio UART (MI_03 of B17318CDBE9A61B1)
# and print everything received for a few seconds as hex. Framing: SOF 0xAB, ESC 0xAC, EOF 0xAD
# (zmk/app/src/studio/msg_framing.h). Only the given request bytes are written (escaped).
# usage: studio-rpc.sh <out-file> <payload hex, e.g. "08 01 1a 02 08 01"> [read seconds, default 3]
set -u
out=$1
hex=$2
secs=${3:-3}
ser=B17318CDBE9A61B1
pl=$(echo "$hex" | tr -d ' ' | sed 's/../0x&,/g; s/,$//')
powershell.exe -NoProfile -Command "
\$port = Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -match 'VID_1D50&PID_615E&MI_03' } | ForEach-Object {
    \$parent = (Get-PnpDeviceProperty -InstanceId \$_.InstanceId -KeyName DEVPKEY_Device_Parent).Data
    if (\$parent -match '$ser' -and \$_.FriendlyName -match '\((COM\d+)\)') { \$Matches[1] }
} | Select-Object -First 1
if (-not \$port) { [Console]::Out.WriteLine('RPC no MI_03 port'); exit 1 }
[Console]::Out.WriteLine('RPC port ' + \$port)
\$p = New-Object System.IO.Ports.SerialPort \$port, 115200
\$p.DtrEnable = \$true; \$p.ReadTimeout = 200
try { \$p.Open() } catch { [Console]::Out.WriteLine('RPC open failed: ' + \$_.Exception.Message); exit 1 }
Start-Sleep -Milliseconds 200
try { \$p.DiscardInBuffer() } catch {}
\$payload = [byte[]]($pl)
\$frame = New-Object System.Collections.Generic.List[byte]
\$frame.Add(0xAB)
foreach (\$b in \$payload) { if (\$b -eq 0xAB -or \$b -eq 0xAC -or \$b -eq 0xAD) { \$frame.Add(0xAC) }; \$frame.Add(\$b) }
\$frame.Add(0xAD)
\$req = \$frame.ToArray()
\$p.Write(\$req, 0, \$req.Length)
[Console]::Out.WriteLine('RPC sent ' + ((\$req | ForEach-Object { \$_.ToString('x2') }) -join ' '))
\$buf = New-Object byte[] 4096; \$got = New-Object System.Collections.Generic.List[byte]
\$end = (Get-Date).AddSeconds($secs)
while ((Get-Date) -lt \$end) {
    try { \$n = \$p.Read(\$buf, 0, \$buf.Length); if (\$n -gt 0) { for (\$i = 0; \$i -lt \$n; \$i++) { \$got.Add(\$buf[\$i]) } } } catch [TimeoutException] {} catch { break }
}
try { \$p.Close() } catch {}
[Console]::Out.WriteLine('RPC recv ' + \$got.Count + ' bytes: ' + ((\$got | ForEach-Object { \$_.ToString('x2') }) -join ' '))
" 2>/dev/null | tr -d '\r' > "$out"
cat "$out"
grep -q '^RPC recv [1-9]' "$out"
