# Overnight alternate-write loop with PRODUCTION images (2026-10-09, leader's decision on
# zmk-workspace#1): write image B, check the boot, dwell, write image A, check, dwell, ... Both images
# carry the boot-entry clean and the breadcrumb (CONFIG_CORON_DIAG_ENTRY) and differ in every page
# (B = speed optimizations), so each iteration is a real UF2 write followed by the bootloader's
# DFU exit. Every write goes through calib-flash.ps1 -Expect prod (console 'b', UF2 copy, drive
# gone, app back within 90 s, dump complete). On top of that this loop requires the dump's
# 'ZDIAG crumb' line to say: previous boot valid and reached RUNNING (pv=1 pst=10), this boot
# reached RUNNING (st=10), seq advanced by one.
# Any failed check STOPS the loop without further device operations: a half that did not come
# back stays as it is (no reset, no power cycle possible) until the leader presses reset once; the
# next boot's dump then shows the stalled boot's stage in 'pst'.
# usage: prod-loop.ps1 -RunDir <dir> -Uf2A <file> -Md5A <md5> -Uf2B <file> -Md5B <md5> [-Iterations 250] [-DwellSec 60]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$Uf2A,
    [Parameter(Mandatory = $true)][string]$Md5A,
    [Parameter(Mandatory = $true)][string]$Uf2B,
    [Parameter(Mandatory = $true)][string]$Md5B,
    [int]$Iterations = 250,
    [int]$DwellSec = 60,
    [ValidateSet('A', 'B')][string]$First = 'B',   # the image to write first (the other one is running)
    [string]$Serial = 'B17318CDBE9A61B1'
)
$ErrorActionPreference = 'Stop'
$flash = Join-Path $PSScriptRoot 'calib-flash.ps1'
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$script:Summary = Join-Path $RunDir 'summary.log'
function Log([string]$m) {
    $line = (Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m
    Add-Content -LiteralPath $script:Summary -Value $line -Encoding UTF8
    Write-Host $line
}
$imgA = @{ Name = 'A'; Uf2 = $Uf2A; Md5 = $Md5A }
$imgB = @{ Name = 'B'; Uf2 = $Uf2B; Md5 = $Md5B }
$images = if ($First -ceq 'B') { @($imgB, $imgA) } else { @($imgA, $imgB) }
Log "LOOP start iterations=$Iterations dwell=${DwellSec}s serial=$Serial A=$Uf2A ($Md5A) B=$Uf2B ($Md5B)"
$done = 0; $stop = ''
$prevSeq = $null
for ($i = 1; $i -le $Iterations; $i++) {
    $img = $images[($i - 1) % 2]
    $ld = Join-Path $RunDir ('iter-{0:d3}' -f $i)
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    $t0 = Get-Date
    Log ('iter {0} write {1} (deadline 200s)' -f $i, $img.Name)
    $childOut = Join-Path $ld 'child.out'
    $childErr = Join-Path $ld 'child.err'
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $flash, '-Serial', $Serial, '-LogDir', $ld, '-Uf2', $img.Uf2, '-Md5', $img.Md5, '-Expect', 'prod') -NoNewWindow -PassThru -RedirectStandardOutput $childOut -RedirectStandardError $childErr
    $null = $p.Handle   # PowerShell 5.1: without touching Handle before the exit, ExitCode reads back empty
    if (-not $p.WaitForExit(200000)) {
        Log ('iter {0} child did not exit within 200 s (pid {1}); not killed, STOP' -f $i, $p.Id)
        $stop = 'child-timeout'; break
    }
    $rc = $p.ExitCode
    if ($null -eq $rc) { $rc = -1 }   # unreadable exit code counts as a failure (never as a pass)
    $io2 =Get-ChildItem -LiteralPath $ld -Filter 'flash-prod-*-io2.out' -ErrorAction SilentlyContinue | Select-Object -First 1
    $crumb = ''
    if ($io2) { $crumb = (Get-Content -LiteralPath $io2.FullName | Where-Object { $_ -cmatch '^ZDIAG crumb ' } | Select-Object -First 1) }
    $crumbOk = $false; $seq = $null
    if ($crumb -cmatch 'pv=(\d+) pseq=(\d+) pst=(\d+) .* seq=(\d+) st=(\d+)') {
        $pv = [int]$Matches[1]; $pseq = [int]$Matches[2]; $pst = [int]$Matches[3]; $seq = [int]$Matches[4]; $st = [int]$Matches[5]
        $crumbOk = ($pv -eq 1 -and $pst -eq 10 -and $st -eq 10 -and $seq -eq ($pseq + 1))
        if ($null -ne $prevSeq -and $pseq -ne $prevSeq) { $crumbOk = $false }
    }
    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    Log ('iter {0} result image={1} rc={2} crumb="{3}" crumb_ok={4} elapsed={5}s' -f $i, $img.Name, $rc, $crumb, $crumbOk, $elapsed)
    if ($rc -ne 0 -or -not $crumbOk) {
        $stop = "check-failed rc=$rc crumb_ok=$crumbOk"
        Log ('iter {0} STOP ({1}); no further device operation' -f $i, $stop)
        break
    }
    $prevSeq = $seq
    $done++
    if ($i -lt $Iterations) {
        Log ('iter {0} dwell {1}s (deadline {2}s)' -f $i, $DwellSec, ($DwellSec + 30))
        Start-Sleep -Seconds $DwellSec
    }
}
if (-not $stop) { $stop = 'all-iterations-done' }
Log "LOOP DONE iterations_ok=$done stop=$stop last_seq=$prevSeq"
if ($stop -eq 'all-iterations-done') { exit 0 } else { exit 1 }
