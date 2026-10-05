#!/usr/bin/env bash
# Print the COM port of the console serial port (USB interface 0) of one Coron half.
# usage: port-of.sh <R|L>
# It reads the device tree only. It must not enumerate serial ports through Win32_SerialPort:
# that touches every COM port, including the Bluetooth serial ports of paired headphones, and
# makes Windows page those headphones for five seconds each time.
set -u
case ${1:-R} in
    R) ser=B17318CDBE9A61B1 ;;
    L) ser=743A486E04021F9D ;;
    *) exit 2 ;;
esac
powershell.exe -NoProfile -Command "
Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -match 'VID_1D50&PID_615E&MI_00' } | ForEach-Object {
    \$parent = (Get-PnpDeviceProperty -InstanceId \$_.InstanceId -KeyName DEVPKEY_Device_Parent).Data
    if (\$parent -match '$ser' -and \$_.FriendlyName -match '\((COM\d+)\)') { \$Matches[1] }
} | Select-Object -First 1" 2>/dev/null | tr -d '\r\n'
