# Send one console command to the half identified by -Serial, through calib-lib.ps1 (the console
# port is looked up by the USB serial). The console child prints the pre-send dump, writes the
# command, and reads the reply for -ReadSeconds. Used by the lab campaign for 'A' (crash-path
# self-test: the device reboots ~50 ms after the command) and 'c' (clear the crash records).
#   half-cmd.ps1 -Serial <usb serial> -Cmd <char> -LogDir <dir> [-ReadSeconds 2]
# Exit 0 = the command was written (child stamp "sent"), 1 = not written.
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$Cmd,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [int]$ReadSeconds = 2
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:Serial = $Serial
$script:LogFile = Join-Path $LogDir ("halfcmd-" + (Get-Date).ToString('MMdd-HHmmss-fff') + '.log')
$script:Scn = $null
$script:DumpSeconds = 30
Log "HALFCMD serial=$Serial cmd=$Cmd"
try {
    $t = Send-Cmd $Cmd $ReadSeconds
} catch {
    if ($_.Exception.Message -cne 'CALIB-ABORT') { Log "ERROR $($_.Exception.Message)" }
    Log "'$Cmd' not written"; exit 1
}
Log "'$Cmd' written"
Write-Output ($t -split "`n" | Where-Object { $_ -cmatch '^ZDIAG (selftest|ring cleared|drop-host|reboot|bootloader)' } | Select-Object -First 3)
exit 0
