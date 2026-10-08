# Terminates one process and its whole process tree, and CONFIRMS it (review #10 point 3,
# review #11). Runs as its own process so that the caller (Invoke-Child in calib-lib.ps1) can put
# a deadline on the termination as a whole: the tree enumeration (CIM), the termination request
# (taskkill) and the confirmation each can block, and none of them can be interrupted from inside
# this script. The caller waits for this process with a deadline and, if it does not return,
# records the termination as NOT confirmed from whatever this script had printed so far.
#   calib-kill.ps1 -TargetPid <pid> [-Mode <simulation mode>]
# Progress goes to stdout, one line per phase, flushed at once:
#   phase=enumerate pid=N / tree=[N,...] / phase=terminate / taskkill rc=N: <output> /
#   phase=confirm / alive=[...] confirmed=True|False
# Exit 0 = confirmed (taskkill returned 0 and no pid of the tree is left within 5 s), 1 = not.
# -Mode (simulation only): 'fail' = taskkill not invoked, rc 1; 'linger' = taskkill not invoked,
# rc 0; 'enum-hang' = block before the enumeration; 'kill-hang' = block instead of taskkill.
# The enumeration and the confirmation are real in every mode.
param([Parameter(Mandatory = $true)][int]$TargetPid, [string]$Mode = '')
function Emit([string]$s) { [Console]::Out.WriteLine($s); [Console]::Out.Flush() }
function Get-ProcessTree([int]$rootPid) {
    $ids = @($rootPid); $queue = @($rootPid)
    while ($queue.Count -gt 0) {
        $cur = $queue[0]; $queue = @($queue | Select-Object -Skip 1)
        $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$cur" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.ProcessId })
        foreach ($k in $kids) { if ($ids -notcontains $k) { $ids += $k; $queue += $k } }
    }
    return $ids
}
Emit "phase=enumerate pid=$TargetPid"
if ($Mode -ceq 'enum-hang') { Start-Sleep -Seconds 600 }
$tree = @(Get-ProcessTree $TargetPid)
Emit "tree=[$($tree -join ',')]"
Emit 'phase=terminate'
if ($Mode -ceq 'kill-hang') { Start-Sleep -Seconds 600 }
if ($Mode -ceq 'fail') { $kout = '(mock) taskkill NOT invoked: simulated failure'; $krc = 1 }
elseif ($Mode -ceq 'linger') { $kout = '(mock) taskkill NOT invoked: simulated success without effect'; $krc = 0 }
else { $kout = ((& taskkill.exe /PID $TargetPid /T /F 2>&1) | ForEach-Object { "$_" }) -join ' | '; $krc = $LASTEXITCODE }
Emit "taskkill rc=${krc}: $kout"
Emit 'phase=confirm'
$t0 = Get-Date; $alive = @()
while ($true) {
    $alive = @($tree | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    if ($alive.Count -eq 0 -or ((Get-Date) - $t0).TotalSeconds -ge 5) { break }
    Start-Sleep -Milliseconds 200
}
$confirmed = ($krc -eq 0 -and $alive.Count -eq 0)
Emit "alive=[$($alive -join ',')] confirmed=$confirmed (after $([int](((Get-Date) - $t0).TotalSeconds)) s)"
if ($confirmed) { exit 0 } else { exit 1 }
