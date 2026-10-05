#!/usr/bin/env bash
# Talk to the diag-min aid on the right half. usage: min-cmd.sh <out-file> [command char]
# Opens the console port (which prints a dump), optionally sends one command, saves all output.
set -u
out=$1
cmd=${2:-}
port=$(bash "$(dirname "$0")/port-of.sh" "${SIDE:-R}")
[[ -n "$port" ]] || { : > "$out"; exit 1; }
powershell.exe -NoProfile -Command "
\$p = New-Object System.IO.Ports.SerialPort '$port', 115200
\$p.DtrEnable = \$true; \$p.ReadTimeout = 300; \$p.NewLine = \"\`n\"
try { \$p.Open() } catch { exit 1 }
\$end = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt \$end) { try { \$l = \$p.ReadLine().TrimEnd(\"\`r\"); [Console]::Out.WriteLine(\$l); if (\$l -match 'ZDIAG end') { break } } catch [TimeoutException] {} catch { break } }
if ('$cmd' -ne '') {
    \$p.Write('$cmd')
    [Console]::Out.WriteLine('HOST sent ' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    \$end = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt \$end) { try { \$l = \$p.ReadLine().TrimEnd(\"\`r\"); [Console]::Out.WriteLine(\$l) } catch [TimeoutException] {} catch { break } }
}
try { \$p.Close() } catch {}
" 2>/dev/null | tr -d '\r' > "$out"
grep -q 'ZDIAG end' "$out"
