# One console exchange with the half identified by -Serial, through calib-lib.ps1 (the console port
# is looked up by the USB serial, so nothing is ever written to the other half or to the Studio UART).
#   half-io.ps1 -Serial <usb serial> -LogDir <dir>            read the dump (opening the port triggers it)
#   half-io.ps1 -Serial <usb serial> -LogDir <dir> -Bootloader  send 'b' after a complete dump, then wait
#                                                               until the bootloader of this serial is on USB
# Output: the dump text on stdout (read mode). Exit 0 = done, 1 = no dump / bootloader not seen.
# Used by pair-loop.ps1 (2026-10-09).
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [switch]$Bootloader
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'calib-lib.ps1')
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$script:Serial = $Serial
$script:LogFile = Join-Path $LogDir ("halfio-" + (Get-Date).ToString('MMdd-HHmmss-fff') + '.log')
$script:Scn = $null
$script:DumpSeconds = 60
if ($Bootloader) {
    Log "HALFIO bootloader serial=$Serial"
    $state = Get-State
    if ($state -ceq 'boot') { Log 'already in bootloader'; exit 0 }
    if ($state -cne 'app') { Log "state=$state, nothing sent"; exit 1 }
    try {
        $t = Send-Cmd 'b' 2   # Require inside throws CALIB-ABORT when the child refused to write
        $ev = Ack-Evidence $t 'b' 'ZDIAG bootloader'
    } catch {
        if ($_.Exception.Message -cne 'CALIB-ABORT') { Log "ERROR $($_.Exception.Message)" }
        Log "'b' not written"; exit 1
    }
    if (Wait-State 'boot' 30) { Log 'bootloader on USB'; exit 0 }
    Log "bootloader not seen within 30 s (state=$script:lastState)"; exit 1
}
Log "HALFIO read serial=$Serial"
$t = Exchange
if (-not $t) { Pause-Ms 1500; $t = Exchange }
if (-not $t) { Log 'no dump'; exit 1 }
Write-Output $t
exit 0
