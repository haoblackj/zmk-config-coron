# The whole calibration without any manual operation: preflight, write the base test image,
# steps 0,1,2,(3 SKIP),4,5,6,7,8, then ALWAYS the production restore, then a summary.
# Calibration stops at the first FAIL (the failing step already saved everything and did not
# perform its next device operation). The restore runs afterwards whatever the calibration result,
# with its own checks, and is reported separately. Exit codes: 0 both PASS, 1 calibration FAIL and
# restore PASS, 2 restore FAIL (calibration PASS), 3 both FAIL.
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [Parameter(Mandatory = $true)][string]$Uf2Base, [Parameter(Mandatory = $true)][string]$Md5Base,
    [Parameter(Mandatory = $true)][string]$Uf2Alt, [Parameter(Mandatory = $true)][string]$Md5Alt,
    [Parameter(Mandatory = $true)][string]$Uf2Prod, [Parameter(Mandatory = $true)][string]$Md5Prod,
    [string]$MockDir = ''   # directory of per-step scenario files (pre.json, flash-base.json, 0.json, ..., flash-prod.json)
)
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$summary = Join-Path $LogDir 'summary.log'
function S($m) { $line = (Get-Date).ToString('HH:mm:ss') + " $m"; Add-Content -Path $summary -Value $line -Encoding UTF8; Write-Host $line }
function MockArg([string]$name) { if ($MockDir) { $p = Join-Path $MockDir "$name.json"; if (Test-Path $p) { return @('-Mock', $p) } }; return @() }
$run = Join-Path $PSScriptRoot 'calib-run.ps1'
$flash = Join-Path $PSScriptRoot 'calib-flash.ps1'
$common = @('-Serial', $Serial, '-LogDir', $LogDir, '-Uf2Base', $Uf2Base, '-Md5Base', $Md5Base, '-Uf2Alt', $Uf2Alt, '-Md5Alt', $Md5Alt, '-Uf2Prod', $Uf2Prod, '-Md5Prod', $Md5Prod)
$results = [ordered]@{}
$calibFail = $false

S "CALIBRATION start serial=$Serial"
# preflight (no device write) and the base image write
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $run -Step pre @common @(MockArg 'pre') | Out-Null
$results['pre'] = $LASTEXITCODE
S "pre rc=$($results['pre'])"
if ($results['pre'] -ne 0) { $calibFail = $true }
if (-not $calibFail) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $flash -Serial $Serial -LogDir $LogDir -Uf2 $Uf2Base -Md5 $Md5Base -Expect base @(MockArg 'flash-base') | Out-Null
    $results['flash-base'] = $LASTEXITCODE
    S "flash-base rc=$($results['flash-base'])"
    if ($results['flash-base'] -ne 0) { $calibFail = $true }
}
foreach ($step in @('0', '1', '2', '3', '4', '5', '6', '7', '8')) {
    if ($calibFail) { $results[$step] = 'not run'; S "step $step not run (calibration stopped)"; continue }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $run -Step $step @common @(MockArg $step) | Out-Null
    $rc = $LASTEXITCODE
    $results[$step] = $rc
    $label = switch ($rc) { 0 { 'PASS' } 1 { 'FAIL' } 2 { 'SKIP' } default { "rc=$rc" } }
    S "step $step $label"
    if ($rc -eq 1 -or $rc -ge 3) { $calibFail = $true }
}
# production restore: always, separately judged
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $flash -Serial $Serial -LogDir $LogDir -Uf2 $Uf2Prod -Md5 $Md5Prod -Expect prod @(MockArg 'flash-prod') | Out-Null
$results['restore'] = $LASTEXITCODE
$restoreFail = ($results['restore'] -ne 0)
S ("restore " + $(if ($restoreFail) { 'FAIL' } else { 'PASS' }))
S ("CALIBRATION " + $(if ($calibFail) { 'FAIL' } else { 'PASS (step 3 SKIP: pin reset not tested)' }) + " | RESTORE " + $(if ($restoreFail) { 'FAIL' } else { 'PASS' }))
S ("results: " + (($results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
$code = 0
if ($calibFail) { $code += 1 }
if ($restoreFail) { $code += 2 }
exit $code
