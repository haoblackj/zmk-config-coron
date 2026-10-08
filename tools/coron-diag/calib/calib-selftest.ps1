# Direct tests of the two identification functions of calib-lib.ps1 with instance ids read on
# the real PC (review #13, points 1 and 2). No device, no PnP, no CIM: the matchers run on
# strings. Exit 0 when every case holds, 1 otherwise; one line per case.
$script:LogFile = Join-Path ([System.IO.Path]::GetTempPath()) 'calib-selftest.log'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
$script:Serial = 'B17318CDBE9A61B1'
$fails = 0
function Case([string]$what, [bool]$got, [bool]$want) {
    $ok = ($got -eq $want)
    if (-not $ok) { $script:fails++ }
    Write-Output ("{0} {1} -> {2} (want {3})" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $what, $got, $want)
}
Write-Output '--- Test-UsbstorSerial (UF2 disk of this serial)'
Case 'real id, Windows prefix A&258725EA&0& before the serial (read 2026-10-08 10:42)' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1&0') $true
Case 'same id, no prefix (\<serial>&0)' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\B17318CDBE9A61B1&0') $true
Case 'trailing &1 instead of &0' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1&1') $true
Case 'another serial' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&DEADBEEF00000001&0') $false
Case 'serial with one extra leading char (XB17318CDBE9A61B1)' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&XB17318CDBE9A61B1&0') $false
Case 'serial with one extra trailing char (B17318CDBE9A61B1X)' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1X&0') $false
Case 'serial truncated by one char (B17318CDBE9A61B)' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B&0') $false
Case 'serial present but not before the trailing &n' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\B17318CDBE9A61B1&A&258725EA&0&0') $false
Case 'not a USBSTOR disk (USB device node of the bootloader)' (Test-UsbstorSerial 'USB\VID_2886&PID_0045\B17318CDBE9A61B1') $false
Case 'lower-case serial' (Test-UsbstorSerial 'USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&b17318cdbe9a61b1&0') $true
Write-Output '--- Test-ConsoleIface (diag console = CDC interface MI_00 of VID 1D50 PID 615E)'
Case 'COM5 instance id, MI_00 (read 2026-10-08)' (Test-ConsoleIface 'USB\VID_1D50&PID_615E&MI_00\9&168EB68&4&0000') $true
Case 'COM7 instance id, MI_03 (Studio RPC UART)' (Test-ConsoleIface 'USB\VID_1D50&PID_615E&MI_03\9&168EB68&4&0003') $false
Case 'HID interface MI_02' (Test-ConsoleIface 'USB\VID_1D50&PID_615E&MI_02\9&168EB68&4&0002') $false
Case 'MI_00 of another VID/PID' (Test-ConsoleIface 'USB\VID_239A&PID_0045&MI_00\9&1&2&0000') $false
Case 'MI_000 (not MI_00)' (Test-ConsoleIface 'USB\VID_1D50&PID_615E&MI_000\9&168EB68&4&0000') $false
Write-Output ("SELFTEST " + $(if ($fails -eq 0) { 'PASS' } else { "FAIL ($fails)" }))
if ($fails -eq 0) { exit 0 } else { exit 1 }
