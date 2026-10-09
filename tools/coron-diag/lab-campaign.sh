#!/usr/bin/env bash
# The one-shot measurement campaign (2026-10-09). Steps, each gated on the previous one:
#   1. write the lab image to the right half (one write), check the boot and 'ZDIAG lab live'
#   2. right self-test 'A': crash path -> reboot -> next dump shows crash0 line=4242 file=selftest
#      with the printk tail containing 'Actual EVENT_OVERHEAD_START_US = 4242' and sum=ok; then 'c'
#   3. write the lab image to the left half (one write), left self-test the same way, 'c'
#   4. stimulus 1: recon-loop.ps1 (PC reconnects, no writes) until a crash or 200 cycles
#   5. stimulus 2: prod-loop.ps1 with the SAME file as A and B (bootloader skips identical pages:
#      no flash wear) until a crash or 300 iterations, 60 s dwell
#   6. at every stop: read both halves' dumps, the watchdog store (Studio RPC), export the Windows
#      PnP log for the campaign window
# usage: lab-campaign.sh <step-from> (1..5); logs under %TEMP%\coron-flash\lab-1009-*\ and $S/lab-*.out
set -u
W=/mnt/c/Users/yagu001/AppData/Local/Temp/coron-flash
WW='C:\Users\yagu001\AppData\Local\Temp\coron-flash'
S=/tmp/claude-1000/-home-yagu001-repo-github-com-haoblackj-zmk-workspace/f1edcf4a-4bc3-45f7-a2ec-c1b2a3233983/scratchpad
E=$HOME/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/prod-entry-20261009/wdlog
RSER=B17318CDBE9A61B1; LSER=743A486E04021F9D
RMD5=$(md5sum $W/coron_R-lab.uf2 | cut -d' ' -f1); LMD5=$(md5sum $W/coron_L-lab.uf2 | cut -d' ' -f1)
from=${1:-1}
ps() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$@" 2>&1 | tr -d '\r'; }
say() { echo "$(date +%H:%M:%S) $*"; }
dump_of() { cat "$1"/*-io*.out 2>/dev/null | tr -d '\r'; }

flash_half() { # serial uf2 md5 logdir
    ps "$WW\\calib\\calib-flash.ps1" -Serial "$1" -LogDir "$WW\\$4" -Uf2 "$WW\\$2" -Md5 "$3" -Expect prod | grep -E 'RESULT|FAIL' | cut -c1-160
}
read_half() { # serial logdir -> prints dump lines of interest
    ps "$WW\\calib\\half-io.ps1" -Serial "$1" -LogDir "$WW\\$2" | grep -E 'ZDIAG (begin|crumb|lab live|lab crash[0-9] |lab crash[0-9]pk|lab end|end)' | cut -c1-200
}
send_cmd() { # serial cmd logdir (fire-and-forget commands 'A' and 'c'; the console child prints the pre-send dump)
    ps "$WW\\calib\\half-cmd.ps1" -Serial "$1" -Cmd "$2" -LogDir "$WW\\$3" | tail -3
}
selftest() { # serial logdir-prefix
    local ser=$1 pre=$2
    say "self-test on $ser: send A"
    send_cmd "$ser" A "$pre-A"
    sleep 12
    say "self-test on $ser: read the next boot's dump"
    read_half "$ser" "$pre-after" | grep -E 'lab live|crash0 |crash0pk' | cut -c1-200
    local d; d=$(dump_of "$W/$pre-after")
    if echo "$d" | grep -q 'ZDIAG lab crash0 .*line=4242 file=selftest.*sum=ok' && echo "$d" | grep -q 'crash0pk .*Actual EVENT_OVERHEAD_START_US = 4242'; then
        say "self-test on $ser: PASS (record survived the reboot, text captured, checksum ok)"
    else
        say "self-test on $ser: FAIL"; return 1
    fi
    # the record must also survive the bootloader's DFU pass (the 'b' + same-file path that
    # stimulus 2 uses and that a crash at boot would be read through)
    local uf2 md5
    if [ "$ser" = "$RSER" ]; then uf2=coron_R-lab.uf2; md5=$RMD5; else uf2=coron_L-lab.uf2; md5=$LMD5; fi
    say "self-test on $ser: same-file rewrite through the bootloader, then re-read"
    flash_half "$ser" "$uf2" "$md5" "$pre-rewrite" || return 1
    d=$(dump_of "$W/$pre-rewrite")
    if echo "$d" | grep -q 'ZDIAG lab crash0 .*line=4242 file=selftest.*sum=ok'; then
        say "self-test on $ser: PASS (record survived the bootloader pass too)"
        send_cmd "$ser" c "$pre-clear" >/dev/null
        return 0
    fi
    say "self-test on $ser: FAIL (record lost or corrupted across the bootloader pass)"; return 1
}
stop_capture() { # label: watchdog store + both dumps + PnP export
    local lb=$1; mkdir -p "$S/lab-$lb"
    say "capture at $lb: watchdog store"
    bash $E/studio-rpc.sh "$S/lab-$lb/wd-list.txt" "08 09 a2 06 08 12 06 08 02 12 02 12 00" 4 >/dev/null; python3 $E/pb-decode.py "$S/lab-$lb/wd-list.txt" | head -60 > "$S/lab-$lb/wd-list.decoded.txt"
    say "capture at $lb: dumps"
    read_half "$RSER" "lab-1009-$lb-R" >/dev/null; read_half "$LSER" "lab-1009-$lb-L" >/dev/null
    say "capture at $lb: Windows PnP log (last 24 h)"
    powershell.exe -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap | Out-String -Width 400" 2>/dev/null | tr -d '\r' > "$S/lab-$lb/pnp.txt"
    wc -l "$S/lab-$lb/pnp.txt"
}

if [ "$from" -le 1 ]; then
    say "step 1: write the lab image to R ($RMD5)"
    flash_half "$RSER" coron_R-lab.uf2 "$RMD5" lab-1009-flashR || exit 1
    read_half "$RSER" lab-1009-R0 | grep -E 'crumb|lab live' || exit 1
fi
if [ "$from" -le 2 ]; then
    say "step 2: right self-test"; selftest "$RSER" lab-1009-selfR || exit 1
fi
if [ "$from" -le 3 ]; then
    say "step 3: write the lab image to L ($LMD5) and self-test"
    flash_half "$LSER" coron_L-lab.uf2 "$LMD5" lab-1009-flashL || exit 1
    read_half "$LSER" lab-1009-L0 | grep -E 'crumb|lab live' || exit 1
    selftest "$LSER" lab-1009-selfL || exit 1
fi
if [ "$from" -le 4 ]; then
    say "step 4: reconnect stimulus (no writes)"
    (cd $W && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WW\\calib\\recon-loop.ps1" -RunDir "$WW\\lab-1009-recon" -Cycles 200 -WaitSec 30 > $S/lab-recon.out 2>&1); rc=$?
    tail -n 2 $W/lab-1009-recon/summary.log | cut -c1-200
    if [ $rc -ne 0 ]; then say "recon loop stopped (rc=$rc): capture and END"; stop_capture recon-stop; exit 2; fi
fi
if [ "$from" -le 5 ]; then
    say "step 5: same-file rewrite stimulus (no wear)"
    echo "$W/lab-1009-rewrite" > $S/prod-loop-dir.txt
    (cd $W && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WW\\calib\\prod-loop.ps1" -RunDir "$WW\\lab-1009-rewrite" -Uf2A "$WW\\coron_R-lab.uf2" -Md5A "$RMD5" -Uf2B "$WW\\coron_R-lab.uf2" -Md5B "$RMD5" -Iterations 300 -DwellSec 60 -First A > $S/lab-rewrite.out 2>&1); rc=$?
    tail -n 2 $W/lab-1009-rewrite/summary.log | cut -c1-200
    say "rewrite loop ended (rc=$rc): capture and END"; stop_capture rewrite-stop; exit $rc
fi
